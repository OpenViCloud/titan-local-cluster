#!/usr/bin/env bash
# first-start_test.sh — lima/scripts/up.sh outlasts Lima's own wait on a VM's first boot.
#
# WHY this file exists: on a new titan-incus, the provision script (apt installs Incus and OVN) measured 689 s on an Ubuntu
# host. Lima waits about 10 minutes for its final requirement ("boot scripts must have finished"), whatever --timeout says,
# then `limactl start` exits 1 with the VM Running and still provisioning. up.sh then waits for cloud-init in the VM itself
# and reads the provision script's last word as before. It runs against a fake `limactl`.
#
# Run:  bash lima/tests/first-start_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
UP="$HERE/../scripts/up.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# The VM is Stopped until `start`, which exits $FAKE_START_RC and leaves it Running. The provision grep prints "VM: done"
# unless the VM is named in $FAKE_UNPROVISIONED. Every call is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
vm=""
for a in "$@"; do case "$a" in titan-incus|titan-k3s) vm="$a" ;; esac; done
case "$1" in
  list)
    if [ "$2" = "--json" ]; then echo '{"name": "x", "config": {"portForwards": []}}'
    elif [ -e "$FAKE_DIR/$vm.running" ]; then echo Running
    else echo Stopped; fi ;;
  start) touch "$FAKE_DIR/$vm.running"; exit "$FAKE_START_RC" ;;
  shell)
    case "$*" in
      *"cloud-init status --wait"*) exit 2 ;;
      *grep*) case " $FAKE_UNPROVISIONED " in *" $vm "*) ;; *) echo "$vm: done" ;; esac ;;
    esac ;;
esac
FAKE
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/docker"
# Stops up.sh right after the VM loop: the secrets bootstrap is not this test's business.
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/kubectl"
chmod +x "$WORK/bin/limactl" "$WORK/bin/docker" "$WORK/bin/kubectl"

run_up() {  # run_up START_RC UNPROVISIONED_VMS
  : > "$WORK/log"; rm -f "$WORK"/*.running
  OUT=$(FAKE_LOG="$WORK/log" FAKE_DIR="$WORK" FAKE_START_RC="$1" FAKE_UNPROVISIONED="$2" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    timeout 60 bash "$UP" 2>&1); RC=$?
}
provisioned() { grep -c "^shell $1 -- sudo grep" "$WORK/log"; }

run_up 1 ""
grep -q 'cloud-init status --wait' "$WORK/log" && ok "start exits 1, VM Running: up.sh waits for cloud-init" || bad "no wait: $(cat "$WORK/log")"
[ "$(provisioned titan-incus)" -ge 1 ] && [ "$(provisioned titan-k3s)" -ge 1 ] && ok "both VMs reach the provision check" || bad "stopped early: $OUT"

run_up 0 ""
grep -q 'cloud-init status --wait' "$WORK/log" && bad "a start that succeeded waited anyway" || ok "start exits 0: no extra wait"

run_up 1 titan-incus
[ "$RC" -ne 0 ] && ok "provision not finished after the wait: up.sh fails" || bad "up.sh went on with titan-incus unprovisioned"
printf '%s' "$OUT" | grep -q 'titan-incus' && ok "the message names the VM" || bad "message: $OUT"
[ "$(provisioned titan-k3s)" -eq 0 ] && ok "the next VM is not touched" || bad "titan-k3s went on: $(cat "$WORK/log")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
