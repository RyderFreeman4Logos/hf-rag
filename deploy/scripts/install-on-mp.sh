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
chmod 600 "$ETC/ragctl.env"
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
install -m 644 "$APP/deploy/systemd/rag-ingest@.service" "$HOME/.config/systemd/user/rag-ingest@.service"
systemctl --user daemon-reload
systemctl --user enable qdrant.user.service
systemctl --user start qdrant.user.service
set -a
. "$ETC/ragctl.env"
set +a
"$APP/.venv/bin/ragctl" create-collection --config "$ETC/ragctl.toml"
printf '%s\n' 'install_complete'
