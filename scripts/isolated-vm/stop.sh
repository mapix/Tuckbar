#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
"$menuy_tart_bin" stop "$menuy_vm_name" --timeout 20 2>/dev/null || true
launchctl remove io.novarock.MacMenuY.VerificationVM 2>/dev/null || true
launchctl remove io.novarock.MacMenuY.GuestVNCProxy 2>/dev/null || true
