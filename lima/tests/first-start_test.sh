#!/usr/bin/env bash
# first-start_test.sh — lima/scripts/up.sh outlasts Lima's own wait on a VM's first boot.
#
# WHY this file exists: on a new titan-incus, the provision script (apt installs Incus and OVN) measured 689 s on an Ubuntu
# host. Lima waits about 10 minutes for its final requirement ("boot scripts must have finished"), whatever --timeout says,
# then `limactl start` exits 1 with the VM Running and still provisioning. up.sh then waits for cloud-init in the VM itself
# (also when it is run again on a VM still provisioning) and reads the provision script's last word as before. It also
# brings a VM made at an older size to the cpus and memory of its Lima file (docs/topology.md#ram-budget), and a VM made
# before a provision script changed to the file's scripts (docs/topology.md#provision-sync). It runs against a fake
# `limactl`.
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
# The Lima files up.sh reads on this host, so the fake reports their sizes.
source "$HERE/../scripts/host-os.sh"
VMS_DIR=$(vm_dir "$(uname -s)")
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# The VM is Stopped until `start` (Running from the start when named in $FAKE_RUNNING); `start` exits $FAKE_START_RC and
# leaves it Running unless $FAKE_START_STOPS is set; `stop` stops it. The provision grep prints "VM: done" unless the VM is
# named in $FAKE_UNPROVISIONED. `list --json` reports the cpus, memory and provision scripts of the VM's file in $FAKE_VMS,
# or 1 CPU and 1 GiB for a VM named in $FAKE_SMALL, an old script for a VM named in $FAKE_OLD, until `edit` ran on it;
# `edit` keeps its arguments one per line in $FAKE_DIR/<vm>.edit. Every call is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
vm=""
for a in "$@"; do case "$a" in titan-incus|titan-k3s) vm="$a" ;; esac; done
case "$1" in
  list)
    if [ "$2" = "--json" ]; then
      small=""; old=""
      if [ ! -e "$FAKE_DIR/$vm.edited" ]; then
        case " $FAKE_SMALL " in *" $vm "*) small=yes ;; esac
        case " $FAKE_OLD " in *" $vm "*) old=yes ;; esac
      fi
      python3 -c 'import json, os, re, sys
text = open(sys.argv[1]).read()
cpus, gib = int(re.search(r"^cpus: (\d+)", text, re.M).group(1)), int(re.search(r"^memory: (\d+)GiB", text, re.M).group(1))
if sys.argv[3]:
    cpus, gib = 1, 1
provision = [{"mode": "system", "script": "old\n" if sys.argv[4] else open(os.path.join(os.path.dirname(sys.argv[1]), url)).read()}
             for url in re.findall(r"^    url: (\S+)$", text, re.M)]
print(json.dumps({"name": sys.argv[2], "cpus": cpus, "memory": gib * 1024 ** 3,
                  "config": {"portForwards": [], "provision": provision}}))' "$FAKE_VMS/$vm.yaml" "$vm" "$small" "$old"
    elif [ -e "$FAKE_DIR/$vm.running" ] || case " $FAKE_RUNNING " in *" $vm "*) true ;; *) false ;; esac; then echo Running
    else echo Stopped; fi ;;
  start) [ -n "$FAKE_START_STOPS" ] || touch "$FAKE_DIR/$vm.running"; exit "$FAKE_START_RC" ;;
  stop) rm -f "$FAKE_DIR/$vm.running" ;;
  edit) touch "$FAKE_DIR/$vm.edited"; printf '%s\n' "$@" > "$FAKE_DIR/$vm.edit" ;;
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

run_up() {  # run_up START_RC UNPROVISIONED_VMS [RUNNING_VMS] [START_STOPS] [SMALL_VMS] [OLD_PROVISION_VMS]
  : > "$WORK/log"; rm -f "$WORK"/*.running "$WORK"/*.edited "$WORK"/*.edit
  OUT=$(FAKE_LOG="$WORK/log" FAKE_DIR="$WORK" FAKE_VMS="$VMS_DIR" FAKE_START_RC="$1" FAKE_UNPROVISIONED="$2" FAKE_RUNNING="${3:-}" \
    FAKE_START_STOPS="${4:-}" FAKE_SMALL="${5:-}" FAKE_OLD="${6:-}" \
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

# A VM made before its file grew: up.sh stops it, edits it to the file's size and starts it; the other VM is left alone.
k3s_size=$(python3 -c 'import re, sys
t = open(sys.argv[1]).read()
print("--cpus", re.search(r"^cpus: (\d+)", t, re.M).group(1), "--memory", re.search(r"^memory: (\d+)GiB", t, re.M).group(1))' "$VMS_DIR/titan-k3s.yaml")
run_up 0 "" "titan-incus titan-k3s" "" titan-k3s
awk '$1 == "stop" && $2 == "titan-k3s" {s=NR} $1 == "edit" && /titan-k3s/ {e=NR} $1 == "start" && $2 == "titan-k3s" {r=NR} END {exit !(s && e > s && r > e)}' "$WORK/log" \
  && ok "a running VM at an older size is stopped, edited, then started" || bad "resize order: $(cat "$WORK/log")"
grep -qx "edit --tty=false titan-k3s $k3s_size" "$WORK/log" && ok "the edit carries the file's cpus and memory" || bad "edit flags: $(grep '^edit' "$WORK/log")"
grep -q -e '^stop titan-incus' -e '^edit .*titan-incus' -e '^start titan-incus' "$WORK/log" && bad "the VM at its file's size was touched: $(cat "$WORK/log")" || ok "a VM at its file's size is not stopped"
printf '%s' "$OUT" | grep -q "titan-k3s: resizing to $k3s_size" && ok "up.sh says it resizes" || bad "message: $OUT"

run_up 0 "" "" "" titan-k3s
grep -q '^stop titan-k3s' "$WORK/log" && bad "a stopped VM was stopped again: $(cat "$WORK/log")" || ok "a stopped VM at an older size is edited without a stop"
grep -qx "edit --tty=false titan-k3s $k3s_size" "$WORK/log" && ok "the stopped VM is edited" || bad "no edit: $(cat "$WORK/log")"

# A VM made before k3s.sh changed: up.sh stops it, sets the file's script in its provision, and starts it; the size stays.
k3s_set=$(python3 -c 'import base64, sys; print(".provision[0].script = (\"%s\" | @base64d)" % base64.b64encode(open(sys.argv[1], "rb").read()).decode())' \
  "$VMS_DIR/provision/k3s.sh")
run_up 0 "" "titan-incus titan-k3s" "" "" titan-k3s
awk '$1 == "stop" && $2 == "titan-k3s" {s=NR} $1 == "edit" && /titan-k3s/ {e=NR} $1 == "start" && $2 == "titan-k3s" {r=NR} END {exit !(s && e > s && r > e)}' "$WORK/log" \
  && ok "a running VM with an old provision script is stopped, edited, then started" || bad "reprovision order: $(cat "$WORK/log")"
[ "$(sed -n '3p;4p' "$WORK/titan-k3s.edit" 2>/dev/null)" = "titan-k3s
--set" ] && [ "$(sed -n '5p' "$WORK/titan-k3s.edit")" = "$k3s_set" ] && [ "$(wc -l < "$WORK/titan-k3s.edit")" -eq 5 ] \
  && ok "the edit sets the file's k3s.sh as one argument and no size" || bad "edit arguments: $(head -c 300 "$WORK/titan-k3s.edit" 2>/dev/null)"
grep -q -e '^stop titan-incus' -e '^edit .*titan-incus' "$WORK/log" && bad "the VM with the file's scripts was touched: $(cat "$WORK/log")" || ok "a VM with the file's scripts is not stopped"
printf '%s' "$OUT" | grep -q "titan-k3s: copying in 1 provision script(s)" && ok "up.sh says it copies the script in" || bad "message: $OUT"

# Both changed: one stop, one edit with the size and the script.
run_up 0 "" "titan-incus titan-k3s" "" titan-k3s titan-k3s
[ "$(grep -c '^stop titan-k3s' "$WORK/log")" -eq 1 ] && [ "$(grep -c '^edit ' "$WORK/log")" -eq 1 ] && ok "size and script change in one stop and one edit" || bad "stops or edits: $(cat "$WORK/log")"
[ "$(sed -n '3,8p' "$WORK/titan-k3s.edit" | tr '\n' ' ')" = "titan-k3s $k3s_size --set " ] && [ "$(sed -n '9p' "$WORK/titan-k3s.edit")" = "$k3s_set" ] \
  && ok "that edit carries the size flags and the script" || bad "edit arguments: $(head -c 300 "$WORK/titan-k3s.edit" 2>/dev/null)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
