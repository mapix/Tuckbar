#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$menuy_workspace/artifacts/vm"
if "$menuy_tart_bin" list --source local --quiet | rg -x "$menuy_vm_name" >/dev/null; then
  printf 'VM already exists: %s\n' "$menuy_vm_name"
  exit 0
fi
"$menuy_tart_bin" clone ghcr.io/cirruslabs/macos-tahoe-base:latest "$menuy_vm_name" --concurrency 4
