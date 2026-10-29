#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
# Recovery must run only after the normal VM is gracefully stopped.
# --no-graphics makes Tart print a hardware-VNC endpoint without opening host UI.
# The endpoint includes a generated private credential: keep its run log private.
exec "$menuy_tart_bin" run "$menuy_vm_name" --recovery --no-graphics --vnc-experimental \
  --no-audio --no-clipboard --no-usb-accessories
