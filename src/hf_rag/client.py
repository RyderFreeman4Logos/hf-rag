from __future__ import annotations

from typing import Any, Iterable

import httpx

from .config import Config
from .sparse import sparse_vector


class ServiceError(RuntimeError):
    pass


class RAGClient:
    def __init__(self, config: Config) -> None:
        self.config = config
        headers = {"Content-Type": "application/json"}
        if key := config.qdrant_api_key():
            headers["api-key"] = key
        self.qdrant = httpx.Client(base_url=config.qdrant_url, headers=headers, timeout=config.timeout_seconds)
        self.gb10 = httpx.Client(timeout=config.timeout_seconds)

    def close(self) -> None:
        self.qdrant.close()
        self.gb10.close()

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

    def health(self) -> bool:
        response = self.qdrant.get("/healthz")
        return response.status_code == 200

    def embed(self, texts: list[str]) -> list[list[float]]:
        headers = {"Authorization": f"Bearer {key}"} if (key := self.config.api_key()) else {}
        response = self.gb10.post(
            self.config.embedding_url,
            headers=headers,
            json={"model": self.config.embedding_model, "input": texts},
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
        response = self.gb10.post(
            self.config.rerank_url,
            headers=headers,
            json={"model": self.config.rerank_model, "query": query, "documents": documents},
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
        return self._checked(self.qdrant.get(f"/collections/{self.config.collection}"), "collection info")

    def count(self) -> int:
        body = self._checked(
            self.qdrant.post(f"/collections/{self.config.collection}/points/count", json={"exact": True}), "count"
        )
        return int(body.get("result", {}).get("count", 0))

    def upsert(self, points: list[dict[str, Any]]) -> None:
        self._checked(
            self.qdrant.put(f"/collections/{self.config.collection}/points?wait=true", json={"points": points}), "upsert"
        )

    def search(self, query: str, limit: int = 8) -> list[dict[str, Any]]:
        """Qdrant v1.18 query API: named dense + sparse prefetch fused by server-side RRF."""
        dense = self.embed([query])[0]
        body = self._checked(
            self.qdrant.post(
                f"/collections/{self.config.collection}/points/query",
                json={
                    "prefetch": [
                        {"query": dense, "using": "dense", "limit": limit * 3},
                        {"query": sparse_vector(query), "using": "bm25", "limit": limit * 3},
                    ],
                    "query": {"fusion": "rrf"}, "limit": limit * 2, "with_payload": True,
                },
            ),
            "hybrid RRF query",
        )
        result = body.get("result", {})
        fused = result.get("points", []) if isinstance(result, dict) else []
        if not isinstance(fused, list):
            fused = []
        docs = [str(item.get("payload", {}).get("text", "")) for item in fused]
        if not docs:
            return []
        reranked = self.rerank(query, docs)
        for item, score in zip(fused, reranked):
            item["rerank_score"] = score
        return sorted(fused, key=lambda item: float(item["rerank_score"]), reverse=True)[:limit]

    @staticmethod
    def safe_hits(hits: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
        output = []
        for hit in hits:
            payload = hit.get("payload", {})
            if not isinstance(payload, dict):
                payload = {}
            output.append({
                "record_id": payload.get("record_id", hit.get("id")),
                "score": hit.get("rerank_score", hit.get("score")),
                "dataset_id": payload.get("dataset_id"), "split": payload.get("split"),
                "language": payload.get("language"), "content_hash": payload.get("content_hash"),
            })
        return output
