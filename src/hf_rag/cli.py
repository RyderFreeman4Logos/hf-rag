from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Annotated

import typer

from .client import RAGClient, ServiceError
from .config import load_config
from .ingest import ingest, qdrant_rss_mib
from .probe import probe_archive
from .safety import safe_event
from .sparse import sparse_vector

app = typer.Typer(
    add_completion=False,
    no_args_is_help=True,
    pretty_exceptions_enable=False,
    pretty_exceptions_show_locals=False,
    rich_markup_mode=None,
)
ConfigOption = Annotated[Path | None, typer.Option("--config", exists=True, readable=True)]


def _emit(value: dict[str, object]) -> None:
    print(json.dumps(value, sort_keys=True), flush=True)


def _run_client(config: ConfigOption, fn) -> None:
    cfg = load_config(config)
    client = RAGClient(cfg)
    try:
        fn(client, cfg)
    except ServiceError as exc:
        _emit(safe_event("error", error_type=type(exc).__name__, message=str(exc)))
        raise SystemExit(2) from None
    finally:
        client.close()


@app.command("create-collection")
def create_collection(config: ConfigOption = None) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        client.create_collection()
        _emit(safe_event("collection_ready"))

    _run_client(config, _go)


@app.command()
def doctor(config: ConfigOption = None) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        if not client.health():
            raise ServiceError("qdrant health unavailable")
        vectors = client.embed(["hello world", "测试文档"])
        if any(len(vector) != 4096 for vector in vectors):
            raise ServiceError("embedding dimension mismatch")
        scores = client.rerank("capacity planning documentation", ["hello world", "测试文档"])
        if len(scores) != 2:
            raise ServiceError("rerank result count mismatch")
        terms = len(sparse_vector("hello world 测试文档")["indices"])
        if terms == 0:
            raise ServiceError("bm25 fixture empty")
        _emit(safe_event("doctor_ok", embedding_dim=4096, bm25_fixture_terms=terms, rerank_results=len(scores)))

    _run_client(config, _go)


@app.command("ingest")
def ingest_cmd(source: Annotated[Path, typer.Argument(exists=True, readable=True)], config: ConfigOption = None) -> None:
    try:
        stats = ingest(source, load_config(config))
        _emit(safe_event("ingest_return", **stats.as_dict()))
    except ServiceError as exc:
        _emit(safe_event("error", error_type=type(exc).__name__, message=str(exc)))
        raise SystemExit(2) from None


@app.command()
def resume(source: Annotated[Path, typer.Argument(exists=True, readable=True)], config: ConfigOption = None) -> None:
    ingest_cmd(source, config)


@app.command("safe-probe")
def safe_probe(source: Annotated[Path, typer.Argument(exists=True, readable=True)], output: Annotated[Path, typer.Option("--output")]) -> None:
    payload = probe_archive(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _emit(safe_event("probe_complete", files=payload["totals"]["files"], rows=payload["totals"]["rows"]))


@app.command("search-json")
def search_json(
    config: ConfigOption = None,
    include_text: Annotated[bool, typer.Option("--include-text", help="Include payload text (for interactive review only)")] = False,
) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                query = request.get("query") if isinstance(request, dict) else None
                limit = request.get("limit", 20) if isinstance(request, dict) else 20
                want_text = include_text
                if isinstance(request, dict) and "include_text" in request:
                    want_text = bool(request.get("include_text"))
                if not isinstance(query, str) or not isinstance(limit, int) or not 1 <= limit <= 64:
                    raise ValueError("invalid request")
                _emit({"results": client.safe_hits(client.search(query, limit), include_text=want_text)})
            except (ValueError, ServiceError, OSError) as exc:
                _emit({"error_type": type(exc).__name__, "message": str(exc) if isinstance(exc, ServiceError) else type(exc).__name__})

    _run_client(config, _go)


@app.command()
def search(
    query: Annotated[str, typer.Option("--query")],
    limit: Annotated[int, typer.Option("--limit")] = 20,
    include_text: Annotated[bool, typer.Option("--include-text")] = False,
    config: ConfigOption = None,
) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        _emit({"results": client.safe_hits(client.search(query, limit), include_text=include_text)})

    _run_client(config, _go)


@app.command()
def stats(config: ConfigOption = None) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        _emit(safe_event("stats", point_count=client.count(), qdrant_rss_mib=qdrant_rss_mib()))

    _run_client(config, _go)


@app.command()
def verify(config: ConfigOption = None) -> None:
    def _go(client: RAGClient, _cfg) -> None:
        _emit(safe_event("verify", health=client.health(), point_count=client.count(), qdrant_rss_mib=qdrant_rss_mib()))

    _run_client(config, _go)


if __name__ == "__main__":
    app()
