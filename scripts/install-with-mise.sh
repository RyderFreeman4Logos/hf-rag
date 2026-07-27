#!/usr/bin/env sh
# Install ragctl from this checkout without sudo. It never reads archive contents.
set -eu
set +x

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

if [ ! -f "$repo_root/pyproject.toml" ]; then
    printf '%s\n' 'missing_pyproject_toml' >&2
    exit 1
fi

export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
mise_bin=$(command -v mise || true)
if [ -z "$mise_bin" ]; then
    if ! command -v curl >/dev/null 2>&1; then
        printf '%s\n' 'mise_not_found: install mise first, then rerun this script' >&2
        exit 1
    fi
    bootstrap=$(mktemp "${TMPDIR:-/tmp}/hf-rag-mise.XXXXXX")
    trap 'rm -f "$bootstrap"' EXIT HUP INT TERM
    if ! curl --fail --silent --show-error --location https://mise.run --output "$bootstrap"; then
        printf '%s\n' 'mise_bootstrap_failed: network unavailable or download rejected' >&2
        exit 1
    fi
    sh "$bootstrap"
    rm -f "$bootstrap"
    trap - EXIT HUP INT TERM
    mise_bin=$(command -v mise || true)
fi
if [ -z "$mise_bin" ]; then
    printf '%s\n' 'mise_bootstrap_failed: mise is not on PATH' >&2
    exit 1
fi

if command -v uv >/dev/null 2>&1; then
    tool_bin=${UV_TOOL_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}
    mkdir -p "$tool_bin"
    # Project name is hf-rag; [project.scripts] exposes ragctl.
    UV_TOOL_BIN_DIR="$tool_bin" uv tool install --from "$repo_root" --force hf-rag
    ragctl_bin="$tool_bin/ragctl"
else
    data_home=${XDG_DATA_HOME:-$HOME/.local/share}
    venv=${RAGCTL_VENV:-$data_home/hf-rag/venv}
    python_bin=$(command -v python3.11 || command -v python3 || true)
    if [ -z "$python_bin" ]; then
        printf '%s\n' 'python_not_found: install Python 3.11+ or uv, then retry' >&2
        exit 1
    fi
    if [ ! -x "$venv/bin/python" ]; then
        "$python_bin" -m venv "$venv"
    fi
    "$venv/bin/python" -m pip install --upgrade -e "$repo_root"
    ragctl_bin="$venv/bin/ragctl"
fi

if [ ! -x "$ragctl_bin" ]; then
    printf '%s\n' 'ragctl_install_failed' >&2
    exit 1
fi

# `mise reshim` registers normal user tool bins when possible.  Also install a
# small explicit shim so `eval "$(mise activate bash)"` always resolves ragctl.
"$mise_bin" reshim >/dev/null 2>&1 || true
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
mise_data=${MISE_DATA_DIR:-$data_home/mise}
shim_dir="$mise_data/shims"
mkdir -p "$shim_dir"
quote_for_sh() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
shim_tmp="$shim_dir/.ragctl.$$"
trap 'rm -f "$shim_tmp"' EXIT HUP INT TERM
{
    printf '%s\n' '#!/bin/sh'
    printf 'exec %s "$@"\n' "$(quote_for_sh "$ragctl_bin")"
} > "$shim_tmp"
chmod 755 "$shim_tmp"
mv -f "$shim_tmp" "$shim_dir/ragctl"
"$ragctl_bin" --help >/dev/null
printf '%s\n' 'ragctl_installed_from_local_checkout'
