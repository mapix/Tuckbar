#!/bin/bash
# Source this file only from MacMenuY's VM scripts.
set -euo pipefail
menuy_workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export TART_HOME="$menuy_workspace/artifacts/vm/tart-home"
export TART_NO_AUTO_PRUNE=1
menuy_vm_name="${MENUY_VM_NAME:-menuy-tahoe}"
