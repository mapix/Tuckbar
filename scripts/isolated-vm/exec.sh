#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec tart exec "$menuy_vm_name" "$@"
