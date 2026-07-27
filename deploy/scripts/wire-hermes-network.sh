#!/usr/bin/env sh
# Attach running Qdrant to a Hermes private docker network (durable reconnect helper).
# Does not print secrets or corpus content.
set -eu
NET="${HF_RAG_HERMES_NETWORK:-hermes-ai-safety_private}"
# Prefer compose service name; fall back to container name scan.
CID="$(docker ps -q --filter name=deploy-qdrant-1 | head -1)"
if [ -z "$CID" ]; then
  CID="$(docker ps -q --filter ancestor=qdrant/qdrant:v1.18.3 | head -1)"
fi
[ -n "$CID" ] || { printf '%s\n' 'qdrant_container_not_running' >&2; exit 1; }
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  printf '%s\n' "network_missing:$NET" >&2
  exit 1
fi
# Idempotent connect
if docker inspect "$CID" --format '{{json .NetworkSettings.Networks}}' | grep -q "\"$NET\""; then
  printf '%s\n' "already_connected net=$NET cid=$CID"
else
  docker network connect "$NET" "$CID"
  printf '%s\n' "connected net=$NET cid=$CID"
fi
# Print only network IP (no secrets)
docker inspect "$CID" --format '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s=%s " $k $v.IPAddress}}{{end}}'
