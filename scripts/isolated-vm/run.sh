#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$menuy_workspace/artifacts/vm/share"
tart set "$menuy_vm_name" --cpu 4 --memory 8192 --display 1728x1117pt --no-display-refit
# Only the task's artifact staging folder is shared, read-only. Clipboard,
# host audio and USB accessory passthrough are disabled; no GUI opens on host.
exec tart run "$menuy_vm_name" --no-graphics --no-audio --no-clipboard --no-usb-accessories \
  --dir="menuy:$menuy_workspace/artifacts/vm/share:ro"
