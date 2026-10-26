#!/usr/bin/env bash
# trust-s3-ca_test.sh — mac/scripts/trust-s3-ca.sh puts the S3 CA into titan-incus's system store.
#
# WHY this file exists: Incus uploads VM and volume backups to SeaweedFS over https and trusts only the system store, which
# Go reads once per process. So the CA must land there, and Incus must restart when it changed, and only then: a restart on
# every `up.sh` would cut the worker's Incus calls for nothing. The script runs against a fake `limactl` that keeps the VM's
# file in a folder.
#
# Run:  bash mac/tests/trust-s3-ca_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/trust-s3-ca.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/vm" "$WORK/home/.config/titan-local-cluster"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl shell titan-incus -- sudo CMD ARGS: records the command; `cat FILE` and `tee FILE` read and write $FAKE_VM/FILE.
printf '%s\n' "$*" >> "$FAKE_VM.log"
[ "$1 $2 $3 $4" = "shell titan-incus -- sudo" ] || { echo "unexpected: $*" >&2; exit 2; }
shift 4
case "$1" in
  cat) cat "$FAKE_VM/$(basename "$2")" 2>/dev/null || { echo "cat: $2: No such file or directory" >&2; exit 1; } ;;
  tee) cat > "$FAKE_VM/$(basename "$2")" ;;
  update-ca-certificates|systemctl) ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/limactl"
CA="$WORK/home/.config/titan-local-cluster/s3-ca.crt"

run() {
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_VM="$WORK/vm" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

echo "a VM without the CA"
printf -- '-----BEGIN CERTIFICATE-----\nfirst\n-----END CERTIFICATE-----\n' > "$CA"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
cmp -s "$CA" "$WORK/vm/titan-local-s3.crt" && ok "the CA is written to the VM, byte for byte" || bad "the VM's file differs"
grep -q 'tee /usr/local/share/ca-certificates/titan-local-s3.crt$' "$WORK/vm.log" \
  && ok "into /usr/local/share/ca-certificates/, where update-ca-certificates reads" || bad "wrong path: $(cat "$WORK/vm.log")"
grep -q 'sudo update-ca-certificates$' "$WORK/vm.log" && ok "the system store is rebuilt" || bad "no update-ca-certificates"
grep -q 'sudo systemctl restart incus$' "$WORK/vm.log" && ok "Incus restarts to read it" || bad "Incus not restarted"
[ "$(grep -n 'update-ca-certificates' "$WORK/vm.log" | cut -d: -f1)" -lt "$(grep -n 'systemctl restart incus' "$WORK/vm.log" | cut -d: -f1)" ] \
  && ok "the store is rebuilt before the restart" || bad "restart came first"

echo "a VM that has the same CA"
rm "$WORK/vm.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q -e 'tee' -e 'update-ca-certificates' -e 'systemctl' "$WORK/vm.log" \
  && bad "it wrote or restarted anyway: $(cat "$WORK/vm.log")" || ok "nothing is written and Incus keeps running"

echo "a new CA"
rm "$WORK/vm.log"
printf -- '-----BEGIN CERTIFICATE-----\nsecond\n-----END CERTIFICATE-----\n' > "$CA"
run
cmp -s "$CA" "$WORK/vm/titan-local-s3.crt" && grep -q 'systemctl restart incus$' "$WORK/vm.log" \
  && ok "the new CA replaces the old one and Incus restarts" || bad "the VM kept the old CA or Incus did not restart"

echo "no CA on the Mac"
rm "$CA" "$WORK/vm.log"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'bootstrap-secrets.sh' && ok "stops and names the script that makes it" || bad "rc=$RC $OUT"
[ ! -e "$WORK/vm.log" ] && ok "the VM is not touched" || bad "the VM was touched: $(cat "$WORK/vm.log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
