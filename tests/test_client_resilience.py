from __future__ import annotations

from typing import Any

import httpx
import pytest

from hf_rag.client import RAGClient, ServiceError
from hf_rag.config import Config


class SequencedGB10:
    def __init__(self, outcomes: list[httpx.Response | Exception]) -> None:
        self.outcomes = outcomes
        self.calls: list[dict[str, Any]] = []

    def close(self) -> None:
        pass

    def post(self, _url: str, **kwargs: Any) -> httpx.Response:
        self.calls.append(kwargs)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def _client_with(
    outcomes: list[httpx.Response | Exception], config: Config | None = None
) -> tuple[RAGClient, SequencedGB10]:
    client = RAGClient(config or Config())
    fake = SequencedGB10(outcomes)
    client.gb10.close()
    client.gb10 = fake  # type: ignore[assignment]
    return client, fake


def test_embed_retries_transient_status_without_logging_input(monkeypatch: pytest.MonkeyPatch) -> None:
    from hf_rag import client as client_module

    client, fake = _client_with(
        [
            httpx.Response(503),
            httpx.Response(503),
            httpx.Response(200, json={"data": [{"embedding": [0.0] * 4096}]}),
        ]
    )
    monkeypatch.setattr(client_module.time, "sleep", lambda _seconds: None)

    try:
        assert client.embed(["synthetic benign source"]) == [[0.0] * 4096]
    finally:
        client.close()

    assert len(fake.calls) == 3
    assert all(call["json"]["input"] == ["synthetic benign source"] for call in fake.calls)


def test_rerank_retries_network_error_without_logging_input(monkeypatch: pytest.MonkeyPatch) -> None:
    from hf_rag import client as client_module

    client, fake = _client_with(
        [
            httpx.ConnectError("synthetic benign source"),
            httpx.Response(200, json={"results": [{"index": 0, "score": 0.75}]}),
        ]
    )
    monkeypatch.setattr(client_module.time, "sleep", lambda _seconds: None)

    try:
        assert client.rerank("synthetic benign source", ["synthetic benign source"]) == [0.75]
    finally:
        client.close()

    assert len(fake.calls) == 2


def test_exhausted_transient_error_is_short_and_never_contains_input(monkeypatch: pytest.MonkeyPatch) -> None:
    from hf_rag import client as client_module

    text = "synthetic benign source"
    client, fake = _client_with([httpx.Response(502) for _ in range(3)], Config(gb10_max_attempts=3))
    monkeypatch.setattr(client_module.time, "sleep", lambda _seconds: None)

    try:
        with pytest.raises(ServiceError) as exc_info:
            client.embed([text])
    finally:
        client.close()

    assert len(fake.calls) == 3
    assert str(exc_info.value) == "embedding: HTTP 502 after 3 attempts"
    assert text not in str(exc_info.value)


def test_default_gb10_retry_budget_is_extreme() -> None:
    config = Config()

    assert config.timeout_seconds >= 540
    assert config.gb10_max_attempts >= 50
    assert config.retry_max_sleep_seconds >= 120


def test_cli_disables_typer_pretty_exceptions() -> None:
    from hf_rag.cli import app

    assert app.pretty_exceptions_enable is False
    assert app.pretty_exceptions_show_locals is False
