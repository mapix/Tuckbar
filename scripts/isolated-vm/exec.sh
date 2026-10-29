#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec "$menuy_tart_bin" exec "$menuy_vm_name" "$@"
