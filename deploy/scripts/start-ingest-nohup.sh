#!/usr/bin/env sh
# Durable, counts-only host ingest launcher. Do not add set -x here.
set -eu
set +x

APP=/home/obj/srv/hf-rag/app
STATE=/home/obj/srv/hf-rag/state
LOG_DIR=/home/obj/srv/hf-rag/logs
ARCHIVE=${1:-/home/obj/w/datasets.tar.zst}
PIDFILE=$STATE/ingest.nohup.pid
LOGFILE=$LOG_DIR/ingest.nohup.log

if [ "$(id -un)" != "obj" ]; then
    printf '%s\n' 'must_run_as_obj' >&2
    exit 1
fi
[ -f "$ARCHIVE" ] || { printf '%s\n' 'archive_not_found' >&2; exit 1; }
mkdir -p "$STATE" "$LOG_DIR"
umask 077
touch "$LOGFILE"

if [ -f "$PIDFILE" ]; then
    pid=$(tr -d '[:space:]' < "$PIDFILE")
    case "$pid" in
        ''|*[!0-9]*) rm -f "$PIDFILE" ;;
        *)
            if kill -0 "$pid" 2>/dev/null; then
                printf '%s\n' 'nohup_ingest_already_running' >&2
                exit 1
            fi
            rm -f "$PIDFILE"
            ;;
    esac
fi

if systemctl --user is-active --quiet rag-ingest@datasets.service; then
    printf '%s\n' 'systemd_ingest_active_stop_it_before_starting_nohup' >&2
    exit 1
fi

# The worker imports secrets from ragctl.env itself. nohup keeps it alive after
# SSH disconnect; all worker output is structured counts-only JSON in LOGFILE.
nohup "$APP/deploy/scripts/_ingest-worker.sh" "$ARCHIVE" >>"$LOGFILE" 2>&1 </dev/null &
pid=$!
printf '%s\n' "$pid" > "$PIDFILE"
printf '%s\n' "nohup_ingest_started pid=$pid log=$LOGFILE"
