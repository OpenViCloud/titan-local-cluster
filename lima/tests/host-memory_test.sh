#!/usr/bin/env bash
# host-memory_test.sh — lima/scripts/host-memory.sh and its call in lima/scripts/up.sh.
#
# WHY this file exists: on 2026-11-20 the Ubuntu host's swap filled up and titan-incus's guest stalled for nine hours
# while every pod looked healthy (docs/topology.md#ram-2026-11-20). The check says LOW before a pass writes to the
# cluster. It runs against fake /proc/meminfo files; up.sh is read, not run.
#
# Run:  bash lima/tests/host-memory_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/host-memory.sh"
UP="$HERE/../scripts/up.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

meminfo() {  # meminfo AVAILABLE_KIB SWAP_TOTAL_KIB SWAP_FREE_KIB
  printf 'MemTotal:       15777388 kB\nMemFree:          332000 kB\nMemAvailable:   %s kB\nSwapTotal:      %s kB\nSwapFree:       %s kB\n' "$1" "$2" "$3" > "$WORK/meminfo"
}

check() {  # check NAME WANT_EXIT WANT_PREFIX
  local out code
  out=$(HOST_OS=Linux HOST_MEMINFO="$WORK/meminfo" bash "$SCRIPT" 2>&1)
  code=$?
  if [ "$code" -eq "$2" ] && [[ "$out" == "$3"* ]]; then ok "$1"; else bad "$1 (exit $code: $out)"; fi
}

echo "host-memory.sh"
meminfo 4456884 4194300 2210388
check "4352 MiB available, 47% swap used: OK" 0 "HOST_MEMORY=OK available=4352MiB swap_used=47%"
# The reading of 2026-11-20 at 15:13Z, while titan-incus's guest was stalled (docs/topology.md#ram-2026-11-20).
meminfo 2707456 4194300 7168
check "swap 99% used: LOW" 1 "HOST_MEMORY=LOW available=2644MiB swap_used=99%"
meminfo 1048576 4194300 4194300
check "1024 MiB available, no swap used: LOW" 1 "HOST_MEMORY=LOW available=1024MiB swap_used=0%"
meminfo 2097152 4194300 1048575
check "2048 MiB and 75% swap are still OK" 0 "HOST_MEMORY=OK available=2048MiB swap_used=75%"
meminfo 2096128 4194300 4194300
check "2047 MiB available: LOW" 1 "HOST_MEMORY=LOW available=2047MiB swap_used=0%"
meminfo 8388608 4194300 1006632
check "76% swap used: LOW" 1 "HOST_MEMORY=LOW available=8192MiB swap_used=76%"
meminfo 8388608 0 0
check "no swap at all: OK" 0 "HOST_MEMORY=OK available=8192MiB swap_used=0%"
printf 'MemTotal: 1 kB\n' > "$WORK/meminfo"
check "no MemAvailable: ERROR, not OK" 2 "HOST_MEMORY=ERROR cannot read MemAvailable"
rm -f "$WORK/meminfo"
check "no meminfo file: ERROR, not OK" 2 "HOST_MEMORY=ERROR cannot read MemAvailable"
out=$(HOST_OS=Darwin bash "$SCRIPT")
code=$?
if [ "$code" -eq 0 ] && [[ "$out" == "HOST_MEMORY=SKIPPED Darwin"* ]]; then ok "macOS: SKIPPED"; else bad "macOS (exit $code: $out)"; fi

echo "up.sh"
call=$(grep -n 'scripts/host-memory.sh' "$UP" | grep -v '^[0-9]*:[[:space:]]*#' || true)
if [ "$(printf '%s\n' "$call" | grep -c .)" -ne 1 ]; then bad "up.sh: want one call, got: ${call:-none}"; fi
if [ -n "$call" ] && [[ "$call" == *'|| echo "WARNING:'* ]]; then ok "up.sh runs the check and only warns"; else bad "up.sh call: ${call:-none}"; fi
last_step=$(grep -n 'drop-old-applications.sh"$' "$UP" | cut -d: -f1)
call_line=${call%%:*}
if [ -n "$call_line" ] && [ -n "$last_step" ] && [ "$call_line" -gt "$last_step" ]; then ok "up.sh checks after both VMs and root are up"; else bad "up.sh checks at line ${call_line:-?}, last step at ${last_step:-?}"; fi

# Run up.sh's own line under its shell options, with a check that says LOW: up.sh must go on and say why.
mkdir -p "$WORK/fake/scripts"
printf '#!/bin/bash\necho "HOST_MEMORY=LOW available=1MiB swap_used=99%%"\nexit 1\n' > "$WORK/fake/scripts/host-memory.sh"
line=${call#*:}
out=$(here="$WORK/fake" bash -c "set -euo pipefail; $line; echo AFTER" 2>&1)
code=$?
if [ "$code" -eq 0 ] && [[ "$out" == *"WARNING: host-memory.sh exited 1"* ]] && [[ "$out" == *AFTER ]]; then ok "LOW only warns: up.sh goes on"; else bad "LOW in up.sh (exit $code: $out)"; fi

echo
echo "host-memory_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
