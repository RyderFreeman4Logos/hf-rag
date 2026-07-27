#!/usr/bin/env sh
# Structure-only probe: path, byte count, schema names, row counts and hashes.
set -eu
set +x
APP=/home/obj/srv/hf-rag/app
ARCHIVE=${1:-/home/obj/w/datasets.tar.zst}
OUTPUT=/home/obj/srv/hf-rag/structure.json
[ -f "$ARCHIVE" ] || { printf '%s\n' 'archive_not_found' >&2; exit 1; }
mkdir -p /home/obj/srv/hf-rag
exec systemd-run --user --wait --collect --quiet \
  -p MemoryMax=256M -p MemorySwapMax=0 -p NoNewPrivileges=yes \
  "$APP/.venv/bin/ragctl" safe-probe "$ARCHIVE" --output "$OUTPUT"
