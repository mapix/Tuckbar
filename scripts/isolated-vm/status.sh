#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
"$menuy_tart_bin" list --format json
"$menuy_tart_bin" ip "$menuy_vm_name" --resolver agent --wait 0 || true
