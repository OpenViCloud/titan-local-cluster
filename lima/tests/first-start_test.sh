#!/usr/bin/env bash
# first-start_test.sh — lima/scripts/up.sh outlasts Lima's own wait on a VM's first boot.
#
# WHY this file exists: on a new titan-incus, the provision script (apt installs Incus and OVN) measured 689 s on an Ubuntu
# host. Lima waits about 10 minutes for its final requirement ("boot scripts must have finished"), whatever --timeout says,
# then `limactl start` exits 1 with the VM Running and still provisioning. up.sh then waits for cloud-init in the VM itself
# (also when it is run again on a VM still provisioning) and reads the provision script's last word as before. It runs
# against a fake `limactl`.
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
# The VM is Stopped until `start` (Running from the start when named in $FAKE_RUNNING); `start` exits $FAKE_START_RC and
# leaves it Running unless $FAKE_START_STOPS is set. The provision grep prints "VM: done" unless the VM is named in $FAKE_UNPROVISIONED. Every call is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
vm=""
for a in "$@"; do case "$a" in titan-incus|titan-k3s) vm="$a" ;; esac; done
case "$1" in
  list)
    if [ "$2" = "--json" ]; then echo '{"name": "x", "config": {"portForwards": []}}'
    elif [ -e "$FAKE_DIR/$vm.running" ] || case " $FAKE_RUNNING " in *" $vm "*) true ;; *) false ;; esac; then echo Running
    else echo Stopped; fi ;;
  start) [ -n "$FAKE_START_STOPS" ] || touch "$FAKE_DIR/$vm.running"; exit "$FAKE_START_RC" ;;
  shell)
    case "$*" in
      *"cloud-init status --wait"*) exit 2 ;;
      *grep*) case " $FAKE_UNPROVISIONED " in *" $vm "*) ;; *) echo "$vm: done" ;; esac ;;
    esac ;;
esac
FAKE
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/docker"
# Stops up.sh in the secrets bootstrap, at its first kubectl; what it writes before that stays in the test's HOME.
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/kubectl"
chmod +x "$WORK/bin/limactl" "$WORK/bin/docker" "$WORK/bin/kubectl"

run_up() {  # run_up START_RC UNPROVISIONED_VMS [RUNNING_VMS] [START_STOPS]
  : > "$WORK/log"; rm -f "$WORK"/*.running
  OUT=$(FAKE_LOG="$WORK/log" FAKE_DIR="$WORK" FAKE_START_RC="$1" FAKE_UNPROVISIONED="$2" FAKE_RUNNING="${3:-}" FAKE_START_STOPS="${4:-}" \
    HOME="$WORK/home" PATH="$WORK/bin:$PATH" bash "$UP" 2>&1); RC=$?
}
provisioned() { grep -c "^shell $1 -- sudo grep" "$WORK/log"; }

run_up 1 ""
grep -q '^start titan-incus' "$WORK/log" && grep -q '^start titan-k3s' "$WORK/log" && ok "stopped VMs are started" || bad "no start: $(cat "$WORK/log")"
grep -q 'cloud-init status --wait' "$WORK/log" && ok "start exits 1, VM Running: up.sh waits for cloud-init" || bad "no wait: $(cat "$WORK/log")"
[ "$(provisioned titan-incus)" -ge 1 ] && [ "$(provisioned titan-k3s)" -ge 1 ] && ok "both VMs reach the provision check" || bad "stopped early: $OUT"

run_up 0 "" "titan-incus titan-k3s"
grep -q '^start ' "$WORK/log" && bad "a running VM was started" || ok "run again on running VMs: none is started"
[ "$(grep -c 'cloud-init status --wait' "$WORK/log")" -eq 2 ] && ok "run again: up.sh waits for each VM's cloud-init before the check" || bad "no wait on a running VM: $(cat "$WORK/log")"
awk '/cloud-init status --wait/{w=1} /sudo grep/{exit !w}' "$WORK/log" && ok "the wait comes before the provision check" || bad "check before wait: $(cat "$WORK/log")"

run_up 1 titan-incus
[ "$RC" -ne 0 ] && ok "provision not finished after the wait: up.sh fails" || bad "up.sh went on with titan-incus unprovisioned"
printf '%s' "$OUT" | grep -q 'ERROR: provisioning of titan-incus did not finish' && ok "the message names the VM" || bad "message: $OUT"
[ "$(provisioned titan-k3s)" -eq 0 ] && ok "the next VM is not touched" || bad "titan-k3s went on: $(cat "$WORK/log")"

run_up 1 "" "" yes
[ "$RC" -ne 0 ] && ok "start exits 1, VM not Running: up.sh fails" || bad "up.sh went on after a start that left the VM stopped"
grep -q 'cloud-init status --wait' "$WORK/log" && bad "waited on a stopped VM: $(cat "$WORK/log")" || ok "no wait on a VM that did not start"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
