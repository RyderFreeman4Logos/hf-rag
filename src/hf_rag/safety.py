from __future__ import annotations

from typing import Any

FORBIDDEN_LOG_KEYS = frozenset(
    {"text", "content", "prompt", "goal", "target", "response", "messages", "document", "sample", "preview"}
)


def safe_event(event: str, **fields: Any) -> dict[str, Any]:
    """Return a structured log record that cannot hold corpus-bearing fields."""
    unsafe = FORBIDDEN_LOG_KEYS.intersection(fields)
    if unsafe:
        raise ValueError(f"unsafe log key: {sorted(unsafe)[0]}")
    return {"event": event, **fields}
