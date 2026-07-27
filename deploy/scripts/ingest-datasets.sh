#!/usr/bin/env sh
# Starts the bounded user service. Progress is counts-only; never use set -x.
set -eu
set +x
if [ "$(id -un)" != "obj" ]; then
  printf '%s\n' 'must run as obj' >&2
  exit 1
fi
systemctl --user start --wait rag-ingest@datasets.service
systemctl --user status --no-pager rag-ingest@datasets.service
