from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any, Mapping, Sequence


@dataclass(frozen=True)
class Record:
    record_id: str
    point_id: int
    content_hash: str
    text: str
    metadata: dict[str, str | int]


def _string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(part for item in value if (part := _string(item)))
    if isinstance(value, Mapping):
        for key in ("content", "text", "value", "message"):
            if (part := _string(value.get(key))):
                return part
    return ""


def build_record(
    *, dataset_path: str, row_index: int, row: Mapping[str, Any], field_priority: Sequence[str], dataset_id: str,
    split: str = "unknown", language: str = "unknown", max_chars: int = 24_000,
) -> Record | None:
    """Build a deterministic retrieval record without serializing raw fields elsewhere."""
    canonical = {str(key).casefold(): value for key, value in row.items()}
    values: list[str] = []
    seen: set[str] = set()
    for field in field_priority:
        key = field.casefold()
        if key in seen:
            continue
        seen.add(key)
        if (value := _string(canonical.get(key))):
            values.append(value)
    text = "\n\n".join(values).strip()
    if not text:
        return None
    text = text[:max_chars]
    content_hash = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
    stable = f"{dataset_path}\0{row_index}\0{content_hash}".encode("utf-8")
    stable_hash = hashlib.sha256(stable).hexdigest()
    record_id = f"{dataset_id}-{stable_hash[:32]}"
    # Qdrant accepts only unsigned integers or UUIDs as point IDs.
    point_id = int(stable_hash[:16], 16)
    return Record(
        record_id=record_id,
        point_id=point_id,
        content_hash=content_hash,
        text=text,
        metadata={
            "dataset_id": dataset_id,
            "split": split,
            "language": language,
            "record_id": record_id,
            "content_hash": content_hash,
            "source_path": dataset_path,
            "row_index": row_index,
        },
    )
