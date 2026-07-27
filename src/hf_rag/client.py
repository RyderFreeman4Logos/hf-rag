from __future__ import annotations

import random
import time
from threading import Lock, local
from typing import Any, Iterable

import httpx

from .config import Config
from .sparse import sparse_vector


class ServiceError(RuntimeError):
    pass


GB10_MAX_ATTEMPTS = 100


class RAGClient:
    def __init__(self, config: Config) -> None:
        self.config = config
        headers = {"Content-Type": "application/json"}
        if key := config.qdrant_api_key():
            headers["api-key"] = key
        self.qdrant = httpx.Client(base_url=config.qdrant_url, headers=headers, timeout=config.timeout_seconds)
        # Embedding calls are submitted from multiple worker threads. A sync
        # httpx.Client must not be shared between them: thread-local clients
        # give each worker its own connection pool and therefore a real GB10
        # TCP connection while Qdrant remains serial in the ingest loop.
        self._gb10_local = local()
        self._gb10_lock = Lock()
        self._gb10_clients: list[Any] = []
        self._closed = False

    def _new_gb10_client(self) -> httpx.Client:
        connection_limit = max(1, self.config.embed_concurrency)
        return httpx.Client(
            timeout=self.config.timeout_seconds,
            limits=httpx.Limits(
                max_connections=connection_limit,
                max_keepalive_connections=connection_limit,
            ),
        )

    @property
    def gb10(self) -> httpx.Client:
        """Return the calling thread's GB10 client, creating it on first use."""
        client = getattr(self._gb10_local, "client", None)
        if client is not None:
            return client
        with self._gb10_lock:
            if self._closed:
                raise RuntimeError("RAGClient is closed")
            client = self._new_gb10_client()
            self._gb10_clients.append(client)
            self._gb10_local.client = client
        return client

    @gb10.setter
    def gb10(self, client: httpx.Client) -> None:
        """Allow synthetic transports in tests without sharing production clients."""
        with self._gb10_lock:
            if self._closed:
                raise RuntimeError("RAGClient is closed")
            self._gb10_clients.append(client)
            self._gb10_local.client = client

    def close(self) -> None:
        self.qdrant.close()
        with self._gb10_lock:
            self._closed = True
            clients, self._gb10_clients = self._gb10_clients, []
        for client in clients:
            client.close()

    @staticmethod
    def _checked(response: httpx.Response, operation: str) -> dict[str, Any]:
        if response.is_error:
            raise ServiceError(f"{operation}: HTTP {response.status_code}")
        try:
            payload = response.json()
        except ValueError as exc:
            raise ServiceError(f"{operation}: invalid JSON") from exc
        if not isinstance(payload, dict):
            raise ServiceError(f"{operation}: unexpected JSON type")
        return payload

    def _map_transport_error(self, operation: str, exc: Exception) -> ServiceError:
        """Never include request bodies; include short connectivity hints."""
        name = type(exc).__name__
        hint = ""
        if "ConnectError" in name or "ConnectTimeout" in name or "Connection refused" in str(exc):
            hint = (
                " connection refused;"
                " if running inside hermes/raven container, Qdrant loopback is not shared —"
                " use docker-network URL (e.g. http://deploy-qdrant-1:6333) via"
                " RAGCTL_CONFIG and run deploy/scripts/setup-container-client.sh on the host"
            )
        return ServiceError(f"{operation}: {name}{hint}")

    def _gb10_post(
        self, operation: str, url: str, headers: dict[str, str], payload: dict[str, Any]
    ) -> httpx.Response:
        """Post to GB10 with long retry budgets while never rendering request content."""
        max_attempts = max(1, self.config.gb10_max_attempts)
        max_sleep = max(0.0, self.config.retry_max_sleep_seconds)

        def retry_sleep(attempt: int) -> None:
            # Jitter avoids eight concurrent workers retrying in lockstep.
            ceiling = min(float(2 ** min(attempt - 1, 20)), max_sleep)
            time.sleep(random.uniform(ceiling * 0.5, ceiling) if ceiling else 0.0)

        for attempt in range(1, max_attempts + 1):
            try:
                response = self.gb10.post(url, headers=headers, json=payload)
            except httpx.RequestError as exc:
                if attempt == max_attempts:
                    raise ServiceError(
                        f"{operation}: network {type(exc).__name__} after {attempt} attempts"
                    ) from None
                retry_sleep(attempt)
                continue

            retryable = response.status_code in {408, 429} or response.status_code >= 500
            if retryable and attempt == max_attempts:
                raise ServiceError(f"{operation}: HTTP {response.status_code} after {attempt} attempts")
            if retryable:
                retry_sleep(attempt)
                continue
            return response

        raise AssertionError("unreachable")

    def health(self) -> bool:
        try:
            response = self.qdrant.get("/healthz")
        except httpx.RequestError as exc:
            raise self._map_transport_error("qdrant health", exc) from None
        return response.status_code == 200

    def embed(self, texts: list[str]) -> list[list[float]]:
        headers = {"Authorization": f"Bearer {key}"} if (key := self.config.api_key()) else {}
        response = self._gb10_post(
            "embedding",
            self.config.embedding_url,
            headers,
            {"model": self.config.embedding_model, "input": texts},
        )
        data = self._checked(response, "embedding").get("data")
        if not isinstance(data, list):
            raise ServiceError("embedding: missing data")
        vectors = [item.get("embedding") for item in data if isinstance(item, dict)]
        if len(vectors) != len(texts) or any(not isinstance(vector, list) or len(vector) != 4096 for vector in vectors):
            raise ServiceError("embedding: expected exactly 4096 dimensions")
        return vectors

    def rerank(self, query: str, documents: list[str]) -> list[float]:
        headers = {"Authorization": f"Bearer {key}"} if (key := self.config.api_key()) else {}
        response = self._gb10_post(
            "rerank",
            self.config.rerank_url,
            headers,
            {"model": self.config.rerank_model, "query": query, "documents": documents},
        )
        body = self._checked(response, "rerank")
        results = body.get("results", body.get("data"))
        if not isinstance(results, list):
            raise ServiceError("rerank: missing results")
        ordered = [0.0] * len(documents)
        for position, item in enumerate(results):
            if not isinstance(item, dict):
                continue
            index = item.get("index", position)
            score = item.get("relevance_score", item.get("score"))
            if isinstance(index, int) and 0 <= index < len(ordered) and isinstance(score, (int, float)):
                ordered[index] = float(score)
        return ordered

    def create_collection(self) -> None:
        config = {
            "vectors": {"dense": {"size": 4096, "distance": "Cosine", "on_disk": True}},
            "sparse_vectors": {"bm25": {"index": {"on_disk": True}, "modifier": "idf"}},
            "hnsw_config": {"m": 8, "ef_construct": 32, "full_scan_threshold": 1000, "on_disk": True},
            "optimizers_config": {"default_segment_number": 1, "indexing_threshold": 2000000, "memmap_threshold": 10000},
            "wal_config": {"wal_capacity_mb": 4, "wal_segments_ahead": 0},
            "on_disk_payload": True,
            "strict_mode_config": {"enabled": True, "max_resident_memory_percent": 80},
        }
        response = self.qdrant.put(f"/collections/{self.config.collection}", json=config)
        if response.status_code not in {200, 201, 409}:
            self._checked(response, "create collection")
        for field in ("dataset_id", "split", "language", "record_id", "content_hash"):
            response = self.qdrant.put(
                f"/collections/{self.config.collection}/index", json={"field_name": field, "field_schema": "keyword"}
            )
            if response.status_code not in {200, 201, 409}:
                self._checked(response, f"create payload index {field}")

    def collection_info(self) -> dict[str, Any]:
        try:
            return self._checked(self.qdrant.get(f"/collections/{self.config.collection}"), "collection info")
        except httpx.RequestError as exc:
            raise self._map_transport_error("collection info", exc) from None

    def count(self) -> int:
        try:
            body = self._checked(
                self.qdrant.post(f"/collections/{self.config.collection}/points/count", json={"exact": True}), "count"
            )
        except httpx.RequestError as exc:
            raise self._map_transport_error("count", exc) from None
        return int(body.get("result", {}).get("count", 0))

    def upsert(self, points: list[dict[str, Any]]) -> None:
        try:
            self._checked(
                self.qdrant.put(f"/collections/{self.config.collection}/points?wait=true", json={"points": points}), "upsert"
            )
        except httpx.RequestError as exc:
            raise self._map_transport_error("upsert", exc) from None

    def search(self, query: str, limit: int = 8) -> list[dict[str, Any]]:
        """Qdrant v1.18 query API: named dense + sparse prefetch fused by server-side RRF."""
        dense = self.embed([query])[0]
        dense_k = max(self.config.dense_prefetch, limit * 8)
        bm25_k = max(self.config.bm25_prefetch, limit * 8)
        fused_k = max(self.config.fused_limit, limit * 4)
        try:
            body = self._checked(
                self.qdrant.post(
                    f"/collections/{self.config.collection}/points/query",
                    json={
                        "prefetch": [
                            {"query": dense, "using": "dense", "limit": dense_k},
                            {"query": sparse_vector(query), "using": "bm25", "limit": bm25_k},
                        ],
                        "query": {"fusion": "rrf"},
                        "limit": fused_k,
                        "with_payload": True,
                    },
                ),
                "hybrid RRF query",
            )
        except httpx.RequestError as exc:
            raise self._map_transport_error("hybrid RRF query", exc) from None
        result = body.get("result", {})
        fused = result.get("points", []) if isinstance(result, dict) else []
        if not isinstance(fused, list):
            fused = []
        docs = [str(item.get("payload", {}).get("text", "")) for item in fused]
        if not docs:
            return []
        # Rerank all fused candidates (quality over speed).
        reranked = self.rerank(query, docs)
        for item, score in zip(fused, reranked):
            item["rerank_score"] = score
        return sorted(fused, key=lambda item: float(item["rerank_score"]), reverse=True)[:limit]

    @staticmethod
    def safe_hits(hits: Iterable[dict[str, Any]], *, include_text: bool = False) -> list[dict[str, Any]]:
        """Project hits. Text is opt-in for interactive search (never for logs)."""
        output = []
        for hit in hits:
            payload = hit.get("payload", {})
            if not isinstance(payload, dict):
                payload = {}
            row = {
                "record_id": payload.get("record_id", hit.get("id")),
                "score": hit.get("rerank_score", hit.get("score")),
                "dataset_id": payload.get("dataset_id"),
                "split": payload.get("split"),
                "language": payload.get("language"),
                "content_hash": payload.get("content_hash"),
            }
            if include_text:
                # Explicit opt-in for Hermes skill / interactive review only.
                text = payload.get("text")
                if isinstance(text, str):
                    row["text"] = text
            output.append(row)
        return output
