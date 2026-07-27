#!/usr/bin/env sh
set -eu
set +x
APP=/home/obj/srv/hf-rag/app
ETC=/home/obj/srv/hf-rag/etc
ARCHIVE=${1:?archive required}
[ -f "$ARCHIVE" ] || { printf '%s\n' 'archive_not_found' >&2; exit 1; }
set -a
. "$ETC/ragctl.env"
set +a
exec "$APP/.venv/bin/ragctl" ingest "$ARCHIVE" --config "$ETC/ragctl.toml"
