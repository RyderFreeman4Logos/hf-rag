#!/usr/bin/env sh
# Configure a Hermes/raven container client to reach host Qdrant over docker network.
# Run on the host (obj@mp). Never prints API keys or corpus text.
set -eu
CONTAINER="${1:-hermes-ai-safety-hermes-1}"
NET="${HF_RAG_HERMES_NETWORK:-hermes-ai-safety_private}"
HOST_ETC="${HOST_ETC:-/home/obj/srv/hf-rag/etc}"
QDRANT_ALIAS="${QDRANT_ALIAS:-deploy-qdrant-1}"

[ -f "$HOST_ETC/ragctl.env" ] || { printf '%s\n' "missing $HOST_ETC/ragctl.env" >&2; exit 1; }
[ -f "$HOST_ETC/ragctl.toml" ] || { printf '%s\n' "missing $HOST_ETC/ragctl.toml" >&2; exit 1; }

# Ensure Qdrant is on the hermes network
APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
sh "$APP_ROOT/deploy/scripts/wire-hermes-network.sh" >/dev/null

# Resolve Qdrant IP/alias on that network for a health check only
QIP="$(docker inspect "$QDRANT_ALIAS" --format '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "'"$NET"'"}}{{$v.IPAddress}}{{end}}{{end}}' 2>/dev/null || true)"
[ -n "$QIP" ] || QIP="$QDRANT_ALIAS"

# Read keys without printing them
set -a
# shellcheck disable=SC1090
. "$HOST_ETC/ragctl.env"
set +a
: "${QDRANT_API_KEY:?QDRANT_API_KEY missing in ragctl.env}"

# Write container-side config under /opt/data (persistent volume for hermes boxes)
docker exec "$CONTAINER" sh -lc 'mkdir -p /opt/data/.config/hf-rag /opt/data/.local/bin'

# ragctl.toml for container: point at docker-network alias, keep GB10 URLs
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

[ingest]
embed_batch_size = 4
upsert_batch_size = 8
min_mem_available_mib = 768
max_qdrant_rss_mib = 700
disk_free_mib = 1024
checkpoint = "/opt/data/.local/share/hf-rag/ingest.sqlite3"
log_full_text = false
EOF

# env file inside container (0600)
docker exec -i -e QK="$QDRANT_API_KEY" -e GK="${GB10_API_KEY:-}" "$CONTAINER" sh -lc '
  umask 077
  printf "QDRANT_API_KEY=%s\nGB10_API_KEY=%s\nRAGCTL_CONFIG=/opt/data/.config/hf-rag/ragctl.toml\n" "$QK" "$GK" > /opt/data/.config/hf-rag/ragctl.env
  chmod 600 /opt/data/.config/hf-rag/ragctl.env
'

# PATH helper for interactive shells (HOME may be /root while tools live under /opt/data)
docker exec "$CONTAINER" sh -lc '
  mkdir -p /opt/data/.local/bin
  if [ -x /opt/data/.local/bin/ragctl ]; then
    ln -sfn /opt/data/.local/bin/ragctl /usr/local/bin/ragctl 2>/dev/null || true
  fi
  # profile snippet
  snip=/opt/data/.config/hf-rag/path.sh
  cat > "$snip" <<'\''EOS'\''
# hf-rag client path + env (sourced by hermes shells)
export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$PATH"
if [ -f /opt/data/.config/hf-rag/ragctl.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /opt/data/.config/hf-rag/ragctl.env
  set +a
fi
EOS
  for rc in /opt/data/.bashrc /root/.bashrc; do
    if [ -f "$rc" ] || mkdir -p "$(dirname "$rc")" 2>/dev/null; then
      touch "$rc"
      if ! grep -q "hf-rag/path.sh" "$rc" 2>/dev/null; then
        printf "\n# hf-rag\n[ -f %s ] && . %s\n" "$snip" "$snip" >> "$rc"
      fi
    fi
  done
'

# Smoke: help + doctor (counts/status only)
docker exec "$CONTAINER" sh -lc '
  . /opt/data/.config/hf-rag/path.sh
  command -v ragctl
  ragctl --help >/dev/null
  ragctl doctor --config /opt/data/.config/hf-rag/ragctl.toml
  ragctl stats --config /opt/data/.config/hf-rag/ragctl.toml
'
printf '%s\n' "container_client_ready container=$CONTAINER qdrant=http://${QDRANT_ALIAS}:6333"
