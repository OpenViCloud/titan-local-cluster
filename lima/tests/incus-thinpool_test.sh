#!/usr/bin/env bash
# incus-thinpool_test.sh — lima/scripts/incus-thinpool.sh stops up.sh when titan-incus's LVM thin pool is not active.
#
# WHY this file exists: after a stop the pool can come back broken (`Check of pool default/IncusThinPool failed … Manual
# repair required!`). Provision still finishes, Incus still starts, and the first sign is a customer VM that fails to start
# (docs/topology.md#runbook). So up.sh reads the pool once titan-incus is provisioned and stops with the runbook's
# commands. It runs against a fake `limactl` that answers `lvs` from $FAKE_LVS.
#
# Run:  bash lima/tests/incus-thinpool_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/incus-thinpool.sh"
UP="$HERE/../scripts/up.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl shell titan-incus -- sudo lvs …: prints $FAKE_LVS and exits $FAKE_LVS_RC; anything else is unexpected.
printf '%s\n' "$*" >> "$FAKE_LOG"
[ "$1 $2 $3 $4 $5" = "shell titan-incus -- sudo lvs" ] || { echo "unexpected: $*" >&2; exit 2; }
[ -z "${FAKE_LVS_WARN:-}" ] || echo "$FAKE_LVS_WARN" >&2
printf '%s' "$FAKE_LVS"
exit "${FAKE_LVS_RC:-0}"
FAKE
chmod +x "$WORK/bin/limactl"

# run <lvs json> [lvs exit code]
run() {
  : > "$WORK/log"
  OUT=$(FAKE_LOG="$WORK/log" FAKE_LVS="$1" FAKE_LVS_RC="${2:-0}" PATH="$WORK/bin:$PATH" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}
lvs_json() {  # lvs_json <lv_active>: one LV IncusThinPool, as `lvs --reportformat json` prints it
  printf '  {\n      "report": [\n          {\n              "lv": [\n                  {"lv_name":"IncusThinPool", "lv_active":"%s"}\n              ]\n          }\n      ]\n  }\n' "$1"
}

echo "an active pool"
run "$(lvs_json active)"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q -- '--reportformat json' "$WORK/log" && grep -q 'default/IncusThinPool' "$WORK/log" && grep -q 'lv_active' "$WORK/log" \
  && ok "reads lv_active of default/IncusThinPool as JSON" || bad "lvs call: $(cat "$WORK/log")"

echo "an active pool, with a warning of LVM on stderr"
: > "$WORK/log"
OUT=$(FAKE_LOG="$WORK/log" FAKE_LVS="$(lvs_json active)" FAKE_LVS_WARN="  WARNING: Sum of all thin volume sizes exceeds the size of thin pools." \
  PATH="$WORK/bin:$PATH" bash "$SCRIPT" 2>/dev/null </dev/null); RC=$?
[ "$RC" -eq 0 ] && ok "exit 0: stderr is not read as part of the report" || bad "exit $RC: $OUT"

echo "a pool that is not active (the broken pool after a stop)"
run "$(lvs_json '')"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q '^ERROR: .*IncusThinPool' && ok "says the pool is not active" || bad "message: $OUT"
for cmd in 'systemctl stop incus.service incus.socket' 'lvconvert --repair -y default/IncusThinPool' 'vgchange -ay default' \
  'systemctl start incus.socket incus.service'; do
  printf '%s' "$OUT" | grep -qF "$cmd" && ok "prints the runbook step: $cmd" || bad "no '$cmd' in: $OUT"
done

echo "no pool, or lvs fails"
run '  {"report": [{"lv": []}]}'
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^ERROR: ' && ok "no LV IncusThinPool: exit 1 with an error" || bad "no LV: exit $RC: $OUT"
run '' 5
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^ERROR: could not read ' && [ "$(printf '%s\n' "$OUT" | grep -c '^ERROR: ')" = 1 ] \
  && ok "lvs fails: exit 1 at once, says it could not read the pool" \
  || bad "lvs fails: exit $RC: $OUT"
run 'not json'
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q '^ERROR: ' && ok "output that is not JSON: exit 1 with an error" || bad "not JSON: exit $RC: $OUT"

echo "up.sh runs it"
order=$(awk '/^done$/ && !loop { loop = NR } /^bash "\$here\/scripts\/incus-thinpool\.sh"$/ && !pool { pool = NR } /trust-extra-ca\.sh"$/ && loop && !ca { ca = NR }
  END { print (loop && pool > loop && pool < ca) ? "ok" : "loop=" loop " pool=" pool " ca=" ca }' "$UP")
[ "$order" = ok ] && ok "after the VMs are provisioned, before anything is written into them" || bad "up.sh order: $order"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
