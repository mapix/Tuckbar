#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
exec tart stop "$menuy_vm_name" --timeout 20
