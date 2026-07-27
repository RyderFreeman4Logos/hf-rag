from __future__ import annotations

import hashlib
import math
import re
from collections import Counter

_TOKEN_RE = re.compile(r"[\w\u4e00-\u9fff]+", re.UNICODE)


def _index(token: str) -> int:
    return int.from_bytes(hashlib.blake2b(token.encode("utf-8"), digest_size=4).digest(), "big")


def sparse_vector(text: str) -> dict[str, list[int] | list[float]]:
    """Produce deterministic TF weights; Qdrant's sparse modifier applies corpus IDF."""
    counts = Counter(token.casefold() for token in _TOKEN_RE.findall(text))
    pairs = sorted((_index(token), 1.0 + math.log(count)) for token, count in counts.items())
    return {"indices": [index for index, _ in pairs], "values": [weight for _, weight in pairs]}
