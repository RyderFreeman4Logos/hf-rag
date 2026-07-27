from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class DatasetRule:
    glob: str = "*"
    dataset_id: str = "hf"
    fields: tuple[str, ...] = ("goal", "target", "prompt", "text", "messages", "instruction", "response")
    split: str = "unknown"
    language: str = "unknown"


@dataclass(frozen=True)
class Config:
    qdrant_url: str = "http://127.0.0.1:6333"
    collection: str = "hf_eval_hybrid"
    qdrant_api_key_env: str = "QDRANT_API_KEY"
    embedding_url: str = "http://100.105.4.92:18002/v1/embeddings"
    embedding_model: str = "qwen3-embedding-8b"
    rerank_url: str = "http://100.105.4.92:18003/v1/rerank"
    rerank_model: str = "qwen3-reranker-8b"
    api_key_env: str = "GB10_API_KEY"
    timeout_seconds: float = 540.0
    embed_batch_size: int = 4
    upsert_batch_size: int = 8
    # Retrieval quality knobs (slow is OK). Defaults favor recall + rerank depth.
    dense_prefetch: int = 240
    bm25_prefetch: int = 240
    fused_limit: int = 120
    min_mem_available_mib: int = 768
    max_qdrant_rss_mib: int = 700
    disk_free_mib: int = 1024
    log_full_text: bool = False
    checkpoint: Path = Path("/home/obj/srv/hf-rag/state/ingest.sqlite3")
    rules: tuple[DatasetRule, ...] = field(default_factory=lambda: (DatasetRule(),))

    def api_key(self) -> str | None:
        return os.environ.get(self.api_key_env)

    def qdrant_api_key(self) -> str | None:
        return os.environ.get(self.qdrant_api_key_env)

    def rule_for(self, dataset_path: str) -> DatasetRule:
        from fnmatch import fnmatch

        return next((rule for rule in self.rules if fnmatch(dataset_path, rule.glob)), self.rules[-1])


def discover_config_path() -> Path | None:
    """Resolve config without printing contents.

    Order:
    1. RAGCTL_CONFIG env
    2. ./ragctl.toml
    3. $XDG_CONFIG_HOME/hf-rag/ragctl.toml
    4. ~/.config/hf-rag/ragctl.toml
    5. /opt/data/.config/hf-rag/ragctl.toml  (hermes/raven volume)
    6. /home/obj/srv/hf-rag/etc/ragctl.toml  (host deploy)
    """
    env = os.environ.get("RAGCTL_CONFIG")
    candidates: list[Path] = []
    if env:
        candidates.append(Path(env))
    candidates.append(Path.cwd() / "ragctl.toml")
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        candidates.append(Path(xdg) / "hf-rag" / "ragctl.toml")
    home = Path.home()
    candidates.append(home / ".config" / "hf-rag" / "ragctl.toml")
    candidates.append(Path("/opt/data/.config/hf-rag/ragctl.toml"))
    candidates.append(Path("/home/obj/srv/hf-rag/etc/ragctl.toml"))
    for path in candidates:
        try:
            if path.is_file():
                return path
        except OSError:
            continue
    return None


def load_config(path: Path | None) -> Config:
    if path is None:
        path = discover_config_path()
    if path is None:
        return Config()
    raw = tomllib.loads(path.read_text(encoding="utf-8"))
    rag = raw.get("rag", {})
    ingest = raw.get("ingest", {})
    retrieval = raw.get("retrieval", {})
    rules = tuple(
        DatasetRule(
            glob=str(rule.get("glob", "*")), dataset_id=str(rule.get("dataset_id", "hf")),
            fields=tuple(str(field) for field in rule.get("fields", DatasetRule.fields)),
            split=str(rule.get("split", "unknown")), language=str(rule.get("language", "unknown")),
        ) for rule in raw.get("dataset_rule", [])
    ) or (DatasetRule(),)
    log_full_text = bool(ingest.get("log_full_text", False))
    if log_full_text:
        raise ValueError("log_full_text must remain false")
    return Config(
        qdrant_url=str(rag.get("qdrant_url", Config.qdrant_url)).rstrip("/"),
        collection=str(rag.get("collection", Config.collection)),
        qdrant_api_key_env=str(rag.get("qdrant_api_key_env", Config.qdrant_api_key_env)),
        embedding_url=str(rag.get("embedding_url", Config.embedding_url)),
        embedding_model=str(rag.get("embedding_model", Config.embedding_model)),
        rerank_url=str(rag.get("rerank_url", Config.rerank_url)),
        rerank_model=str(rag.get("rerank_model", Config.rerank_model)),
        api_key_env=str(rag.get("api_key_env", Config.api_key_env)),
        timeout_seconds=float(rag.get("timeout_seconds", Config.timeout_seconds)),
        embed_batch_size=int(ingest.get("embed_batch_size", Config.embed_batch_size)),
        upsert_batch_size=int(ingest.get("upsert_batch_size", Config.upsert_batch_size)),
        dense_prefetch=int(retrieval.get("dense_prefetch", Config.dense_prefetch)),
        bm25_prefetch=int(retrieval.get("bm25_prefetch", Config.bm25_prefetch)),
        fused_limit=int(retrieval.get("fused_limit", Config.fused_limit)),
        min_mem_available_mib=int(ingest.get("min_mem_available_mib", Config.min_mem_available_mib)),
        max_qdrant_rss_mib=int(ingest.get("max_qdrant_rss_mib", Config.max_qdrant_rss_mib)),
        disk_free_mib=int(ingest.get("disk_free_mib", Config.disk_free_mib)),
        log_full_text=log_full_text,
        checkpoint=Path(ingest.get("checkpoint", str(Config.checkpoint))), rules=rules,
    )
