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

# env file inside container. Interactive hermes-shell runs as user `hermes`
# (uid 10000), not root — so root-only 0600 causes: Permission denied.
docker exec -i -e QK="$QDRANT_API_KEY" -e GK="${GB10_API_KEY:-}" "$CONTAINER" sh -lc '
  umask 077
  printf "QDRANT_API_KEY=%s\nGB10_API_KEY=%s\nRAGCTL_CONFIG=/opt/data/.config/hf-rag/ragctl.toml\n" "$QK" "$GK" > /opt/data/.config/hf-rag/ragctl.env
'

# PATH helper for interactive shells (HOME may be /root while tools live under /opt/data)
docker exec "$CONTAINER" sh -lc '
  mkdir -p /opt/data/.local/bin
  # Prefer uv-installed real binary if present
  REAL=""
  for c in /opt/data/.local/share/uv/tools/hf-rag/bin/ragctl \
           /opt/data/.local/bin/ragctl.real; do
    if [ -x "$c" ]; then REAL="$c"; break; fi
  done
  # If current ragctl is the real script (not our wrapper), remember it
  if [ -z "$REAL" ] && [ -x /opt/data/.local/bin/ragctl ] && ! head -1 /opt/data/.local/bin/ragctl | grep -q "hf-rag env"; then
    if head -1 /opt/data/.local/bin/ragctl | grep -q python || grep -q "hf_rag" /opt/data/.local/bin/ragctl 2>/dev/null; then
      REAL=/opt/data/.local/bin/ragctl
    fi
  fi
  [ -n "$REAL" ] && ln -sfn "$REAL" /opt/data/.local/bin/ragctl.real

  # Wrapper: Hermes agent tool shells often skip .bashrc and have no QDRANT_API_KEY
  # → bare ragctl would hit Qdrant 401. Always load ragctl.env here.
  if [ -x /opt/data/.local/bin/ragctl.real ] || [ -x /opt/data/.local/share/uv/tools/hf-rag/bin/ragctl ]; then
    cat > /opt/data/.local/bin/ragctl <<'"'"'WRAP'"'"'
#!/bin/sh
# hf-rag env bootstrap for non-interactive Hermes terminals
CFG="${RAGCTL_CONFIG:-/opt/data/.config/hf-rag/ragctl.toml}"
ENVF="/opt/data/.config/hf-rag/ragctl.env"
REAL="/opt/data/.local/share/uv/tools/hf-rag/bin/ragctl"
if [ ! -x "$REAL" ]; then REAL="/opt/data/.local/bin/ragctl.real"; fi
if [ -r "$ENVF" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENVF"
  set +a
fi
export RAGCTL_CONFIG="${RAGCTL_CONFIG:-$CFG}"
if [ -f "${RAGCTL_CONFIG}" ]; then
  case " $* " in
    *" --config "*) exec "$REAL" "$@" ;;
    *)
      if [ "$#" -ge 1 ]; then
        cmd="$1"; shift
        exec "$REAL" "$cmd" --config "$RAGCTL_CONFIG" "$@"
      else
        exec "$REAL" --help
      fi
      ;;
  esac
else
  exec "$REAL" "$@"
fi
WRAP
    chmod 755 /opt/data/.local/bin/ragctl
  fi
  ln -sfn /opt/data/.local/bin/ragctl /usr/local/bin/ragctl 2>/dev/null || true
  # profile snippet — never hard-fail if env is unreadable
  snip=/opt/data/.config/hf-rag/path.sh
  cat > "$snip" <<'\''EOS'\''
# hf-rag client path + env (sourced by hermes shells)
export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:${PATH:-}"
if [ -r /opt/data/.config/hf-rag/ragctl.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /opt/data/.config/hf-rag/ragctl.env
  set +a
elif [ -f /opt/data/.config/hf-rag/ragctl.env ]; then
  printf "%s\n" "hf-rag: cannot read /opt/data/.config/hf-rag/ragctl.env (permission denied). Run on host: sh /home/obj/srv/hf-rag/app/deploy/scripts/setup-container-client.sh" >&2
fi
export RAGCTL_CONFIG="${RAGCTL_CONFIG:-/opt/data/.config/hf-rag/ragctl.toml}"
EOS
  # Ownership: hermes-shell sessions are often user hermes on /opt/data volume.
  if id hermes >/dev/null 2>&1; then
    chown -R hermes:hermes /opt/data/.config/hf-rag /opt/data/.local/bin/ragctl /opt/data/.local/bin/ragctl.real 2>/dev/null || true
    chmod 750 /opt/data/.config/hf-rag
    chmod 640 /opt/data/.config/hf-rag/ragctl.env
    chmod 644 /opt/data/.config/hf-rag/ragctl.toml /opt/data/.config/hf-rag/path.sh
    chmod 755 /opt/data/.local/bin/ragctl 2>/dev/null || true
  else
    chmod 755 /opt/data/.config/hf-rag
    chmod 644 /opt/data/.config/hf-rag/ragctl.env /opt/data/.config/hf-rag/ragctl.toml /opt/data/.config/hf-rag/path.sh
  fi
  for rc in /opt/data/.bashrc /root/.bashrc; do
    if [ -f "$rc" ] || mkdir -p "$(dirname "$rc")" 2>/dev/null; then
      touch "$rc"
      if ! grep -q "hf-rag/path.sh" "$rc" 2>/dev/null; then
        printf "\n# hf-rag\n[ -f %s ] && . %s\n" "$snip" "$snip" >> "$rc"
      fi
      if id hermes >/dev/null 2>&1 && [ -f /opt/data/.bashrc ]; then
        chown hermes:hermes /opt/data/.bashrc 2>/dev/null || true
      fi
    fi
  done
'

# Smoke: interactive path + agent-like clean env (no bashrc) must not 401
docker exec "$CONTAINER" sh -lc '
  . /opt/data/.config/hf-rag/path.sh
  command -v ragctl
  ragctl --help >/dev/null
  ragctl doctor --config /opt/data/.config/hf-rag/ragctl.toml
  ragctl stats --config /opt/data/.config/hf-rag/ragctl.toml
'
if docker exec "$CONTAINER" id hermes >/dev/null 2>&1; then
  docker exec -u hermes "$CONTAINER" sh -lc '
    . /opt/data/.config/hf-rag/path.sh
    command -v ragctl
    ragctl stats --config /opt/data/.config/hf-rag/ragctl.toml
  '
  # Critical: no env inheritance (Hermes tool shells)
  docker exec -u hermes "$CONTAINER" sh -lc '
    env -i HOME=/opt/data PATH=/opt/data/.local/bin:/usr/bin:/bin \
      /opt/data/.local/bin/ragctl stats
  '
fi

# Install query-only Hermes skill into box skill roots (hermes user)
APP_SKILL_SRC="$APP_ROOT/hermes-skills/private-hf-corpus-search"
if [ -d "$APP_SKILL_SRC" ]; then
  for dest in /opt/data/skills/private-hf-corpus-search /opt/data/.agents/skills/private-hf-corpus-search; do
    docker exec "$CONTAINER" sh -lc "mkdir -p $(dirname $dest)"
    # copy via tar to preserve perms as hermes
    tar -C "$APP_SKILL_SRC" -cf - . | docker exec -i -u hermes "$CONTAINER" sh -lc "mkdir -p $dest && tar -C $dest -xf - && chmod -R u+rwX,go+rX $dest"
  done
  printf '%s\n' "skill_installed private-hf-corpus-search"
fi

printf '%s\n' "container_client_ready container=$CONTAINER qdrant=http://${QDRANT_ALIAS}:6333"
