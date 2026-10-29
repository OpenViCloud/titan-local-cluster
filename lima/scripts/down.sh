#!/bin/bash
# Stops both VMs: a running VM keeps the guest memory it ever touched, only a stop gives it back to the host
# (docs/topology.md#ram-budget, R-1). Disks stay; guest VMs
# in titan-incus stop too, and Incus's LVM pool once needed a repair after this stop (README).
set -euo pipefail
for vm in titan-k3s titan-incus; do
  status=$(limactl list --format '{{.Status}}' "$vm" 2>/dev/null || true)
  if [ "$status" = "Running" ]; then
    limactl stop "$vm"
  fi
done
