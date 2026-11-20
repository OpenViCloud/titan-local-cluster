#!/bin/bash
# host-memory.sh: is there room on the host for the local cluster to work (docs/topology.md#host-memory)? On Ubuntu a
# host whose swap fills up stalls a VM's guest until its Incus stops answering, with no error anywhere. Run before a pass
# that writes to the cluster (a regression pass, a dev pull); up.sh runs it and only warns.
#
# Prints one line and exits 0 for HOST_MEMORY=OK or SKIPPED, 1 for HOST_MEMORY=LOW. LOW: MemAvailable under 2048 MiB, or
# more than 75% of the swap in use. macOS has no /proc/meminfo: SKIPPED.
# HOST_MEMINFO and HOST_OS stand in for /proc/meminfo and `uname -s` (lima/tests/host-memory_test.sh).
set -euo pipefail

min_available_mib=2048
max_swap_used_percent=75
os=${HOST_OS:-$(uname -s)}
meminfo=${HOST_MEMINFO:-/proc/meminfo}

if [ "$os" != "Linux" ]; then
  echo "HOST_MEMORY=SKIPPED $os has no /proc/meminfo"
  exit 0
fi

read -r available_kib swap_total_kib swap_free_kib < <(awk '
  /^MemAvailable:/ { available = $2 }
  /^SwapTotal:/ { total = $2 }
  /^SwapFree:/ { free = $2 }
  END { print (available == "" ? "-" : available), total + 0, free + 0 }
' "$meminfo")
if [ "$available_kib" = "-" ]; then
  echo "ERROR: no MemAvailable in $meminfo" >&2
  exit 2
fi

available_mib=$((available_kib / 1024))
swap_used_percent=0
if [ "$swap_total_kib" -gt 0 ]; then
  swap_used_percent=$(((swap_total_kib - swap_free_kib) * 100 / swap_total_kib))
fi
reading="available=${available_mib}MiB swap_used=${swap_used_percent}%"

if [ "$available_mib" -lt "$min_available_mib" ] || [ "$swap_used_percent" -gt "$max_swap_used_percent" ]; then
  echo "HOST_MEMORY=LOW $reading (wants available >= ${min_available_mib}MiB and swap_used <= ${max_swap_used_percent}%; free RAM on the host first: docs/topology.md#host-memory)"
  exit 1
fi
echo "HOST_MEMORY=OK $reading"
