#!/bin/bash
# Stops up.sh when titan-incus's LVM thin pool is not active. After a stop it can come back broken: provision finishes,
# Incus starts, and only a customer VM's start fails (docs/topology.md#runbook, "The Incus thin pool is broken"). Prints
# the repair, which an agent asks Tôn Chủ about before running: OS commands inside the VM.
# Needs: titan-incus running and provisioned.
set -euo pipefail

POOL=default/IncusThinPool

if ! report=$(limactl shell titan-incus -- sudo lvs --reportformat json -o lv_name,lv_active "$POOL" 2>&1); then
  echo "ERROR: could not read $POOL in titan-incus: $report" >&2
  exit 1
fi
if ! active=$(python3 -c '
import json, sys
lvs = json.loads(sys.stdin.read())["report"][0]["lv"]
print(lvs[0]["lv_active"] if lvs else "missing")
' <<< "$report" 2>/dev/null); then
  echo "ERROR: lvs printed no report for $POOL in titan-incus: $report" >&2
  exit 1
fi
if [ "$active" != "active" ]; then
  cat >&2 <<MSG
ERROR: the Incus thin pool $POOL in titan-incus is not active (${active:-inactive}); customer VMs cannot start.
Repair it inside titan-incus (limactl shell titan-incus), then run up.sh again (docs/topology.md#runbook):
  sudo systemctl stop incus.service incus.socket
  sudo lvconvert --repair -y $POOL
  sudo vgchange -ay default
  sudo systemctl start incus.socket incus.service
MSG
  exit 1
fi
echo "titan-incus: thin pool $POOL active"
