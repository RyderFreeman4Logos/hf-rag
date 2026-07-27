from __future__ import annotations

import threading
from pathlib import Path

import pytest

from hf_rag.checkpoint import Checkpoint
from hf_rag.client import ServiceError
from hf_rag.config import Config, DatasetRule
from hf_rag.readers import RowItem


def test_records_use_generic_text_fallback_and_count_only_pure_empty_rows(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from hf_rag import ingest as ingest_module

    rows = [
        RowItem("synthetic/data.jsonl", 0, {"body": "synthetic benign fallback"}),
        RowItem("synthetic/data.jsonl", 1, {"id": "metadata-only"}),
        RowItem("synthetic/data.jsonl", 2, {"prompt": "synthetic benign configured"}),
    ]
    monkeypatch.setattr(ingest_module, "iter_rows", lambda _source: iter(rows))
    stats = ingest_module.IngestStats()

    config = Config(rules=(DatasetRule(fields=("prompt",)),))
    records = list(ingest_module.records_from_source(Path("synthetic"), config, stats))

    assert len(records) == 2
    assert stats.scanned == 3
    assert stats.skipped == 1
    assert stats.skip_reasons == {"empty_text": 1}
    assert stats.as_dict()["skipped_empty"] == 1


class _ConcurrentClient:
    def __init__(self, _config: Config) -> None:
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()
        self.all_started = threading.Event()
        self.upserts = 0

    def embed(self, texts: list[str]) -> list[list[float]]:
        with self.lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            if self.active >= 8:
                self.all_started.set()
        assert self.all_started.wait(timeout=2), "embed requests were not concurrent"
        with self.lock:
            self.active -= 1
        return [[0.0] * 4096 for _ in texts]

    def upsert(self, _points: list[dict[str, object]]) -> None:
        self.upserts += 1

    def close(self) -> None:
        pass


def test_ingest_keeps_eight_embedding_requests_in_flight(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from hf_rag import ingest as ingest_module

    rows = [
        RowItem("synthetic/data.jsonl", index, {"prompt": f"synthetic {index}"})
        for index in range(8)
    ]
    holder: dict[str, _ConcurrentClient] = {}

    def client_factory(config: Config) -> _ConcurrentClient:
        client = _ConcurrentClient(config)
        holder["client"] = client
        return client

    monkeypatch.setattr(ingest_module, "iter_rows", lambda _source: iter(rows))
    monkeypatch.setattr(ingest_module, "RAGClient", client_factory)
    monkeypatch.setattr(ingest_module, "wait_for_resources", lambda _config: None)

    stats = ingest_module.ingest(
        Path("synthetic"),
        Config(
            checkpoint=tmp_path / "checkpoint.sqlite3",
            embed_batch_size=1,
            upsert_batch_size=1,
            embed_concurrency=8,
        ),
        progress_every=100,
    )

    assert stats.upserted == 8
    assert holder["client"].max_active == 8
    assert holder["client"].upserts == 8
    output = capsys.readouterr().out
    assert '"embed_concurrency": 8' in output
    assert "synthetic" not in output


class _FailingClient:
    def __init__(self, _config: Config) -> None:
        pass

    def embed(self, _texts: list[str]) -> list[list[float]]:
        raise ServiceError("embedding: HTTP 503 after 100 attempts")

    def close(self) -> None:
        pass


def test_embedding_failure_is_loud_and_does_not_become_a_skip(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from hf_rag import ingest as ingest_module

    rows = [RowItem("synthetic/data.jsonl", 0, {"prompt": "synthetic benign"})]
    checkpoint_path = tmp_path / "checkpoint.sqlite3"
    monkeypatch.setattr(ingest_module, "iter_rows", lambda _source: iter(rows))
    monkeypatch.setattr(ingest_module, "RAGClient", _FailingClient)
    monkeypatch.setattr(ingest_module, "wait_for_resources", lambda _config: None)

    with pytest.raises(ServiceError, match="after 100 attempts"):
        ingest_module.ingest(Path("synthetic"), Config(checkpoint=checkpoint_path))

    checkpoint = Checkpoint(checkpoint_path)
    try:
        assert checkpoint.count() == 0
    finally:
        checkpoint.close()
