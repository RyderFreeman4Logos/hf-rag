#!/usr/bin/env sh
# Configure a Hermes/raven container client to reach host Qdrant over docker network.
# Run on the host (obj@mp). Never prints API keys or corpus text.
set -eu
set +x

CONTAINER="${1:-hermes-ai-safety-hermes-1}"
HOST_ETC="${HOST_ETC:-/home/obj/srv/hf-rag/etc}"
QDRANT_ALIAS="${QDRANT_ALIAS:-deploy-qdrant-1}"

[ -f "$HOST_ETC/ragctl.toml" ] || {
  printf '%s\n' "missing $HOST_ETC/ragctl.toml" >&2
  exit 1
}

# Prefer the separate host credentials TOML. The legacy env file remains a
# migration input for existing host installs, but is never copied into Hermes.
if [ -n "${RAGCTL_CREDENTIALS:-}" ]; then
  CREDENTIALS_FORMAT=toml
  CREDENTIALS_SOURCE=$RAGCTL_CREDENTIALS
  [ -f "$CREDENTIALS_SOURCE" ] || {
    printf '%s\n' 'RAGCTL_CREDENTIALS does not name a file' >&2
    exit 1
  }
elif [ -f "$HOST_ETC/credentials.toml" ]; then
  CREDENTIALS_FORMAT=toml
  CREDENTIALS_SOURCE=$HOST_ETC/credentials.toml
elif [ -f "$HOST_ETC/ragctl.env" ]; then
  CREDENTIALS_FORMAT=env
  CREDENTIALS_SOURCE=$HOST_ETC/ragctl.env
else
  printf '%s\n' "missing $HOST_ETC/credentials.toml and $HOST_ETC/ragctl.env" >&2
  exit 1
fi

# The runtime identity must own its 0600 credentials file.
docker exec "$CONTAINER" id hermes >/dev/null 2>&1 || {
  printf '%s\n' "missing hermes user in $CONTAINER" >&2
  exit 1
}

# Convert host credentials to a temporary TOML stream without putting keys in
# command arguments or output. The file is removed on every exit path.
umask 077
CONTAINER_CREDENTIALS=$(mktemp "$HOST_ETC/.container-credentials.XXXXXX")
cleanup() {
  rm -f "$CONTAINER_CREDENTIALS"
}
trap cleanup 0 HUP INT TERM
chmod 600 "$CONTAINER_CREDENTIALS"
python3 - "$CREDENTIALS_FORMAT" "$CREDENTIALS_SOURCE" > "$CONTAINER_CREDENTIALS" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

credential_format, source_name = sys.argv[1:3]
source = Path(source_name)
if credential_format == "toml":
    raw = tomllib.loads(source.read_text(encoding="utf-8"))
    keys = raw.get("keys", {})
    if not isinstance(keys, dict):
        raise SystemExit("host credentials [keys] must be a table")
    qdrant_key = keys.get("qdrant_api_key")
    gb10_key = keys.get("gb10_api_key")
else:
    legacy: dict[str, str] = {}
    for line in source.read_text(encoding="utf-8").splitlines():
        name, separator, value = line.partition("=")
        if separator and name in {"QDRANT_API_KEY", "GB10_API_KEY"}:
            legacy[name] = value
    qdrant_key = legacy.get("QDRANT_API_KEY")
    gb10_key = legacy.get("GB10_API_KEY")

if not isinstance(qdrant_key, str) or not qdrant_key:
    raise SystemExit("host credentials are missing qdrant_api_key")
if gb10_key is not None and not isinstance(gb10_key, str):
    raise SystemExit("host credentials gb10_api_key must be a string")

print("[keys]")
print(f"qdrant_api_key = {json.dumps(qdrant_key)}")
if gb10_key:
    print(f"gb10_api_key = {json.dumps(gb10_key)}")
PY

# Ensure Qdrant is on the Hermes network only after all local prerequisites pass.
APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
sh "$APP_ROOT/deploy/scripts/wire-hermes-network.sh" >/dev/null

# Write non-secret config and a separate 0600 credentials.toml under the
# persistent /opt/data volume. Neither file is ever rendered by this script.
docker exec "$CONTAINER" sh -lc 'mkdir -p /opt/data/.config/hf-rag /opt/data/.local/bin'
docker exec -i "$CONTAINER" sh -lc 'cat > /opt/data/.config/hf-rag/ragctl.toml' <<EOF
[rag]
qdrant_url = "http://${QDRANT_ALIAS}:6333"
collection = "hf_eval_hybrid"
qdrant_api_key_env = "QDRANT_API_KEY"
embedding_url = "http://100.105.4.92:18002/v1/embeddings"
embedding_model = "qwen3-embedding-8b"
rerank_url = "http://100.105.4.92:18003/v1/rerank"
rerank_model = "qwen3-reranker-8b"
api_key_env = "GB10_API_KEY"
timeout_seconds = 540

[retrieval]
# Max quality defaults (latency acceptable)
dense_prefetch = 240
bm25_prefetch = 240
fused_limit = 120

[ingest]
embed_batch_size = 32
upsert_batch_size = 32
min_mem_available_mib = 768
max_qdrant_rss_mib = 700
disk_free_mib = 1024
checkpoint = "/opt/data/.local/share/hf-rag/ingest.sqlite3"
log_full_text = false
EOF
docker exec -i "$CONTAINER" sh -lc '
  umask 077
  cat > /opt/data/.config/hf-rag/credentials.toml
' < "$CONTAINER_CREDENTIALS"
rm -f "$CONTAINER_CREDENTIALS"

# PATH-only helper for interactive shells. Auth and config discovery live in
# ragctl itself so non-interactive Hermes tool shells need not source anything.
docker exec "$CONTAINER" sh -lc '
  mkdir -p /opt/data/.local/bin /opt/data/.local/share/uv/tools/hf-rag/bin
  # Always restore the real Python console script under uv tools bin.
  # Never install a wrapper there (a recursive wrapper caused hangs).
  PY=/opt/data/.local/share/uv/tools/hf-rag/bin/python
  REAL=/opt/data/.local/share/uv/tools/hf-rag/bin/ragctl
  if [ -x "$PY" ]; then
    cat > "$REAL" <<'"'"'PYBIN'"'"'
#!/opt/data/.local/share/uv/tools/hf-rag/bin/python
# -*- coding: utf-8 -*-
import sys
from hf_rag.cli import app
if __name__ == "__main__":
    sys.argv[0] = "ragctl"
    app()
PYBIN
    chmod 755 "$REAL"
  fi

  if [ -x "$REAL" ]; then
    cat > /opt/data/.local/bin/ragctl <<'"'"'WRAP'"'"'
#!/bin/sh
# PATH-only hf-rag launcher. ragctl resolves config and credentials itself.
REAL="/opt/data/.local/share/uv/tools/hf-rag/bin/ragctl"
if [ ! -x "$REAL" ]; then
  printf "%s\\n" "ragctl: real binary missing at $REAL" >&2
  exit 127
fi
exec "$REAL" "$@"
WRAP
    chmod 755 /opt/data/.local/bin/ragctl
  fi
  ln -sfn /opt/data/.local/bin/ragctl /usr/local/bin/ragctl 2>/dev/null || true

  snip=/opt/data/.config/hf-rag/path.sh
  cat > "$snip" <<'"'"'EOS'"'"'
# hf-rag PATH helper only. ragctl reads credentials.toml directly.
export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:${PATH:-}"
EOS

  # Remove the old container-only secret copy after the 0600 TOML is in place.
  rm -f /opt/data/.config/hf-rag/ragctl.env
  chown -R hermes:hermes /opt/data/.config/hf-rag /opt/data/.local/bin/ragctl \
    /opt/data/.local/share/uv/tools/hf-rag/bin/ragctl 2>/dev/null || true
  chmod 750 /opt/data/.config/hf-rag
  chmod 600 /opt/data/.config/hf-rag/credentials.toml
  chmod 644 /opt/data/.config/hf-rag/ragctl.toml /opt/data/.config/hf-rag/path.sh
  chmod 755 /opt/data/.local/bin/ragctl /opt/data/.local/share/uv/tools/hf-rag/bin/ragctl 2>/dev/null || true

  # Keep interactive PATH setup convenient, but never source secrets from it.
  for rc in /opt/data/.bashrc /root/.bashrc; do
    if [ -f "$rc" ] || mkdir -p "$(dirname "$rc")" 2>/dev/null; then
      touch "$rc"
      if ! grep -q "hf-rag/path.sh" "$rc" 2>/dev/null; then
        printf "\\n# hf-rag\\n[ -f %s ] && . %s\\n" "$snip" "$snip" >> "$rc"
      fi
      if [ -f /opt/data/.bashrc ]; then
        chown hermes:hermes /opt/data/.bashrc 2>/dev/null || true
      fi
    fi
  done
'

# Smoke Qdrant authentication without calling external embedding/rerank services.
# The final call deliberately has no inherited key variables, no RAGCTL_CONFIG,
# and no sourced shell profile.
docker exec "$CONTAINER" sh -lc '
  PATH=/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$PATH
  export PATH
  command -v ragctl
  ragctl --help >/dev/null
  ragctl stats
'
docker exec -u hermes "$CONTAINER" sh -lc '
  PATH=/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$PATH
  export PATH
  command -v ragctl
  ragctl stats
'
docker exec -u hermes "$CONTAINER" sh -lc '
  env -i HOME=/opt/data PATH=/opt/data/.local/bin:/usr/bin:/bin \
    /opt/data/.local/bin/ragctl stats
'

# Install query-only Hermes skill into box skill roots (hermes user).
APP_SKILL_SRC="$APP_ROOT/hermes-skills/private-hf-corpus-search"
if [ -d "$APP_SKILL_SRC" ]; then
  for dest in /opt/data/skills/private-hf-corpus-search /opt/data/.agents/skills/private-hf-corpus-search; do
    docker exec "$CONTAINER" sh -lc "mkdir -p $(dirname $dest)"
    tar -C "$APP_SKILL_SRC" -cf - . | docker exec -i -u hermes "$CONTAINER" sh -lc "mkdir -p $dest && tar -C $dest -xf - && chmod -R u+rwX,go+rX $dest"
  done
  printf '%s\n' "skill_installed private-hf-corpus-search"
fi

printf '%s\n' "container_client_ready container=$CONTAINER qdrant=http://${QDRANT_ALIAS}:6333"
