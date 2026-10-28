#!/usr/bin/env bash
# ports-free_test.sh — lima/scripts/ports-free.py and its call in lima/scripts/up.sh.
#
# WHY this file exists: when another cluster (another user, another LIMA_HOME, or the same VMs started elsewhere) holds a
# host port of a VM, Lima only warns that it cannot listen and starts the VM anyway; up.sh then talks to the other
# cluster's k3s and stops much later on an x509 error. Before it starts a VM that is not running, up.sh checks every host
# port of that VM is free and stops with the port's number. The script runs against a real socket; up.sh runs against a
# fake `limactl`.
#
# Run:  bash lima/tests/ports-free_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/ports-free.py"
UP="$HERE/../scripts/up.sh"
WORK=$(mktemp -d)
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# A process that listens on a free port of 127.0.0.1 and prints it.
python3 -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
print(s.getsockname()[1], flush=True)
time.sleep(600)
' > "$WORK/held" &
HOLDER=$!
for _ in $(seq 1 50); do [ -s "$WORK/held" ] && break; sleep 0.1; done
HELD=$(cat "$WORK/held")
FREE=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

# The JSON `limactl list --json NAME` prints. Lima adds guestPortRange (and hostPortRange) to every rule, as it does here.
instance() {  # instance RULE_JSON ...
  python3 -c '
import json, sys
rules = [json.loads(r) for r in sys.argv[1:]]
for r in rules:
    if "guestPort" in r:
        r.setdefault("guestPortRange", [r["guestPort"], r["guestPort"]])
        h = r.get("hostPort", r["guestPort"]); r.setdefault("hostPortRange", [h, h])
print(json.dumps({"name": "titan-k3s", "status": "Stopped", "config": {"portForwards": rules}}))
' "$@"
}

echo "ports-free.py"
OUT=$(instance "{\"guestPort\": 80, \"hostIP\": \"127.0.0.1\", \"hostPort\": $FREE}" \
  "{\"guestPort\": 6443, \"hostIP\": \"127.0.0.1\", \"hostPort\": $HELD}" | python3 "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "a held port exits 1" || bad "a held port exits $RC: $OUT"
printf '%s' "$OUT" | grep -q "127.0.0.1:$HELD" && ok "the message names the held port" || bad "message: $OUT"
printf '%s' "$OUT" | grep -q "127.0.0.1:$FREE" && bad "a free port is named: $OUT" || ok "a free port is not named"

OUT=$(instance "{\"guestPort\": 80, \"hostIP\": \"127.0.0.1\", \"hostPort\": $FREE}" | python3 "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "free ports exit 0 and print nothing" || bad "free ports: rc $RC, $OUT"

OUT=$(instance "{\"guestPort\": $HELD, \"hostIP\": \"127.0.0.1\"}" | python3 "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "127.0.0.1:$HELD" && ok "no hostPort: the guest port is the host port" || bad "no hostPort: rc $RC, $OUT"

OUT=$(instance "{\"guestPort\": $HELD, \"hostIP\": \"127.0.0.1\", \"hostPort\": $HELD, \"ignore\": true}" '{"guestIP": "0.0.0.0", "guestPortRange": [1, 65535], "hostIP": "127.0.0.1", "ignore": true}' \
  | python3 "$SCRIPT" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "ignore rules are not checked" || bad "ignore rules: rc $RC, $OUT"

echo "up.sh"
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl list --format '{{.Status}}' VM prints $FAKE_STATUS; list --json VM prints $FAKE_JSON; every call is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "list --format") echo "$FAKE_STATUS" ;;
  "list --json") cat "$FAKE_JSON" ;;
  "shell "*) echo "provision did not finish" ;;
  *) ;;
esac
FAKE
cat > "$WORK/bin/docker" <<'FAKE'
#!/bin/bash
exit 1
FAKE
chmod +x "$WORK/bin/limactl" "$WORK/bin/docker"

run_up() {  # run_up STATUS RULE_JSON
  : > "$WORK/log"
  instance "$2" > "$WORK/json"
  OUT=$(FAKE_LOG="$WORK/log" FAKE_STATUS="$1" FAKE_JSON="$WORK/json" HOME="$WORK/home" PATH="$WORK/bin:$PATH" bash "$UP" 2>&1); RC=$?
}

run_up Stopped "{\"guestPort\": 6443, \"hostIP\": \"127.0.0.1\", \"hostPort\": $HELD}"
[ "$RC" -ne 0 ] && ok "a stopped VM with a held port stops up.sh" || bad "up.sh went on: $OUT"
grep -q '^start ' "$WORK/log" && bad "limactl start was called: $(cat "$WORK/log")" || ok "no VM is started"
printf '%s' "$OUT" | grep -q "127.0.0.1:$HELD" && ok "up.sh names the held port" || bad "message: $OUT"

run_up Running "{\"guestPort\": 6443, \"hostIP\": \"127.0.0.1\", \"hostPort\": $HELD}"
grep -q '^list --json' "$WORK/log" && bad "a running VM was checked: $(cat "$WORK/log")" || ok "a running VM is not checked"
grep -q '^start ' "$WORK/log" && bad "a running VM was started" || ok "a running VM is not started"

run_up Stopped "{\"guestPort\": 6443, \"hostIP\": \"127.0.0.1\", \"hostPort\": $FREE}"
grep -q '^start titan-incus' "$WORK/log" && ok "free ports: the VM is started" || bad "free ports, no start: $(cat "$WORK/log")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
