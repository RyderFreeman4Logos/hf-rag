from __future__ import annotations

import hashlib
import tarfile
from pathlib import Path
from typing import Any

import zstandard as zstd

from .readers import safe_file_metadata, should_skip_path

_FORBIDDEN = frozenset({"text", "content", "prompt", "goal", "target", "response", "messages", "sample", "preview", "row", "body"})


def validate_structure_payload(value: Any) -> None:
    """Reject probe structures that could contain corpus values, recursively."""
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).casefold() in _FORBIDDEN:
                raise ValueError(f"unsafe structure key: {key}")
            validate_structure_payload(child)
    elif isinstance(value, list):
        for child in value:
            validate_structure_payload(child)
    elif not isinstance(value, (str, int, float, bool, type(None))):
        raise ValueError(f"unsupported structure value: {type(value).__name__}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def probe_archive(path: Path) -> dict[str, Any]:
    """Read only file structure, schema names and row counts from a zstd tar stream."""
    files: list[dict[str, Any]] = []
    with path.open("rb") as raw, zstd.ZstdDecompressor().stream_reader(raw) as decompressed:
        with tarfile.open(fileobj=decompressed, mode="r|") as archive:
            for member in archive:
                if not member.isfile() or should_skip_path(member.name):
                    continue
                entry = archive.extractfile(member)
                if entry is None:
                    continue
                with entry:
                    files.append(safe_file_metadata(member.name, entry, member.size))
    payload = {
        "archive": {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)},
        "files": files,
        "totals": {"files": len(files), "rows": sum(int(item.get("rows", 0)) for item in files)},
    }
    validate_structure_payload(payload)
    return payload
