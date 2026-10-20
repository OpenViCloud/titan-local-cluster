#!/bin/bash
# Stops both VMs: a running VM keeps the guest memory it ever touched, only a stop gives it back to macOS
# (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md#ram-budget, R-1). Disks and data stay.
set -euo pipefail
for vm in titan-k3s titan-incus; do
  status=$(limactl list --format '{{.Status}}' "$vm" 2>/dev/null || true)
  if [ "$status" = "Running" ]; then
    limactl stop "$vm"
  fi
done
