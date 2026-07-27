# hf-rag — low-memory, safe hybrid RAG

This project indexes a Hugging Face-style archive into **Qdrant 1.18.3** with named 4096-dim cosine dense vectors and Qdrant-IDF sparse vectors, server-side **RRF**, and mandatory GB10 reranking. It is intentionally a replacement for a RAGFlow deployment, not an add-on to it.

## Hard operating envelope

| Component | Enforced limit | Swap |
|---|---:|---:|
| Qdrant container | `mem_limit=768m` | `memswap_limit=768m` (no swap) |
| ingest `ragctl` user service | `MemoryMax=256M` | `MemorySwapMax=0` |
| steady combined budget | **<= 1 GiB** | **none** |

Qdrant uses one worker/search/optimization/indexing thread, a small WAL, disk-backed dense/sparse/HNSW/payload data, HNSW `m=8`, and collection strict mode at 80%. Ingest is single-concurrency with embedding batches of four and upserts no larger than eight. Search is a short-lived client process; do not run multiple searches while ingest is active.

## Safety policy

`datasets.tar.zst` may contain hostile evaluation content. The implementation **never prints corpus text**:

- No data values, prompts, goals, targets, responses, README bodies, cell values, or text previews in CLI output, logs, checkpoints, structure probes, or search responses.
- Probe output contains only archive/file paths, sizes, SHA-256, format, column **names**, row counts, and error **types**.
- Checkpoints retain only deterministic record IDs and content hashes.
- `search-json` stdin/stdout returns metadata and scores, never retrieved text. It does send selected text directly to the configured GB10 reranker as required; neither request nor response content is logged.
- GB10 embedding/reranking retries only transient network, 408, 429, and 5xx failures with bounded exponential backoff; final errors contain only operation/status or exception type and attempt count.
- The Typer CLI disables Rich pretty exceptions and local-variable rendering, so request payloads cannot be dumped in a traceback.
- Tests use only synthetic benign strings.

Do not `cat`, `head`, `tar -xOf`, `jq`, dataframe-print, or otherwise render the corpus or quarantine paths.

## Deploy on `obj@mp`

From the development host, copy without emitting archive content:

```sh
rsync -a --delete /home/obj/project/github/RyderFreeman4Logos/hf-rag/ \
  obj@mp:/home/obj/srv/hf-rag/app/
ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/install-on-mp.sh
```

The installer refuses a non-`obj` identity or a non-rootless Docker context, creates only `/home/obj/srv/{hf-rag,qdrant}`, produces 0600 secrets/configuration, creates the collection and payload indexes, and enables `qdrant.user.service`. User linger must be enabled (`loginctl show-user obj -p Linger`).

If GB10 uses a bearer key, supply it only as an environment variable to the installer; otherwise leave it empty only if the endpoint accepts unauthenticated requests:

```sh
GB10_API_KEY='…' ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/install-on-mp.sh
```

## Install inside `raven-box hermes-shell ai-safety`

`ragctl` is intentionally installed from a **local checkout**, not PyPI, and does not need `sudo`. From an `obj@mp` Hermes shell:

```sh
raven-box hermes-shell ai-safety
bash /home/obj/srv/hf-rag/app/scripts/install-with-mise.sh
# Start a new shell, or activate mise in the current Bash shell:
eval "$(mise activate bash)"
ragctl --help
```

The same command works from any checkout path; on the host deployment that path is `/home/obj/srv/hf-rag/app`. The installer prefers `uv tool install --from <local-checkout> ragctl`, runs `mise reshim`, and writes an explicit user-owned mise shim. If `uv` is unavailable it uses a dedicated venv under `$XDG_DATA_HOME/hf-rag/venv` (default `~/.local/share/hf-rag/venv`). If `mise` is missing it attempts the official `https://mise.run` bootstrap only when `curl` and network access are available; otherwise install mise first and rerun. It never requires `sudo`.

From the checkout, the equivalent task entry points are:

```sh
mise run install
mise run upgrade
RAGCTL_CONFIG=/home/obj/srv/hf-rag/etc/ragctl.toml mise run doctor-smoke
```

`doctor-smoke` sends only the built-in benign fixtures (`hello world` and a fixed test query); it never reads an archive.

## Safe probe, ingest, verification

```sh
# Writes /home/obj/srv/hf-rag/structure.json with structure only.
ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/safe-probe-archive.sh

# Runs under the 256 MiB/no-swap user systemd service; output is counts only.
ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/ingest-datasets.sh

ssh -o BatchMode=yes obj@mp 'set -a; . /home/obj/srv/hf-rag/etc/ragctl.env; set +a; \
 /home/obj/srv/hf-rag/app/.venv/bin/ragctl doctor --config /home/obj/srv/hf-rag/etc/ragctl.toml; \
 /home/obj/srv/hf-rag/app/.venv/bin/ragctl verify --config /home/obj/srv/hf-rag/etc/ragctl.toml; \
 docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

`doctor` calls live Qdrant, embeddings (expects exactly 4096 dimensions), a benign sparse fixture, and the live GB10 reranker. It is not a configuration-only check. Ingest pauses below the configured `MemAvailable` gate, stops when Qdrant RSS is above 700 MiB, and rejects insufficient disk (default 1 GiB free; deliberately not a spurious tens-of-GiB requirement).

## Commands

- `ragctl create-collection`, `doctor`, `ingest PATH`, `resume PATH`, `stats`, `verify`
- `ragctl safe-probe ARCHIVE --output structure.json`
- `ragctl search-json --config FILE` — one JSON request per stdin line: `{"query":"…","limit":8}`; only result IDs/hashes/metadata/scores are returned.
- `ragctl search --query '…'` — same safe output.

All production configuration belongs in `/home/obj/srv/hf-rag/etc/`, never in Git.
