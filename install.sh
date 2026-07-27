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

# Prefer user bins, but keep system bins so real mise/uv remain reachable.
export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Always use per-user mise state (never write system /usr/local mise config).
export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-$HOME/.config/mise}"
export MISE_DATA_DIR="${MISE_DATA_DIR:-$DATA_HOME/mise}"
export MISE_CACHE_DIR="${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mise}"
mkdir -p "$MISE_CONFIG_DIR" "$MISE_DATA_DIR" "$MISE_CACHE_DIR" "$BIN_DIR"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# curl|bash must never block on stdin/TTY prompts.
export MISE_YES=1
export MISE_NOT_FOUND_AUTO_INSTALL=1

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Absolute paths to real tools (avoid PATH shadowing / broken shims).
MISE_BIN=""
UV_BIN=""
GIT_BIN=""
CURL_BIN=""

resolve_bins() {
  # Prefer known-good absolute locations first.
  if [ -x /usr/local/bin/mise ]; then
    MISE_BIN=/usr/local/bin/mise
  elif [ -x "$HOME/.local/bin/mise" ]; then
    MISE_BIN="$HOME/.local/bin/mise"
  else
    MISE_BIN=$(command -v mise || true)
  fi
  if [ -x /usr/local/bin/uv ]; then
    UV_BIN=/usr/local/bin/uv
  elif [ -x "$HOME/.local/bin/uv" ]; then
    UV_BIN="$HOME/.local/bin/uv"
  else
    UV_BIN=$(command -v uv || true)
  fi
  GIT_BIN=$(command -v git || true)
  CURL_BIN=$(command -v curl || true)

  # Sanity: real mise/uv must not be ragctl.
  if [ -n "$MISE_BIN" ] && ! "$MISE_BIN" --version >/dev/null 2>&1; then
    die "mise at $MISE_BIN is not a working mise binary (got unexpected output)"
  fi
  if [ -n "$UV_BIN" ] && ! "$UV_BIN" --version >/dev/null 2>&1; then
    # Some broken PATH environments make uv resolve to ragctl; try hard paths.
    for cand in /usr/local/bin/uv "$HOME/.local/bin/uv" /usr/bin/uv; do
      if [ -x "$cand" ] && "$cand" --version >/dev/null 2>&1; then
        UV_BIN=$cand
        break
      fi
    done
    if ! "$UV_BIN" --version >/dev/null 2>&1; then
      UV_BIN=""
    fi
  fi
}

bootstrap_mise() {
  resolve_bins
  if [ -n "$MISE_BIN" ]; then
    return 0
  fi
  [ -n "$CURL_BIN" ] || die "curl required to bootstrap mise"
  log "bootstrapping mise from https://mise.run"
  tmp=$(mktemp "${TMPDIR:-/tmp}/hf-rag-mise.XXXXXX")
  "$CURL_BIN" -fsSL https://mise.run -o "$tmp"
  sh "$tmp"
  rm -f "$tmp"
  export PATH="$HOME/.local/bin:$PATH"
  resolve_bins
  [ -n "$MISE_BIN" ] || die "mise bootstrap failed"
}

ensure_uv() {
  resolve_bins
  if [ -n "$UV_BIN" ]; then
    return 0
  fi
  log "installing uv via mise"
  "$MISE_BIN" use -g -y uv@latest || true
  export PATH="$HOME/.local/bin:$PATH"
  resolve_bins
  if [ -z "$UV_BIN" ]; then
    [ -n "$CURL_BIN" ] || die "curl required to bootstrap uv"
    "$CURL_BIN" -fsSL https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    resolve_bins
  fi
  [ -n "$UV_BIN" ] || die "uv bootstrap failed"
}

ensure_python() {
  # Prefer a CPython that has manylinux wheels available.
  log "ensuring python@3.11 via mise"
  "$MISE_BIN" use -g -y python@3.11 || "$MISE_BIN" use -g -y python@3.12 || true
  if py=$("$MISE_BIN" which python 2>/dev/null); then
    export UV_PYTHON="$py"
    export PIPX_DEFAULT_PYTHON="$py"
  fi
}

# Working form on mise 2026.7.x: pipx:git+https://github.com/OWNER/REPO.git@REF
mise_tool_spec() {
  printf 'pipx:git+%s@%s' "$REPO" "$REF"
}

install_via_mise_use() {
  local spec
  spec=$(mise_tool_spec)
  log "primary: $MISE_BIN use -g -y '$spec'"
  export UV_ONLY_BINARY="${UV_ONLY_BINARY:-:all:}"
  if "$MISE_BIN" use -g -y -f "$spec"; then
    return 0
  fi
  log "mise use -g pipx git install failed; will try uv tool fallback"
  return 1
}

resolve_ragctl_from_mise() {
  if bin=$("$MISE_BIN" which ragctl 2>/dev/null) && [ -x "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  if where=$("$MISE_BIN" where "$(mise_tool_spec)" 2>/dev/null); then
    if [ -x "$where/bin/ragctl" ]; then
      printf '%s' "$where/bin/ragctl"
      return 0
    fi
  fi
  candidate=$(find "$MISE_DATA_DIR/installs" -type f -name ragctl 2>/dev/null | head -n1 || true)
  if [ -n "${candidate:-}" ] && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

fetch_checkout() {
  [ -n "$GIT_BIN" ] || die "git required for fallback install"
  mkdir -p "$(dirname "$SRC_DIR")"
  if [ -d "$SRC_DIR/.git" ]; then
    log "updating existing checkout $SRC_DIR ($REF)"
    "$GIT_BIN" -C "$SRC_DIR" remote set-url origin "$REPO" || true
    "$GIT_BIN" -C "$SRC_DIR" fetch --depth 1 origin "$REF"
    "$GIT_BIN" -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD"
  else
    log "cloning $REPO ($REF) -> $SRC_DIR"
    rm -rf "$SRC_DIR"
    if ! "$GIT_BIN" clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null; then
      "$GIT_BIN" clone --depth 1 "$REPO" "$SRC_DIR"
      "$GIT_BIN" -C "$SRC_DIR" fetch --depth 1 origin "$REF" || true
      "$GIT_BIN" -C "$SRC_DIR" checkout -f -B "install/$REF" "FETCH_HEAD" 2>/dev/null || true
    fi
  fi
  [ -f "$SRC_DIR/pyproject.toml" ] || die "checkout missing pyproject.toml"
  log "source=$("$GIT_BIN" -C "$SRC_DIR" rev-parse --short HEAD) ref=$REF"
}

write_mise_shim() {
  local ragctl_bin=$1
  [ -n "$MISE_BIN" ] || return 0
  "$MISE_BIN" reshim >/dev/null 2>&1 || true
  local shim_dir="$MISE_DATA_DIR/shims"
  mkdir -p "$shim_dir"
  cat >"$shim_dir/ragctl" <<EOF
#!/bin/sh
exec $(printf '%q' "$ragctl_bin") "\$@"
EOF
  chmod 755 "$shim_dir/ragctl"
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$ragctl_bin" "$HOME/.local/bin/ragctl" 2>/dev/null || true
}

install_via_uv_fallback() {
  fetch_checkout
  mkdir -p "$BIN_DIR"
  log "fallback: uv tool install --from checkout package hf-rag (script: ragctl)"
  # Project name is hf-rag; console script entry point is ragctl.
  UV_TOOL_BIN_DIR="$BIN_DIR" "$UV_BIN" tool install --from "$SRC_DIR" --force --python 3.11 hf-rag \
    || UV_TOOL_BIN_DIR="$BIN_DIR" "$UV_BIN" tool install --from "$SRC_DIR" --force hf-rag \
    || die "uv tool install failed"
  [ -x "$BIN_DIR/ragctl" ] || die "ragctl binary missing at $BIN_DIR/ragctl"
  write_mise_shim "$BIN_DIR/ragctl"
  printf '%s' "$BIN_DIR/ragctl"
}

smoke() {
  local bin="$1"
  "$bin" --help >/dev/null || die "ragctl --help failed"
}

main() {
  log "hf-rag install.sh repo=$REPO ref=$REF"
  bootstrap_mise
  ensure_uv
  ensure_python

  local ragctl_bin="" method="mise"
  if install_via_mise_use; then
    ragctl_bin=$(resolve_ragctl_from_mise || true)
  fi
  if [ -z "${ragctl_bin:-}" ]; then
    method="uv-fallback"
    ragctl_bin=$(install_via_uv_fallback)
  else
    write_mise_shim "$ragctl_bin"
  fi
  [ -n "$ragctl_bin" ] && [ -x "$ragctl_bin" ] || die "ragctl not found after install"
  smoke "$ragctl_bin"

  log "ragctl_installed path=$ragctl_bin"
  log "next (run in THIS shell or add to ~/.bashrc):"
  # Hermes/raven boxes often keep tools under /opt/data while HOME=/root.
  if [ -d /opt/data ]; then
    log "  export PATH=\"/opt/data/.local/bin:/opt/data/.local/share/mise/shims:\$PATH\""
    log "  # credentials are discovered from /opt/data/.config/hf-rag/credentials.toml after host setup"
  fi
  log "  export PATH=\"$HOME/.local/bin:$MISE_DATA_DIR/shims:\$PATH\""
  log "  eval \"\$($MISE_BIN activate bash)\"   # optional"
  log "  ragctl --help"
  log "If doctor fails with connection refused inside a container:"
  log "  on host: sh /home/obj/srv/hf-rag/app/deploy/scripts/setup-container-client.sh hermes-ai-safety-hermes-1"
  log "upgrade: curl -fsSL https://raw.githubusercontent.com/RyderFreeman4Logos/hf-rag/main/install.sh | bash"
  log "ok ($method)"
}

main "$@"
