#!/usr/bin/env bash
# ovnbr-ipv6_test.sh — the host side of the uplink ovnup that provision/incus.sh installs on titan-incus.
#
# WHY this file exists: Incus brings ovnbr up with IPv6 off each time it starts, which drops the gateway ::1/64 and the
# 255 routes to the routers of the tenant networks. Provision set them only at boot, so every restart of Incus (the S3
# and extra CA scripts, the thin pool repair, a package upgrade) left public IPv6 dead until someone ran provision again
# (docs/network.md#ipv6). The checks read the section "IPv6 on ovnbr" of provision/incus.sh: the script it installs, run
# against a fake `ip` and `sysctl`; the systemd unit that runs that script after every start of incus.service; and the
# order in which the section installs, enables and starts them.
#
# Run:  bash lima/tests/ovnbr-ipv6_test.sh     (from the repo root; macOS bash 3.2 and python3)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROVISION="$HERE/../provision/incus.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

SECTION="$WORK/section.sh"
awk '/^# ── IPv6 on ovnbr/ { inside = 1 } /^# ── / && !/IPv6 on ovnbr/ { inside = 0 } inside' "$PROVISION" > "$SECTION"
SCRIPT="$WORK/titan-ovnbr-ipv6"
awk '/^cat > \/usr\/local\/sbin\/titan-ovnbr-ipv6 <<.OVNBR.$/ { inside = 1; next } /^OVNBR$/ { inside = 0 } inside' \
  "$SECTION" > "$SCRIPT"
chmod 755 "$SCRIPT"
UNIT="$WORK/titan-ovnbr-ipv6.service"
awk '/^cat > \/etc\/systemd\/system\/titan-ovnbr-ipv6\.service <<.UNIT.$/ { inside = 1; next } /^UNIT$/ { inside = 0 } inside' \
  "$SECTION" > "$UNIT"
if [ ! -s "$SECTION" ] || [ ! -s "$SCRIPT" ] || [ ! -s "$UNIT" ] || ! bash -n "$SECTION" || ! bash -n "$SCRIPT"; then
  bad "no section '# ── IPv6 on ovnbr' with the script titan-ovnbr-ipv6 and its unit could be cut out of provision/incus.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

echo "== the unit =="
unit=$(python3 - "$UNIT" <<'PY'
import sys
sections, current = {}, None
for line in open(sys.argv[1]).read().splitlines():
    line = line.strip()
    if line.startswith("[") and line.endswith("]"):
        current = sections.setdefault(line[1:-1], {})
    elif "=" in line and current is not None:
        key, _, value = line.partition("=")
        current.setdefault(key, []).append(value)
want = {
    # Ordered after Incus, so it runs once Incus has brought ovnbr up (IPv6 off).
    ("Unit", "After"): "incus.service",
    # A stop or restart job of incus.service stops or restarts this unit too, and incusd exiting by itself stops it:
    # without them the unit stays active from the last start and a start of Incus would not run it again.
    ("Unit", "PartOf"): "incus.service",
    ("Unit", "BindsTo"): "incus.service",
    # Every start of incus.service starts this unit: a restart, socket activation, the boot.
    ("Install", "WantedBy"): "incus.service",
    ("Service", "Type"): "oneshot",
    ("Service", "RemainAfterExit"): "yes",
    ("Service", "ExecStart"): "/usr/local/sbin/titan-ovnbr-ipv6",
}
problems = []
for (section, key), value in want.items():
    got = sections.get(section, {}).get(key, [])
    if got != [value]:
        problems.append("[%s] %s=%s, got %r" % (section, key, value, got))
print("; ".join(problems))
PY
) || unit="python3 exited $?: $unit"
[ -z "$unit" ] && ok "runs the script once after every start of incus.service, and goes inactive whenever Incus does" \
  || bad "unit: $unit"

echo "== the section installs, enables and starts it =="
order=$(python3 - "$SECTION" "$PROVISION" <<'PY'
import re, sys
section = open(sys.argv[1]).read()
lines = [l.strip() for l in section.splitlines() if l.strip() and not l.strip().startswith("#")]
def at(pattern):
    return next((i for i, l in enumerate(lines) if re.search(pattern, l)), -1)
steps = [
    ("the script written", at(r"^cat > /usr/local/sbin/titan-ovnbr-ipv6 <<'OVNBR'$")),
    ("the script made executable", at(r"^chmod 755 /usr/local/sbin/titan-ovnbr-ipv6$")),
    ("the unit written", at(r"^cat > /etc/systemd/system/titan-ovnbr-ipv6\.service <<'UNIT'$")),
    ("systemd reloaded", at(r"^systemctl daemon-reload$")),
    ("the unit enabled", at(r"^systemctl enable titan-ovnbr-ipv6\.service$")),
    ("the unit (re)started", at(r"^systemctl restart titan-ovnbr-ipv6\.service$")),
]
problems = ["missing: " + name for name, i in steps if i == -1]
if not problems and [i for _, i in steps] != sorted(i for _, i in steps):
    problems.append("order is not: " + ", ".join(name for name, _ in steps))
provision = open(sys.argv[2]).read()
if provision.find("# ── IPv6 on ovnbr") < provision.find("# ── OVN uplink for public IPv6"):
    problems.append("the section comes before the uplink section, which creates ovnbr")
# The prefix the script routes must be the one the uplink is created with.
uplink = re.search(r"^IPV6_BLOCK_PREFIX=(\S+)$", provision, re.M)
script = re.findall(r"^IPV6_BLOCK_PREFIX=(\S+)$", section, re.M)
if not uplink or script != [uplink.group(1)]:
    problems.append("the script's IPV6_BLOCK_PREFIX %r is not the uplink's %r" % (script, uplink and uplink.group(1)))
print("; ".join(problems))
PY
) || order="python3 exited $?: $order"
[ -z "$order" ] && ok "after the uplink: script, unit, daemon-reload, enable, restart; the script's prefix is the uplink's" \
  || bad "section: $order"

echo "== the script run against a fake ip and sysctl =="
mkdir -p "$WORK/bin"
for tool in ip sysctl; do
  printf '#!/bin/bash\necho "%s $*" >> "$FAKE_STATE/calls"\n[ "${FAKE_FAILS:-}" != "%s" ]\n' "$tool" "$tool" > "$WORK/bin/$tool"
done
chmod 755 "$WORK/bin/"*

# run_script <case>: runs the installed script as systemd does; prints its exit code. <case>/net is the net root, with
# ovnbr in it unless the case removes it.
run_script() {
  local state="$WORK/$1"
  FAKE_STATE="$state" OVNBR_NET_ROOT="$state/net" PATH="$WORK/bin:$PATH" "$SCRIPT" > "$state/out" 2>&1
  echo $?
}
calls_of() { grep -c -E "$2" "$WORK/$1/calls" 2>/dev/null || true; }
new_case() { mkdir -p "$WORK/$1/net/ovnbr"; : > "$WORK/$1/calls"; }

new_case up
rc=$(run_script up)
seq_ok=$(python3 - "$WORK/up/calls" <<'PY'
import ipaddress, re, sys
calls = open(sys.argv[1]).read().splitlines()
problems = []
if not calls or calls[0] != "sysctl -qw net.ipv6.conf.ovnbr.disable_ipv6=0":
    problems.append("first call is not IPv6 on for ovnbr: %r" % calls[:1])
if len(calls) < 2 or calls[1] != "ip -6 addr replace 2001:db8:0:d400::1/64 dev ovnbr":
    problems.append("second call is not the gateway ::1/64 on ovnbr: %r" % calls[1:2])
routes = calls[2:]
want = ["ip -6 route replace 2001:db8:0:d4%02x::/64 via 2001:db8:0:d400::1%02x dev ovnbr" % (n, n) for n in range(1, 256)]
if routes != want:
    problems.append("routes: %d calls, first differing %r" % (len(routes), next((r for r, w in zip(routes, want) if r != w), routes[255:256])))
print("; ".join(problems))
PY
)
if [ "$rc" = 0 ] && [ -z "$seq_ok" ]; then
  ok "IPv6 on for ovnbr, then the gateway ::1/64, then /64 n via router ::1nn for n = 1..255"
else
  bad "script: exit=$rc $seq_ok — $(tail -3 "$WORK/up/out")"
fi

new_case again
run_script again >/dev/null
rc=$(run_script again)
[ "$rc" = 0 ] && [ "$(calls_of again '^ip -6 addr replace ')" = 2 ] && [ "$(calls_of again '^ip -6 route replace ')" = 510 ] \
  && ok "run twice: exit 0 both times (replace, not add)" || bad "second run: exit=$rc — $(tail -3 "$WORK/again/out")"

new_case no-bridge
rmdir "$WORK/no-bridge/net/ovnbr"
rc=$(run_script no-bridge)
[ "$rc" = 0 ] && [ ! -s "$WORK/no-bridge/calls" ] && grep -q 'no ovnbr' "$WORK/no-bridge/out" \
  && ok "no ovnbr yet: exit 0, nothing set, says so (the unit does not show failed for it)" \
  || bad "no ovnbr: exit=$rc calls=$(wc -l < "$WORK/no-bridge/calls") — $(cat "$WORK/no-bridge/out")"

new_case ip-fails
rc=$(FAKE_FAILS=ip run_script ip-fails)
[ "$rc" != 0 ] && [ "$(calls_of ip-fails '^ip -6 route replace ')" = 0 ] \
  && ok "a failed ip stops the script with an error, so the unit shows failed" || bad "ip failure: exit=$rc"

new_case sysctl-fails
rc=$(FAKE_FAILS=sysctl run_script sysctl-fails)
[ "$rc" != 0 ] && [ "$(calls_of sysctl-fails '^ip ')" = 0 ] \
  && ok "a failed sysctl stops the script before any address goes on" || bad "sysctl failure: exit=$rc"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
