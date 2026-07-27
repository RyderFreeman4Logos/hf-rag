#!/usr/bin/env sh
# Install/run only as obj on mp. It never inspects corpus contents.
set -eu
set +x
APP=/home/obj/srv/hf-rag/app
ETC=/home/obj/srv/hf-rag/etc
if [ "$(id -un)" != "obj" ] || [ "$HOME" != "/home/obj" ]; then
  printf '%s\n' 'must run as obj with HOME=/home/obj' >&2
  exit 1
fi
if [ ! -f "$APP/pyproject.toml" ]; then
  printf '%s\n' "missing app at $APP; rsync the hf-rag project first" >&2
  exit 1
fi
if [ "$(docker context show)" != "rootless" ]; then
  printf '%s\n' 'refusing: Docker context must be rootless' >&2
  exit 1
fi
mkdir -p "$ETC" /home/obj/srv/hf-rag/state /home/obj/srv/hf-rag/logs \
  /home/obj/srv/qdrant/storage /home/obj/srv/qdrant/snapshots /home/obj/srv/qdrant/tmp
chmod 700 "$ETC" /home/obj/srv/hf-rag/state
if [ ! -f "$ETC/qdrant.env" ]; then
  umask 077
  secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  printf 'QDRANT__SERVICE__API_KEY=%s\n' "$secret" > "$ETC/qdrant.env"
fi
chmod 600 "$ETC/qdrant.env"
qdrant_key="$(cut -d= -f2- "$ETC/qdrant.env")"
if [ ! -f "$ETC/ragctl.env" ]; then
  umask 077
  printf 'QDRANT_API_KEY=%s\n' "$qdrant_key" > "$ETC/ragctl.env"
  printf 'GB10_API_KEY=%s\n' "${GB10_API_KEY:-}" >> "$ETC/ragctl.env"
fi
# Retained temporarily for the existing systemd ingest worker. Client commands
# load the separate credentials.toml directly and do not need to source this.
chmod 600 "$ETC/ragctl.env"
if [ ! -f "$ETC/credentials.toml" ]; then
  umask 077
  python3 - "$ETC/ragctl.env" > "$ETC/credentials.toml" <<'PY'
import json
import sys
from pathlib import Path

legacy: dict[str, str] = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    name, separator, value = line.partition("=")
    if separator and name in {"QDRANT_API_KEY", "GB10_API_KEY"}:
        legacy[name] = value
qdrant_key = legacy.get("QDRANT_API_KEY")
gb10_key = legacy.get("GB10_API_KEY")
if not qdrant_key:
    raise SystemExit("ragctl.env is missing QDRANT_API_KEY")

print("[keys]")
print(f"qdrant_api_key = {json.dumps(qdrant_key)}")
if gb10_key:
    print(f"gb10_api_key = {json.dumps(gb10_key)}")
PY
fi
chmod 600 "$ETC/credentials.toml"
if [ ! -f "$ETC/ragctl.toml" ]; then
  cp "$APP/deploy/ragctl.toml.example" "$ETC/ragctl.toml"
  chmod 600 "$ETC/ragctl.toml"
fi
if ! command -v uv >/dev/null 2>&1; then
  # Official static uv installer into this unprivileged account; no sudo/pip override.
  curl --fail --silent --show-error --location https://astral.sh/uv/0.11.32/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  printf '%s\n' 'uv_bootstrap_failed' >&2
  exit 1
fi
cd "$APP"
if [ ! -x .venv/bin/python ]; then
  uv venv --python 3.11 .venv
fi
uv sync --frozen --no-dev
mkdir -p "$HOME/.config/systemd/user"
install -m 644 "$APP/deploy/systemd/qdrant.user.service" "$HOME/.config/systemd/user/qdrant.user.service"
install -m 644 "$APP/deploy/systemd/qdrant-update.service" "$HOME/.config/systemd/user/qdrant-update.service"
install -m 644 "$APP/deploy/systemd/qdrant-update.timer" "$HOME/.config/systemd/user/qdrant-update.timer"
chmod 755 "$APP/deploy/scripts/qdrant-update.sh"
chmod 755 "$APP/deploy/scripts/start-ingest-nohup.sh"
install -m 644 "$APP/deploy/systemd/rag-ingest@.service" "$HOME/.config/systemd/user/rag-ingest@.service"
systemctl --user daemon-reload
systemctl --user enable --now qdrant.user.service
systemctl --user enable --now qdrant-update.timer
"$APP/.venv/bin/ragctl" create-collection --config "$ETC/ragctl.toml"
printf '%s\n' 'install_complete'
