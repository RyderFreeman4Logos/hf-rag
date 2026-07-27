from __future__ import annotations

from pathlib import Path


def test_checkpoint_round_trip(tmp_path: Path) -> None:
    from hf_rag.checkpoint import Checkpoint

    checkpoint = Checkpoint(tmp_path / "state.sqlite3")
    assert not checkpoint.seen("id-1")
    checkpoint.mark_done("id-1", "a" * 64)
    assert checkpoint.seen("id-1")
    assert checkpoint.count() == 1
    checkpoint.close()
