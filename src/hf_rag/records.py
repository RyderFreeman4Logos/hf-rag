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


_GENERIC_NON_TEXT_FIELDS = frozenset(
    {
        "id", "_id", "uuid", "index", "row_index", "split", "language", "lang", "category",
        "label", "labels", "dataset", "dataset_id", "task", "score", "rank", "metadata", "meta",
    }
)


def _string(value: Any, *, depth: int = 0) -> str:
    """Extract text from common HF nested values without serializing it anywhere else."""
    if depth > 8:
        return ""
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(part for item in value if (part := _string(item, depth=depth + 1)))
    if isinstance(value, Mapping):
        for key in ("content", "text", "value", "message"):
            if (part := _string(value.get(key), depth=depth + 1)):
                return part
        return "\n".join(
            part for item in value.values() if (part := _string(item, depth=depth + 1))
        )
    return ""


def _has_textual_value(value: Any, *, depth: int = 0) -> bool:
    """Keep generic fallback from turning numeric-only metadata into retrieval documents."""
    if depth > 8:
        return False
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, list):
        return any(_has_textual_value(item, depth=depth + 1) for item in value)
    if isinstance(value, Mapping):
        return any(_has_textual_value(item, depth=depth + 1) for item in value.values())
    return False


def _retrieval_text(row: Mapping[str, Any], field_priority: Sequence[str]) -> str:
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

    # HF datasets vary substantially. If configured fields are absent, retain any
    # textual, non-metadata field rather than silently discarding a valid source row.
    if not values:
        for key, raw_value in canonical.items():
            if key in seen or key in _GENERIC_NON_TEXT_FIELDS or not _has_textual_value(raw_value):
                continue
            if (value := _string(raw_value)):
                values.append(value)
    return "\n\n".join(values).strip()


def build_record(
    *, dataset_path: str, row_index: int, row: Mapping[str, Any], field_priority: Sequence[str], dataset_id: str,
    split: str = "unknown", language: str = "unknown", max_chars: int = 24_000,
) -> Record | None:
    """Build a deterministic retrieval record without serializing raw fields elsewhere."""
    text = _retrieval_text(row, field_priority)
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
