#!/usr/bin/env bash
# backup-now_test.sh — lima/scripts/backup-now.sh runs one vm.backup or volume.backup on dev now.
#
# WHY this file exists: a backup is asked once a day per VM and volume, so a measurement of a backup on dev waited for
# the next day's hourly pass, twice in a row (BACKUP-OLD-COPY-CLEANUP). The script drops today's finished row of one
# resource and runs the control plane's schedule job at once. It runs against a fake `kubectl` that keeps one row.
#
# Run:  bash lima/tests/backup-now_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/backup-now.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

VM=0b8d3c2e-5a1f-4c3a-9d7e-1f2a3b4c5d6e
KEY="vm-backup-$VM-20261122"

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# One row of core.provider_commands in $FAKE_ROW as "status|attempts|last_error" (no file: no row). `create job` makes the
# row Pending when there is none; after FAKE_POLLS reads of it, the row becomes $FAKE_END.
printf '%s\n' "$*" >> "$FAKE_LOG"
args=("$@")
verb=""
for a in "${args[@]}"; do
  case "$a" in get|exec|create|wait|delete) verb=$a; break ;; esac
done
case "$verb" in
  get) echo "pod/titan-db-1" ;;
  create)
    if [ ! -f "$FAKE_ROW" ] && [ -z "${FAKE_NO_ROW:-}" ]; then echo "Pending|0|" > "$FAKE_ROW"; fi
    ;;
  wait|delete) ;;
  exec)
    sql="${args[${#args[@]}-1]}"
    case "$sql" in
      delete*) rm -f "$FAKE_ROW" ;;
      select*)
        [ -f "$FAKE_ROW" ] || exit 0
        reads=$(cat "$FAKE_READS" 2>/dev/null || echo 0)
        reads=$((reads + 1))
        echo "$reads" > "$FAKE_READS"
        if [ "$reads" -gt "${FAKE_POLLS:-0}" ] && [ -n "${FAKE_END:-}" ] && grep -q '^Pending\|^Leased' "$FAKE_ROW"; then
          echo "$FAKE_END" > "$FAKE_ROW"
        fi
        cat "$FAKE_ROW"
        ;;
      *) echo "unexpected sql: $sql" >&2; exit 2 ;;
    esac
    ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/kubectl"

# A host-memory.sh that says what $FAKE_MEMORY holds, and the arguments it got.
cat > "$WORK/host-memory.sh" <<'FAKE'
#!/bin/bash
echo "$*" > "$FAKE_MEMORY_ARGS"
echo "${FAKE_MEMORY:-HOST_MEMORY=OK available=9000MiB swap_used=0%}"
case "${FAKE_MEMORY:-OK}" in *LOW*) exit 1 ;; *ERROR*) exit 2 ;; *) exit 0 ;; esac
FAKE
chmod +x "$WORK/host-memory.sh"

run() {  # run ARGS... (env from the caller's FAKE_* variables)
  : > "$WORK/kubectl.log"
  rm -f "$WORK/reads" "$WORK/memory-args"
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/kubectl.log" FAKE_ROW="$WORK/row" \
    FAKE_READS="$WORK/reads" FAKE_MEMORY_ARGS="$WORK/memory-args" BACKUP_NOW_HOST_MEMORY="$WORK/host-memory.sh" \
    BACKUP_NOW_DAY=20261122 BACKUP_NOW_POLL_SECONDS=0 \
    bash "$SCRIPT" "$@" 2>&1 </dev/null)
  RC=$?
}
row() { if [ -n "${1:-}" ]; then echo "$1" > "$WORK/row"; else rm -f "$WORK/row"; fi; }
line_of() { grep -n -m1 -- "$1" "$WORK/kubectl.log" | cut -d: -f1; }
unset FAKE_NO_ROW FAKE_END FAKE_POLLS FAKE_MEMORY

echo "a finished row of today"
row "Done|1|"
FAKE_END="Done|1|" FAKE_POLLS=2 run vm "$VM"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[[ "$OUT" == *"BACKUP_NOW=Done key=$KEY attempts=1"* ]] && ok "says Done, with the key" || bad "output: $OUT"
d=$(line_of "delete from core.provider_commands"); c=$(line_of "create job")
[ -n "$d" ] && [ -n "$c" ] && [ "$d" -lt "$c" ] && ok "drops the finished row before it runs the schedule" || bad "order: delete=$d create=$c"
grep -q "where key = '$KEY' and status in ('Done','Failed')" "$WORK/kubectl.log" && ok "the delete names the one key and only finished rows" || bad "delete sql: $(grep 'delete from' "$WORK/kubectl.log")"
grep -q -- "--from=cronjob/control-plane-job-backup-schedule" "$WORK/kubectl.log" && ok "runs the control plane's schedule job" || bad "no job from the cronjob"
[ "$(cat "$WORK/memory-args")" = "--strict" ] && ok "checks the host strictly first" || bad "host-memory args: $(cat "$WORK/memory-args" 2>/dev/null)"

echo "a failed row of today is dropped too; a volume has its own key"
row "Failed|5|boom"
FAKE_END="Done|1|" FAKE_POLLS=0 run volume "$VM"
[ "$RC" -eq 0 ] && grep -q "delete from core.provider_commands where key = 'volume-backup-$VM-20261122'" "$WORK/kubectl.log" \
  && ok "volume: key volume-backup-…" || bad "exit $RC, log: $(cat "$WORK/kubectl.log")"

echo "no row yet: nothing to drop"
row ""
FAKE_END="Done|1|" FAKE_POLLS=1 run vm "$VM"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q "delete from" "$WORK/kubectl.log" && bad "deleted with no row" || ok "does not delete"

echo "a row still queued or running is not dropped and not asked again"
row "Pending|0|"
FAKE_END="Done|1|" FAKE_POLLS=1 run vm "$VM"
[ "$RC" -eq 0 ] && ok "exit 0: waits for it" || bad "exit $RC: $OUT"
grep -q "delete from\|create job" "$WORK/kubectl.log" && bad "touched a queued row: $(cat "$WORK/kubectl.log")" || ok "no delete, no job"

echo "the command fails for good"
row "Done|1|"
FAKE_END="Failed|5|volume x is not in project p" FAKE_POLLS=1 run vm "$VM"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC: $OUT"
[[ "$OUT" == *"BACKUP_NOW=Failed key=$KEY attempts=5 error=volume x is not in project p"* ]] && ok "says Failed with the error" || bad "output: $OUT"

echo "the schedule does not queue it (no such resource on Incus)"
row ""
FAKE_NO_ROW=1 run vm "$VM"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"BACKUP_NOW=NOT_QUEUED key=$KEY"* ]] && ok "exit 1, NOT_QUEUED" || bad "exit $RC: $OUT"
unset FAKE_NO_ROW

echo "the row never ends"
row "Pending|0|"
run vm "$VM" --timeout 0
[ "$RC" -eq 4 ] && [[ "$OUT" == *"BACKUP_NOW=TIMEOUT key=$KEY"* ]] && ok "exit 4, TIMEOUT" || bad "exit $RC: $OUT"

echo "the host is short of memory"
row "Done|1|"
FAKE_MEMORY="HOST_MEMORY=LOW available=3163MiB swap_used=54% (strict: wants available >= 4096MiB and swap_used <= 25%)" run vm "$VM"
[ "$RC" -eq 3 ] && [[ "$OUT" == *"HOST_MEMORY=LOW"* ]] && ok "exit 3, says why" || bad "exit $RC: $OUT"
[ ! -s "$WORK/kubectl.log" ] && ok "asks the cluster nothing" || bad "kubectl called: $(cat "$WORK/kubectl.log")"
FAKE_MEMORY="HOST_MEMORY=ERROR cannot read MemAvailable" run vm "$VM"
[ "$RC" -eq 3 ] && ok "an ERROR reading is not OK either" || bad "exit $RC: $OUT"
unset FAKE_MEMORY
FAKE_MEMORY="HOST_MEMORY=SKIPPED Darwin has no /proc/meminfo" FAKE_END="Done|1|" FAKE_POLLS=0 run vm "$VM"
[ "$RC" -eq 0 ] && ok "SKIPPED goes on" || bad "exit $RC: $OUT"
unset FAKE_MEMORY

echo "bad arguments reach nothing"
row "Done|1|"
for args in "vm" "disk $VM" "vm not-an-id" "vm $VM'; drop table core.vms; --" "vm $VM --timeout abc" "vm $VM --unknown"; do
  # shellcheck disable=SC2086
  run $args
  if [ "$RC" -eq 2 ] && [ ! -s "$WORK/kubectl.log" ]; then ok "exit 2, nothing called: $args"; else bad "'$args' exit $RC, log: $(cat "$WORK/kubectl.log") out: $OUT"; fi
done

# One argument that has SQL inside it between the first eight hex digits and the rest of an id.
run vm "0b8d3c2e'; select 1; -5a1f-4c3a-9d7e-1f2a3b4c5d6e"
if [ "$RC" -eq 2 ] && [ ! -s "$WORK/kubectl.log" ]; then ok "exit 2, nothing called: SQL inside the id"; else bad "SQL in the id: exit $RC, log: $(cat "$WORK/kubectl.log")"; fi

echo
echo "backup-now_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
