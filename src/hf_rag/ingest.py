from __future__ import annotations

import json
import re
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

from .checkpoint import Checkpoint
from .client import RAGClient
from .config import Config
from .readers import iter_rows
from .records import Record, build_record
from .safety import safe_event
from .sparse import sparse_vector


class ResourceError(RuntimeError):
    pass


@dataclass
class IngestStats:
    scanned: int = 0
    accepted: int = 0
    skipped: int = 0
    upserted: int = 0
    batches: int = 0

    def as_dict(self) -> dict[str, int]:
        return {"scanned": self.scanned, "accepted": self.accepted, "skipped": self.skipped, "upserted": self.upserted, "batches": self.batches}


def mem_available_mib() -> int:
    with Path("/proc/meminfo").open(encoding="ascii") as file:
        for line in file:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    return 0


def qdrant_rss_mib() -> float | None:
    container = subprocess.run(
        ["docker", "ps", "--filter", "label=com.docker.compose.service=qdrant", "--format", "{{.ID}}"],
        text=True, capture_output=True, check=False,
    ).stdout.strip().splitlines()
    if not container:
        return None
    output = subprocess.run(
        ["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", container[0]],
        text=True, capture_output=True, check=False,
    ).stdout.strip()
    used = output.partition("/")[0].strip()
    match = re.fullmatch(r"([0-9.]+)\s*([KMGT]?i?B)", used, flags=re.IGNORECASE)
    if match is None:
        return None
    number = float(match.group(1))
    unit = match.group(2).casefold()
    if unit.startswith("g"):
        return number * 1024
    if unit.startswith("k"):
        return number / 1024
    if unit.startswith("b"):
        return number / (1024 * 1024)
    return number


def wait_for_resources(config: Config) -> None:
    if shutil.disk_usage(config.checkpoint.parent).free // (1024 * 1024) < config.disk_free_mib:
        raise ResourceError("disk_free_below_gate")
    while mem_available_mib() < config.min_mem_available_mib:
        print(json.dumps(safe_event("paused", reason="low_mem_available"), sort_keys=True), flush=True)
        time.sleep(10)
    if (rss := qdrant_rss_mib()) is not None and rss > config.max_qdrant_rss_mib:
        raise ResourceError("qdrant_rss_above_gate")


def records_from_source(source: Path, config: Config, stats: IngestStats) -> Iterator[Record]:
    for item in iter_rows(source):
        stats.scanned += 1
        rule = config.rule_for(item.dataset_path)
        record = build_record(
            dataset_path=item.dataset_path, row_index=item.row_index, row=item.row, field_priority=rule.fields,
            dataset_id=rule.dataset_id, split=rule.split, language=rule.language,
        )
        if record is None:
            stats.skipped += 1
            continue
        yield record


def _to_points(records: list[Record], vectors: list[list[float]]) -> list[dict[str, Any]]:
    return [
        {"id": record.point_id, "vector": {"dense": vector, "bm25": sparse_vector(record.text)},
         "payload": {**record.metadata, "text": record.text}}
        for record, vector in zip(records, vectors, strict=True)
    ]


def ingest(source: Path, config: Config, *, progress_every: int = 100) -> IngestStats:
    """Sequential low-memory ingestion; progress is counts-only by construction."""
    stats = IngestStats()
    checkpoint = Checkpoint(config.checkpoint)
    client = RAGClient(config)
    batch: list[Record] = []
    try:
        for record in records_from_source(source, config, stats):
            if checkpoint.seen(record.record_id):
                stats.skipped += 1
                continue
            batch.append(record)
            stats.accepted += 1
            if len(batch) >= min(config.embed_batch_size, config.upsert_batch_size):
                wait_for_resources(config)
                vectors = client.embed([item.text for item in batch])
                client.upsert(_to_points(batch, vectors))
                checkpoint.mark_many([(item.record_id, item.content_hash) for item in batch])
                stats.upserted += len(batch)
                stats.batches += 1
                batch.clear()
                if stats.upserted % progress_every == 0:
                    print(json.dumps(safe_event("progress", **stats.as_dict()), sort_keys=True), flush=True)
        if batch:
            wait_for_resources(config)
            vectors = client.embed([item.text for item in batch])
            client.upsert(_to_points(batch, vectors))
            checkpoint.mark_many([(item.record_id, item.content_hash) for item in batch])
            stats.upserted += len(batch)
            stats.batches += 1
        print(json.dumps(safe_event("complete", **stats.as_dict()), sort_keys=True), flush=True)
        return stats
    finally:
        client.close()
        checkpoint.close()
