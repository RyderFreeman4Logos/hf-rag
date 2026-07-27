#!/usr/bin/env bash
# Pull and recreate the pinned Qdrant image without touching bind-mounted data.
set -Eeuo pipefail
set +x

APP_DIR="${APP_DIR:-/home/obj/srv/hf-rag/app/deploy}"
ENV_FILE="${ENV_FILE:-/home/obj/srv/hf-rag/etc/qdrant.env}"
COMPOSE_FILE="${COMPOSE_FILE:-${APP_DIR}/compose.yaml}"
LOG_FILE="${LOG_FILE:-/home/obj/srv/hf-rag/logs/qdrant-update.log}"
DOCKER_BIN="${DOCKER_BIN:-/usr/bin/docker}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
IMAGE="${IMAGE:-qdrant/qdrant:v1.18.3}"
SERVICE="${SERVICE:-qdrant}"

[[ -f "$ENV_FILE" ]] || { printf 'missing Qdrant env file: %s\n' "$ENV_FILE" >&2; exit 2; }
[[ -f "$COMPOSE_FILE" ]] || { printf 'missing Qdrant compose file: %s\n' "$COMPOSE_FILE" >&2; exit 2; }
mkdir -p "$(dirname "$LOG_FILE")"

image_digest() {
  "$DOCKER_BIN" image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true
}

api_key="$({ awk -F= '$1 == "QDRANT__SERVICE__API_KEY" { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"; } || true)"
case "$api_key" in
  \"*\") api_key="${api_key#\"}"; api_key="${api_key%\"}" ;;
  \'*\') api_key="${api_key#\'}"; api_key="${api_key%\'}" ;;
esac
[[ -n "$api_key" ]] || { printf 'QDRANT__SERVICE__API_KEY is missing from %s\n' "$ENV_FILE" >&2; exit 2; }

old_digest="$(image_digest)"
"$DOCKER_BIN" pull "$IMAGE"
new_digest="$(image_digest)"

# Intentionally no `down` and never `down -v`: /home/obj/srv/qdrant/storage is retained.
"$DOCKER_BIN" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$SERVICE"

healthy=0
for _ in $(seq 1 30); do
  if "$CURL_BIN" --fail --silent --show-error --output /dev/null \
      --header "api-key: $api_key" http://127.0.0.1:6333/healthz; then
    healthy=1
    break
  fi
  sleep 2
done

printf '%s qdrant_update old_image_digest=%s new_image_digest=%s health=%s\n' \
  "$(date --iso-8601=seconds)" "${old_digest:-<none>}" "${new_digest:-<none>}" "$healthy" >> "$LOG_FILE"
[[ "$healthy" == 1 ]] || { printf 'Qdrant health check failed after update\n' >&2; exit 1; }
