# hf-rag — low-memory, safe hybrid RAG

This project indexes a Hugging Face-style archive into **Qdrant 1.18.3** with named 4096-dim cosine dense vectors and Qdrant-IDF sparse vectors, server-side **RRF**, and mandatory GB10 reranking. It is intentionally a replacement for a RAGFlow deployment, not an add-on to it.

## Hard operating envelope

| Component | Enforced limit | Swap |
|---|---:|---:|
| Qdrant container | `mem_limit=768m` | `memswap_limit=768m` (no swap) |
| ingest `ragctl` user service | `MemoryMax=512M` | `MemorySwapMax=0` |
| steady combined budget | **<= 1 GiB** | **none** |

Qdrant uses one worker/search/optimization/indexing thread, a small WAL, disk-backed dense/sparse/HNSW/payload data, HNSW `m=8`, and collection strict mode at 80%. Ingest has up to eight concurrent GB10 embedding requests, embedding batches of four, and serial upserts no larger than eight. Search is a short-lived client process; do not run multiple searches while ingest is active.

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

## Credentials (XDG)

`ragctl.toml` is non-secret configuration. Keep API keys in a separate mode-`0600`
`credentials.toml`, using `deploy/credentials.toml.example` as the committed
placeholder-only shape:

```toml
[keys]
qdrant_api_key = "replace-with-qdrant-api-key"
gb10_api_key = "replace-with-gb10-api-key"
```

For each key, `ragctl` first honors its configured environment variable
(`QDRANT_API_KEY` or `GB10_API_KEY`) when it is set, then loads the first
available credentials file in this order: `RAGCTL_CREDENTIALS`,
`$XDG_CONFIG_HOME/hf-rag/credentials.toml`,
`~/.config/hf-rag/credentials.toml`, beside the resolved `ragctl.toml`,
`/opt/data/.config/hf-rag/credentials.toml`, then
`/home/obj/srv/hf-rag/etc/credentials.toml`. If neither source provides a key,
requests retain the existing authentication failure behavior. Do not source a
credentials file into a shell: `ragctl` reads it directly and never renders its
contents.

## Install inside a container / `raven-box hermes-shell ai-safety`

Preferred one-liner (pulls **GitHub `main`**, no sudo, no corpus access):

```sh
raven-box hermes-shell ai-safety
curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh | bash
# Hermes boxes often use HOME=/root while tools land under /opt/data:
export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$HOME/.local/bin:$PATH"
ragctl --help
```

### Why `ragctl` seemed broken after install

Two separate issues are common:

1. **PATH**: install puts binaries under `/opt/data/.local/bin` (or mise installs), but a fresh shell `PATH` may not include them → `ragctl: not found`.
2. **Network**: host Qdrant is published only on **host** `127.0.0.1:6333`. Inside the container that loopback is *not* the host, so default `http://127.0.0.1:6333` fails with connection refused.

Fix on the **host** (once per box):

```sh
# as obj@mp
sh /home/obj/srv/hf-rag/app/deploy/scripts/setup-container-client.sh hermes-ai-safety-hermes-1
```

This attaches Qdrant to `hermes-ai-safety_private`, writes non-secret
`/opt/data/.config/hf-rag/ragctl.toml` plus hermes-owned mode-`0600`
`credentials.toml`, and links `ragctl` onto PATH. `ragctl` discovers those
files directly; `path.sh` is optional and only adds PATH for interactive shells.

Then inside the shell:

```sh
export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$PATH"
ragctl doctor
ragctl stats
ragctl search --query 'capacity planning documentation'
```

What `install.sh` does:

1. Bootstraps **mise** (if missing) and ensures **uv** + **Python 3.11** via `mise use -g`.
2. **Primary:** `mise use -g -y 'pipx:git+https://github.com/RyderFreeman4Logos/hf-rag.git@main'`
3. **Fallback:** shallow-clone + `uv tool install --from <checkout> hf-rag` (console script `ragctl`) + mise shim.
4. Never requires `sudo`. Never reads corpus archives.

Host ingest of `.parquet` needs the optional extra (binary wheels):

```sh
# after install, on the host that runs ingest:
uv tool install --from "$HOME/.local/share/hf-rag/src" --force --reinstall-package hf-rag 'hf-rag[parquet]'
# or from a checkout:
uv tool install --from /home/obj/srv/hf-rag/app --force 'hf-rag[parquet]'
```

Container / Hermes shell usually only needs the base CLI (`search` / `doctor` against an already-running Qdrant).

Optional environment overrides (all non-interactive — safe under `curl | bash`):

| Variable | Default |
|---|---|
| `HF_RAG_REPO` | `https://github.com/RyderFreeman4Logos/hf-rag.git` |
| `HF_RAG_REF` | `main` |
| `HF_RAG_DIR` | `$XDG_DATA_HOME/hf-rag/src` |
| `UV_TOOL_BIN_DIR` | `$HOME/.local/bin` |

Example pin to a tag:

```sh
curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh \
  | HF_RAG_REF=v0.1.0 bash
```

### Offline / already-synced checkout

If the repo is already on disk (host deploy path):

```sh
bash /home/obj/srv/hf-rag/app/scripts/install-with-mise.sh
eval "$(mise activate bash)"
```

Or from any checkout:

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

# Optional systemd path: runs under the 512 MiB/no-swap user service; output is counts only.
ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/ingest-datasets.sh

# Preferred durable host path: start via nohup; counts-only output appends here.
ssh -o BatchMode=yes obj@mp /home/obj/srv/hf-rag/app/deploy/scripts/start-ingest-nohup.sh
# /home/obj/srv/hf-rag/logs/ingest.nohup.log

ssh -o BatchMode=yes obj@mp 'env -i HOME=/home/obj PATH=/home/obj/srv/hf-rag/app/.venv/bin:/usr/bin:/bin \
 ragctl doctor --config /home/obj/srv/hf-rag/etc/ragctl.toml; \
 env -i HOME=/home/obj PATH=/home/obj/srv/hf-rag/app/.venv/bin:/usr/bin:/bin \
 ragctl verify --config /home/obj/srv/hf-rag/etc/ragctl.toml; \
 docker stats --no-stream --format "{{.Name}} {{.MemUsage}}"'
```

`doctor` calls live Qdrant, embeddings (expects exactly 4096 dimensions), a benign sparse fixture, and the live GB10 reranker. It is not a configuration-only check. Ingest pauses below the configured `MemAvailable` gate, stops when Qdrant RSS is above 700 MiB, and rejects insufficient disk (default 1 GiB free; deliberately not a spurious tens-of-GiB requirement).

## Commands

- `ragctl create-collection`, `doctor`, `ingest PATH`, `resume PATH`, `stats`, `verify`
- `ragctl safe-probe ARCHIVE --output structure.json`
- `ragctl search-json --config FILE` — one JSON request per stdin line: `{"query":"…","limit":8}`; only result IDs/hashes/metadata/scores are returned.
- `ragctl search --query '…'` — same safe output.

All production configuration belongs in `/home/obj/srv/hf-rag/etc/`, never in Git.
