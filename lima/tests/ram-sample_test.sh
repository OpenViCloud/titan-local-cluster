#!/usr/bin/env bash
# ram-sample_test.sh — lima/scripts/ram-sample.sh.
#
# WHY this file exists: a release measures the peak RAM of titan-k3s over a whole dev pass before titan-k3s may go to
# 5 GiB on Ubuntu (docs/topology.md#host-memory). The sampler must keep going when the guest stops answering (as it did on
# 2026-11-20), write a log the release record accepts (first line `#`), and end when the stop file appears. It runs here
# against a fake limactl.
#
# Run:  bash lima/tests/ram-sample_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/ram-sample.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ "$(uname -s)" != "Linux" ]; then
  echo "ram-sample_test: Linux only, skipped"
  exit 0
fi

printf '#!/bin/bash\n[ "$1 $2" = "shell titan-k3s" ] || { echo "wrong call: $*"; exit 3; }\necho "Mem: 5919 3961 362 321 2217 1958"\necho "full avg10=0.00"\n' > "$WORK/limactl-ok"
printf '#!/bin/bash\nexit 1\n' > "$WORK/limactl-down"
printf '#!/bin/bash\nsleep 5\n' > "$WORK/limactl-stalled"
chmod +x "$WORK/limactl-ok" "$WORK/limactl-stalled" "$WORK/limactl-down"

run() {  # run FAKE LOG [STOP]: samples every second, makes the stop file after about 2.5 s, waits for the loop to end
  local stop=${3:-"$WORK/stop-$RANDOM"}
  RAM_SAMPLE_LIMACTL="$WORK/$1" RAM_SAMPLE_TIMEOUT=1 bash "$SCRIPT" "$2" "$stop" 1 &
  local pid=$!
  sleep 2.5
  touch "$stop"
  wait "$pid"
}

echo "ram-sample.sh"
log="$WORK/new/dir/k3s-ram.log"
run limactl-ok "$log"
code=$?
first=$(head -n 1 "$log")
[ "$code" -eq 0 ] && ok "ends with exit 0 once the stop file exists" || bad "exit $code"
[[ "$first" == "# bash lima/scripts/ram-sample.sh "*" · host "*" and VM titan-k3s · "* ]] && ok "first line is the evidence header" || bad "first line: $first"
[ "$(grep -c '^== 20' "$log")" -ge 2 ] && ok "at least two samples" || bad "samples: $(grep -c '^== 20' "$log")"
samples=$(grep -c '^== 20' "$log")
[ "$(grep -c '^HOST_MEMORY=' "$log")" -eq "$samples" ] && ok "each sample has the host check" || bad "HOST_MEMORY lines vs $samples samples"
[ "$(grep -c '^Mem: 5919' "$log")" -eq "$samples" ] && ok "each sample has the guest's free -m, asked of titan-k3s" || bad "guest readings vs $samples samples: $(grep -m1 'wrong call' "$log")"
[[ "$(tail -n 1 "$log")" == "== stop "* ]] && ok "last line says the loop stopped" || bad "last line: $(tail -n 1 "$log")"

log2="$WORK/stalled.log"
run limactl-stalled "$log2"
[ "$(grep -c '^titan-k3s: no answer within 1 s' "$log2")" -ge 2 ] && ok "a stalled guest leaves a line and the loop goes on" || bad "stalled guest: $(cat "$log2")"
[[ "$(tail -n 1 "$log2")" == "== stop "* ]] && ok "the stalled run still stops" || bad "stalled last line: $(tail -n 1 "$log2")"

log3="$WORK/down.log"
run limactl-down "$log3"
grep -q '^titan-k3s: limactl exited 1' "$log3" && ! grep -q 'no answer' "$log3" && ok "a stopped VM is not reported as a stalled guest" || bad "stopped VM: $(cat "$log3")"

touch "$WORK/old-stop"
run limactl-ok "$WORK/old-stop.log" "$WORK/old-stop"
[ "$(grep -c '^== 20' "$WORK/old-stop.log")" -ge 2 ] && ok "a stop file left from an earlier run does not end the new one" || bad "stale stop file: $(cat "$WORK/old-stop.log")"

for every in 0 abc; do
  bash "$SCRIPT" "$WORK/bad.log" "$WORK/bad.stop" "$every" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "SECONDS=$every: exit 2" || bad "SECONDS=$every accepted"
done

echo "existing" > "$WORK/kept.log"
run limactl-ok "$WORK/kept.log"
[ "$(head -n 1 "$WORK/kept.log")" = "existing" ] && ok "an existing log gets no second header" || bad "header added to an existing log"

bash "$SCRIPT" "$WORK/x.log" >/dev/null 2>&1
[ $? -eq 2 ] && ok "missing STOP_FILE argument: exit 2" || bad "missing argument"

echo
echo "ram-sample_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
