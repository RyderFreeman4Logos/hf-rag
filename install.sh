#!/usr/bin/env bash
# Public one-line installer for ragctl (hf-rag).
# Intended usage inside containers / hermes-shell:
#   curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh | bash
#
# Environment (all optional):
#   HF_RAG_REPO   git remote (default: https://github.com/RyderFreeman4Logos/hf-rag.git)
#   HF_RAG_REF    branch/tag/SHA (default: main)
#   HF_RAG_DIR    checkout directory (default: $XDG_DATA_HOME/hf-rag/src)
#   UV_TOOL_BIN_DIR / XDG_BIN_HOME for the ragctl binary
#
# Safety: never reads or prints corpus archives. No sudo. Piped-stdin safe
# (no interactive prompts; all knobs are env vars).
set -euo pipefail
set +x

REPO="${HF_RAG_REPO:-https://github.com/RyderFreeman4Logos/hf-rag.git}"
REF="${HF_RAG_REF:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
SRC_DIR="${HF_RAG_DIR:-$DATA_HOME/hf-rag/src}"
BIN_DIR="${UV_TOOL_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
export PATH="$HOME/.local/bin:$HOME/bin:$BIN_DIR:$PATH"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

need_cmd curl
need_cmd git
need_cmd tar
need_cmd bash

# --- mise (optional but preferred for shims) ---
ensure_mise() {
  if command -v mise >/dev/null 2>&1; then
    return 0
  fi
  log "mise not found; bootstrapping from https://mise.run"
  tmp=$(mktemp "${TMPDIR:-/tmp}/hf-rag-mise.XXXXXX")
  # shellcheck disable=SC2064
  trap 'rm -f "$tmp"' RETURN
  curl --fail --silent --show-error --location https://mise.run --output "$tmp" \
    || die "mise bootstrap download failed"
  sh "$tmp" || die "mise bootstrap failed"
  # common install locations after bootstrap
  export PATH="$HOME/.local/bin:$HOME/.mise/bin:${MISE_DATA_DIR:-$DATA_HOME/mise}/bin:$PATH"
  command -v mise >/dev/null 2>&1 || die "mise still not on PATH after bootstrap"
}

# --- uv (preferred package installer) ---
ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  log "uv not found; bootstrapping from astral.sh"
  curl --fail --silent --show-error --location https://astral.sh/uv/install.sh | sh \
    || die "uv bootstrap failed"
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  command -v uv >/dev/null 2>&1 || die "uv still not on PATH after bootstrap"
}

# --- fetch source (main by default) ---
fetch_src() {
  mkdir -p "$(dirname -- "$SRC_DIR")"
  if [ -d "$SRC_DIR/.git" ]; then
    log "updating existing checkout $SRC_DIR @ $REF"
    git -C "$SRC_DIR" remote set-url origin "$REPO" 2>/dev/null || true
    git -C "$SRC_DIR" fetch --depth 1 origin "$REF" || die "git fetch failed"
    git -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD" || die "git checkout failed"
  else
    log "cloning $REPO ($REF) -> $SRC_DIR"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
      || git clone --depth 1 "$REPO" "$SRC_DIR" \
      || die "git clone failed"
    # if branch name failed (detached ref), try fetch ref
    if ! git -C "$SRC_DIR" rev-parse --verify "refs/heads/$REF" >/dev/null 2>&1; then
      git -C "$SRC_DIR" fetch --depth 1 origin "$REF" || true
      git -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD" 2>/dev/null || true
    fi
  fi
  [ -f "$SRC_DIR/pyproject.toml" ] || die "checkout missing pyproject.toml"
  log "source=$(git -C "$SRC_DIR" rev-parse --short HEAD) ref=$REF"
}

install_ragctl() {
  mkdir -p "$BIN_DIR"
  if command -v uv >/dev/null 2>&1; then
    # Project name is hf-rag; console script entry point is ragctl.
    log "installing package hf-rag (script: ragctl) via uv tool install"
    UV_TOOL_BIN_DIR="$BIN_DIR" uv tool install --from "$SRC_DIR" --force --python 3.11 hf-rag \
      || UV_TOOL_BIN_DIR="$BIN_DIR" uv tool install --from "$SRC_DIR" --force hf-rag \
      || die "uv tool install failed"
    RAGCTL_BIN="$BIN_DIR/ragctl"
  else
    die "uv required for install"
  fi
  [ -x "$RAGCTL_BIN" ] || die "ragctl binary missing at $RAGCTL_BIN"
}

write_mise_shim() {
  command -v mise >/dev/null 2>&1 || return 0
  mise reshim >/dev/null 2>&1 || true
  mise_data="${MISE_DATA_DIR:-$DATA_HOME/mise}"
  shim_dir="$mise_data/shims"
  mkdir -p "$shim_dir"
  # explicit shim so activate/shims always resolve even if reshim misses UV_TOOL_BIN_DIR
  cat >"$shim_dir/ragctl" <<EOF
#!/bin/sh
exec $(printf '%q' "$RAGCTL_BIN") "\$@"
EOF
  chmod 755 "$shim_dir/ragctl"
}

smoke() {
  "$RAGCTL_BIN" --help >/dev/null || die "ragctl --help failed"
  log "ragctl_installed path=$RAGCTL_BIN"
  log "next: ensure PATH includes $BIN_DIR (and mise shims if used)"
  log "  export PATH=\"$BIN_DIR:\$PATH\""
  if command -v mise >/dev/null 2>&1; then
    log "  eval \"\$(mise activate bash)\"   # or your shell"
  fi
  log "optional host config: RAGCTL_CONFIG=/home/obj/srv/hf-rag/etc/ragctl.toml ragctl doctor"
}

main() {
  log "hf-rag install.sh repo=$REPO ref=$REF"
  ensure_mise
  ensure_uv
  fetch_src
  install_ragctl
  write_mise_shim
  smoke
  log "ok"
}

main "$@"
