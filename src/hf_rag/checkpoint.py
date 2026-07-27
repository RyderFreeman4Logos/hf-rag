from __future__ import annotations

import sqlite3
from pathlib import Path


class Checkpoint:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS completed (record_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL)"
        )

    def seen(self, record_id: str) -> bool:
        return self.conn.execute("SELECT 1 FROM completed WHERE record_id = ?", (record_id,)).fetchone() is not None

    def mark_done(self, record_id: str, content_hash: str) -> None:
        self.conn.execute(
            "INSERT OR IGNORE INTO completed(record_id, content_hash) VALUES (?, ?)", (record_id, content_hash)
        )
        self.conn.commit()

    def mark_many(self, pairs: list[tuple[str, str]]) -> None:
        self.conn.executemany("INSERT OR IGNORE INTO completed(record_id, content_hash) VALUES (?, ?)", pairs)
        self.conn.commit()

    def count(self) -> int:
        return int(self.conn.execute("SELECT COUNT(*) FROM completed").fetchone()[0])

    def close(self) -> None:
        self.conn.close()
