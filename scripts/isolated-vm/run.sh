#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$menuy_workspace/artifacts/vm/share"
"$menuy_tart_bin" set "$menuy_vm_name" --cpu 4 --memory 8192 --display 1728x1117pt --no-display-refit
# Only the task's artifact staging folder is shared, read-only. Clipboard,
# host audio and USB accessory passthrough are disabled; no GUI opens on host.
args=(--no-graphics --no-audio --no-clipboard --no-usb-accessories --dir="menuy:$menuy_workspace/artifacts/vm/share:ro")
if [[ "${MENUY_VM_VNC:-0}" == "1" ]]; then args+=(--vnc-experimental); fi
exec "$menuy_tart_bin" run "$menuy_vm_name" "${args[@]}"
