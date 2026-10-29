#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$menuy_workspace/artifacts/vm"
if tart list --source local --format json | python3 -c 'import json,sys; name=sys.argv[1]; rows=json.load(sys.stdin); rows=rows if isinstance(rows,list) else rows.get("vms",[]); sys.exit(0 if any(r.get("Name",r.get("name"))==name and str(r.get("State",r.get("state",""))).lower()=="running" for r in rows) else 1)' "$menuy_vm_name"; then
  printf 'VM is already running: %s\n' "$menuy_vm_name"
  exit 0
fi
nohup "$menuy_workspace/scripts/isolated-vm/run.sh" > "$menuy_workspace/artifacts/vm/run.log" 2>&1 < /dev/null &
menuy_run_pid=$!
printf '%s\n' "$menuy_run_pid" > "$menuy_workspace/artifacts/vm/run.pid"
printf 'VM background process: %s\n' "$menuy_run_pid"
