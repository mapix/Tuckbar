#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
tart list --format json
tart ip "$menuy_vm_name" --resolver agent --wait 0 || true
