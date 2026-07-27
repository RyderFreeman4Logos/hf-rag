from __future__ import annotations

import csv
import io
import json
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Iterator

import ijson
import zstandard as zstd

SUPPORTED = frozenset({".csv", ".jsonl", ".json", ".parquet"})
_SKIP_NAMES = frozenset({"readme.md", "readme", "dataset_info.json", "state.json"})
_SKIP_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp", ".lock"})


def _require_pyarrow():
    try:
        import pyarrow.parquet as pq
    except ImportError as exc:  # pragma: no cover - optional dep
        raise RuntimeError(
            "parquet support requires optional extra: uv tool install --from . 'hf-rag[parquet]'"
        ) from exc
    return pq


@dataclass(frozen=True)
class RowItem:
    dataset_path: str
    row_index: int
    row: dict[str, Any]


def should_skip_path(name: str) -> bool:
    path = Path(name)
    lower = name.casefold()
    return (
        ".cache/" in lower
        or path.name.casefold() in _SKIP_NAMES
        or path.suffix.casefold() in _SKIP_SUFFIXES
        or path.suffix.casefold() not in SUPPORTED
        or "/metadata/" in lower
    )


class _StreamAdapter(io.RawIOBase):
    """Make tar's forward-only member stream acceptable to text decoders."""

    def __init__(self, stream: BinaryIO) -> None:
        self._stream = stream

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return False

    def writable(self) -> bool:
        return False

    def readinto(self, buffer: bytearray) -> int:
        data = self._stream.read(len(buffer))
        count = len(data)
        buffer[:count] = data
        return count

    def close(self) -> None:
        # The tar loop owns and closes the member stream.
        return None


def _text_stream(file: BinaryIO, *, encoding: str, newline: str | None = None) -> io.TextIOWrapper:
    return io.TextIOWrapper(io.BufferedReader(_StreamAdapter(file)), encoding=encoding, errors="replace", newline=newline)


def _csv_rows(file: BinaryIO) -> Iterator[dict[str, Any]]:
    with _text_stream(file, encoding="utf-8-sig", newline="") as text:
        yield from csv.DictReader(text)


def _jsonl_rows(file: BinaryIO) -> Iterator[dict[str, Any]]:
    with _text_stream(file, encoding="utf-8") as text:
        for line in text:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                yield value


class _PrependReader:
    """Minimal non-seeking binary reader which replays a sniffed prefix."""

    def __init__(self, prefix: bytes, stream: BinaryIO) -> None:
        self._prefix = prefix
        self._stream = stream

    def read(self, size: int = -1) -> bytes:
        if size < 0:
            result, self._prefix = self._prefix, b""
            return result + self._stream.read()
        prefix = self._prefix[:size]
        self._prefix = self._prefix[len(prefix):]
        return prefix + self._stream.read(size - len(prefix))


def _json_rows(file: BinaryIO) -> Iterator[dict[str, Any]]:
    prefix = file.read(4096)
    first = prefix.lstrip()[:1]
    replay = _PrependReader(prefix, file)
    if first == b"[":
        for value in ijson.items(replay, "item"):
            if isinstance(value, dict):
                yield value
    elif first == b"{":
        # A JSON object represents one row; common large arrays are handled above.
        value = next(ijson.items(replay, ""), None)
        if isinstance(value, dict):
            yield value


def _parquet_rows(file: BinaryIO) -> Iterator[dict[str, Any]]:
    # Parquet footer access requires seeks; spool just this member, never the archive.
    pq = _require_pyarrow()
    with tempfile.NamedTemporaryFile(suffix=".parquet") as tmp:
        while chunk := file.read(1024 * 1024):
            tmp.write(chunk)
        tmp.flush()
        parquet = pq.ParquetFile(tmp.name)
        for batch in parquet.iter_batches(batch_size=128):
            for row in batch.to_pylist():
                yield row


def _rows_from_stream(path: str, file: BinaryIO) -> Iterator[dict[str, Any]]:
    suffix = Path(path).suffix.casefold()
    if suffix == ".csv":
        yield from _csv_rows(file)
    elif suffix == ".jsonl":
        yield from _jsonl_rows(file)
    elif suffix == ".json":
        yield from _json_rows(file)
    elif suffix == ".parquet":
        yield from _parquet_rows(file)


def iter_rows(source: Path) -> Iterator[RowItem]:
    """Yield records one at a time from a safe directory or zstd-compressed tar archive."""
    if source.is_dir():
        for item in sorted(source.rglob("*")):
            if not item.is_file():
                continue
            relative = item.relative_to(source).as_posix()
            if should_skip_path(relative):
                continue
            with item.open("rb") as stream:
                for index, row in enumerate(_rows_from_stream(relative, stream)):
                    yield RowItem(relative, index, row)
        return
    if source.is_file() and source.suffix.casefold() in SUPPORTED:
        with source.open("rb") as stream:
            for index, row in enumerate(_rows_from_stream(source.name, stream)):
                yield RowItem(source.name, index, row)
        return
    with source.open("rb") as raw, zstd.ZstdDecompressor().stream_reader(raw) as decompressed:
        with tarfile.open(fileobj=decompressed, mode="r|") as archive:
            for member in archive:
                if not member.isfile() or should_skip_path(member.name):
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    continue
                with extracted:
                    for index, row in enumerate(_rows_from_stream(member.name, extracted)):
                        yield RowItem(member.name, index, row)


def safe_file_metadata(path: str, file: BinaryIO, byte_size: int) -> dict[str, Any]:
    """Return names/counts only. Never return a data value or row representation."""
    suffix = Path(path).suffix.casefold()
    columns: list[str] = []
    rows = 0
    error: str | None = None
    try:
        if suffix == ".parquet":
            pq = _require_pyarrow()
            with tempfile.NamedTemporaryFile(suffix=".parquet") as tmp:
                while chunk := file.read(1024 * 1024):
                    tmp.write(chunk)
                tmp.flush()
                meta = pq.ParquetFile(tmp.name).metadata
                columns = list(pq.ParquetFile(tmp.name).schema.names)
                rows = meta.num_rows
        elif suffix == ".csv":
            with _text_stream(file, encoding="utf-8-sig", newline="") as text:
                reader = csv.reader(text)
                columns = [str(c) for c in next(reader, [])]
                rows = sum(1 for _ in reader)
        elif suffix in {".jsonl", ".json"}:
            for row in _rows_from_stream(path, file):
                if not columns:
                    columns = sorted(str(k) for k in row)
                rows += 1
    except (OSError, ValueError, AttributeError, EOFError, json.JSONDecodeError, tarfile.TarError) as exc:
        error = type(exc).__name__
    result: dict[str, Any] = {"path": path, "bytes": byte_size, "format": suffix.removeprefix(".")}
    if columns:
        result["columns"] = columns
    result["rows"] = rows
    if error:
        result["error_type"] = error
    return result
