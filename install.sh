#!/usr/bin/env bash
# Public one-line installer for ragctl (hf-rag).
# Intended usage inside containers / hermes-shell:
#   curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh | bash
#
# Primary path: mise use -g 'pipx:git+https://github.com/.../hf-rag.git@main'
# Fallback: shallow clone + uv tool install --from <checkout> hf-rag + mise shim.
#
# Non-interactive env overrides (safe under curl|bash; never reads /dev/tty):
#   HF_RAG_REPO   git remote (default: https://github.com/RyderFreeman4Logos/hf-rag.git)
#   HF_RAG_REF    git ref (default: main)
#   HF_RAG_DIR    fallback checkout dir (default: $XDG_DATA_HOME/hf-rag/src)
#   UV_TOOL_BIN_DIR / XDG_BIN_HOME for fallback binary dir
set -euo pipefail
set +x

REPO="${HF_RAG_REPO:-https://github.com/RyderFreeman4Logos/hf-rag.git}"
REF="${HF_RAG_REF:-main}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
SRC_DIR="${HF_RAG_DIR:-$DATA_HOME/hf-rag/src}"
BIN_DIR="${UV_TOOL_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# curl|bash must never block on stdin/TTY prompts.
export MISE_YES=1
export MISE_NOT_FOUND_AUTO_INSTALL=1

need_cmd() { command -v "$1" >/dev/null 2>&1; }

bootstrap_mise() {
  if need_cmd mise; then
    return 0
  fi
  need_cmd curl || die "curl required to bootstrap mise"
  log "bootstrapping mise from https://mise.run"
  tmp=$(mktemp "${TMPDIR:-/tmp}/hf-rag-mise.XXXXXX")
  curl -fsSL https://mise.run -o "$tmp"
  sh "$tmp"
  rm -f "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
  need_cmd mise || die "mise bootstrap failed"
}

ensure_uv() {
  if need_cmd uv; then
    return 0
  fi
  log "installing uv via mise"
  mise use -g -y uv@latest || true
  export PATH="$HOME/.local/bin:$(mise where uv 2>/dev/null || true)/bin:$PATH"
  if ! need_cmd uv; then
    need_cmd curl || die "curl required to bootstrap uv"
    curl -fsSL https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  need_cmd uv || die "uv bootstrap failed"
}

ensure_python() {
  # Prefer a CPython that has manylinux pyarrow wheels (avoid source cmake builds).
  log "ensuring python@3.11 via mise (for binary wheels)"
  mise use -g -y python@3.11 || mise use -g -y python@3.12 || true
  if py=$(mise which python 2>/dev/null); then
    export UV_PYTHON="$py"
    export PIPX_DEFAULT_PYTHON="$py"
  fi
}

# Working form on mise 2026.7.x: pipx:git+https://github.com/OWNER/REPO.git@REF
mise_tool_spec() {
  # Strip trailing .git for display; keep full URL for pipx git backend.
  printf 'pipx:git+%s@%s' "$REPO" "$REF"
}

install_via_mise_use() {
  local spec
  spec=$(mise_tool_spec)
  log "primary: mise use -g -y '$spec'"
  # Prefer wheels; pyarrow source builds need cmake and often fail in slim containers.
  export UV_NO_BUILD_ISOLATION=0
  export UV_COMPILE_BYTECODE=0
  # uv respects only-binary when set this way for tool installs in many versions
  export UV_ONLY_BINARY="${UV_ONLY_BINARY:-:all:}"
  if mise use -g -y -f "$spec"; then
    return 0
  fi
  log "mise use -g pipx git install failed; will try uv tool fallback"
  return 1
}

resolve_ragctl_from_mise() {
  if bin=$(mise which ragctl 2>/dev/null) && [ -x "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  # Some backends put scripts under tool dir bin/
  if where=$(mise where "$(mise_tool_spec)" 2>/dev/null); then
    if [ -x "$where/bin/ragctl" ]; then
      printf '%s' "$where/bin/ragctl"
      return 0
    fi
  fi
  # Search mise installs for ragctl
  local candidate
  candidate=$(find "${MISE_DATA_DIR:-$DATA_HOME/mise}/installs" -type f -name ragctl 2>/dev/null | head -n1 || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

fetch_repo() {
  need_cmd git || die "git required"
  mkdir -p "$(dirname "$SRC_DIR")"
  if [ -d "$SRC_DIR/.git" ]; then
    log "updating existing checkout $SRC_DIR @ $REF"
    git -C "$SRC_DIR" remote set-url origin "$REPO" || true
    git -C "$SRC_DIR" fetch --depth 1 origin "$REF"
    git -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD"
  else
    log "cloning $REPO ($REF) -> $SRC_DIR"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
      || {
        git clone --depth 1 "$REPO" "$SRC_DIR"
        git -C "$SRC_DIR" fetch --depth 1 origin "$REF"
        git -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD"
      }
  fi
  [ -f "$SRC_DIR/pyproject.toml" ] || die "checkout missing pyproject.toml"
  log "source=$(git -C "$SRC_DIR" rev-parse --short HEAD) ref=$REF"
}

install_via_uv_tool() {
  fetch_repo
  mkdir -p "$BIN_DIR"
  log "fallback: uv tool install --from checkout package hf-rag (script: ragctl)"
  UV_TOOL_BIN_DIR="$BIN_DIR" uv tool install --from "$SRC_DIR" --force --python 3.11 hf-rag \
    || UV_TOOL_BIN_DIR="$BIN_DIR" uv tool install --from "$SRC_DIR" --force hf-rag \
    || die "uv tool install failed"
  RAGCTL_BIN="$BIN_DIR/ragctl"
  [ -x "$RAGCTL_BIN" ] || die "ragctl binary missing at $RAGCTL_BIN"
  # Persist a mise-managed pointer so upgrades can re-run this installer or mise reshim.
  write_mise_shim "$RAGCTL_BIN"
  # Record preferred tool id in global config as a comment-free note via env path only.
  # Users upgrade with: curl .../install.sh | bash   OR   HF_RAG_REF=main bash install.sh
}

write_mise_shim() {
  local ragctl_bin=$1
  command -v mise >/dev/null 2>&1 || return 0
  mise reshim >/dev/null 2>&1 || true
  local mise_data="${MISE_DATA_DIR:-$DATA_HOME/mise}"
  local shim_dir="$mise_data/shims"
  mkdir -p "$shim_dir"
  # Explicit shim so activate/shims always resolve even if reshim misses UV_TOOL_BIN_DIR.
  cat >"$shim_dir/ragctl" <<EOF
#!/bin/sh
exec $(printf '%q' "$ragctl_bin") "\$@"
EOF
  chmod 755 "$shim_dir/ragctl"
  # Also drop a ~/.local/bin copy when BIN_DIR differs.
  if [ "$BIN_DIR" != "$HOME/.local/bin" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$ragctl_bin" "$HOME/.local/bin/ragctl" 2>/dev/null || true
  fi
}

smoke() {
  local bin=$1
  "$bin" --help >/dev/null || die "ragctl --help failed"
  log "ragctl_installed path=$bin"
  log "next: ensure PATH includes $(dirname "$bin") and mise shims if used"
  log "  export PATH=\"$(dirname "$bin"):\$PATH\""
  log "  eval \"\$(mise activate bash)\"   # or your shell"
  log "upgrade: curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh | bash"
  log "optional host config: RAGCTL_CONFIG=/home/obj/srv/hf-rag/etc/ragctl.toml ragctl doctor"
}

main() {
  log "hf-rag install.sh repo=$REPO ref=$REF"
  bootstrap_mise
  ensure_uv
  ensure_python
  RAGCTL_BIN=""
  if install_via_mise_use; then
    if RAGCTL_BIN=$(resolve_ragctl_from_mise); then
      write_mise_shim "$RAGCTL_BIN"
      smoke "$RAGCTL_BIN"
      log "ok (mise use -g)"
      return 0
    fi
    log "mise use reported success but ragctl not found; falling back"
  fi
  install_via_uv_tool
  smoke "$RAGCTL_BIN"
  log "ok (uv tool + mise shim)"
}

main "$@"
