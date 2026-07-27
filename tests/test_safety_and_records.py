from __future__ import annotations

import json
from pathlib import Path

import pytest


def test_safe_event_never_contains_text_values() -> None:
    from hf_rag.safety import safe_event

    event = safe_event("row_skipped", dataset_id="demo", row=3, reason="empty_text")
    assert event == {"event": "row_skipped", "dataset_id": "demo", "row": 3, "reason": "empty_text"}
    with pytest.raises(ValueError, match="unsafe log key"):
        safe_event("bad", text="synthetic benign source")


def test_row_to_record_prioritizes_configured_fields_without_exposing_value() -> None:
    from hf_rag.records import build_record

    record = build_record(
        dataset_path="demo/data.csv",
        row_index=7,
        row={"prompt": "alpha", "answer": "beta", "unused": "gamma"},
        field_priority=["prompt", "answer", "text"],
        dataset_id="demo",
    )
    assert record.record_id.startswith("demo-")
    assert 0 <= record.point_id < 2**64
    assert len(record.content_hash) == 64
    assert record.text == "alpha\n\nbeta"
    assert record.metadata["dataset_id"] == "demo"
    assert record.metadata["record_id"] == record.record_id


def test_archive_probe_json_contains_only_structure(tmp_path: Path) -> None:
    from hf_rag.probe import validate_structure_payload

    payload = {
        "archive": {"path": "/safe/path.tar.zst", "sha256": "0" * 64, "bytes": 12},
        "files": [{"path": "demo.csv", "bytes": 4, "format": "csv", "columns": ["prompt"]}],
        "totals": {"files": 1, "rows": 1},
    }
    validate_structure_payload(payload)
    p = tmp_path / "structure.json"
    p.write_text(json.dumps(payload), encoding="utf-8")
    assert "alpha" not in p.read_text(encoding="utf-8")
    with pytest.raises(ValueError, match="unsafe structure key"):
        validate_structure_payload({"files": [{"path": "x", "sample": "do not write text"}]})


def test_sparse_tokenization_is_deterministic_and_nonempty() -> None:
    from hf_rag.sparse import sparse_vector

    one = sparse_vector("hello world hello")
    two = sparse_vector("hello world hello")
    assert one == two
    assert len(one["indices"]) == 2
    assert all(value > 0 for value in one["values"])
