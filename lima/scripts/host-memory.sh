#!/bin/bash
# host-memory.sh: is there room on the host for the local cluster to work (docs/topology.md#host-memory)? On Ubuntu a
# host whose swap fills up stalls a VM's guest until its Incus stops answering, with no error anywhere. A session runs it
# before a pass that writes to the cluster and goes on only on OK or SKIPPED; up.sh runs it last and only warns.
#
# Prints one line, HOST_MEMORY=<word> ..., and exits:
#   0  OK (no swap counts as 0%), or SKIPPED on any OS but Linux (macOS: no /proc/meminfo)
#   1  LOW: MemAvailable under 2048 MiB, or swap in use above 75% (a whole percent, rounded down)
#   2  ERROR: the meminfo file cannot be read, has no MemAvailable, or has a field that is not a number
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

fields=$(awk '
  /^MemAvailable:/ { available = $2 }
  /^SwapTotal:/ { total = $2 }
  /^SwapFree:/ { free = $2 }
  END { print (available == "" ? "-" : available), (total == "" ? 0 : total), (free == "" ? 0 : free) }
' "$meminfo" 2>/dev/null) || fields="-"
read -r available_kib swap_total_kib swap_free_kib <<< "$fields"
for value in "$available_kib" "${swap_total_kib:-}" "${swap_free_kib:-}"; do
  case "$value" in
    "" | *[!0-9]*) available_kib="-" ;;
  esac
done
if [ "$available_kib" = "-" ]; then
  echo "HOST_MEMORY=ERROR cannot read MemAvailable, SwapTotal and SwapFree as numbers from $meminfo"
  exit 2
fi

available_mib=$((available_kib / 1024))
swap_used_percent=0
if [ "$swap_total_kib" -gt 0 ]; then
  swap_used_percent=$(((swap_total_kib - swap_free_kib) * 100 / swap_total_kib))
  [ "$swap_used_percent" -ge 0 ] || swap_used_percent=0
fi
reading="available=${available_mib}MiB swap_used=${swap_used_percent}%"

if [ "$available_mib" -lt "$min_available_mib" ] || [ "$swap_used_percent" -gt "$max_swap_used_percent" ]; then
  echo "HOST_MEMORY=LOW $reading (wants available >= ${min_available_mib}MiB and swap_used <= ${max_swap_used_percent}%; free RAM on the host first: docs/topology.md#host-memory)"
  exit 1
fi
echo "HOST_MEMORY=OK $reading"
