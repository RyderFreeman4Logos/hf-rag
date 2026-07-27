from __future__ import annotations

import csv
from pathlib import Path


def test_iter_rows_directory_reads_benign_csv_without_text_in_event(tmp_path: Path) -> None:
    from hf_rag.readers import iter_rows

    source = tmp_path / "demo.csv"
    with source.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["prompt", "answer"])
        writer.writeheader()
        writer.writerow({"prompt": "benign alpha", "answer": "benign beta"})
    items = list(iter_rows(source))
    assert [(item.dataset_path, item.row_index, sorted(item.row)) for item in items] == [
        ("demo.csv", 0, ["answer", "prompt"])
    ]


def test_should_skip_cache_readme_and_images() -> None:
    from hf_rag.readers import should_skip_path

    assert should_skip_path("x/.cache/a.parquet")
    assert should_skip_path("x/README.md")
    assert should_skip_path("x/image.png")
    assert not should_skip_path("x/data.csv")
