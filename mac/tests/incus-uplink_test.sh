#!/usr/bin/env bash
# incus-uplink_test.sh — the OVN uplink that provision/incus.sh builds on titan-incus for public IPv6.
#
# WHY this file exists: a network asking for public IPv6 goes on the uplink ovnup, and Incus refuses its IPv4 CIDR when
# the uplink does not route it. Nothing on the Mac runs this script before a boot of titan-incus, and a wrong uplink only
# shows when a network create gives up (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/network.md#uplink). The checks read the
# section cut out of provision/incus.sh: its shape (singapore01's, written out in the checks), then the section itself
# run against a fake `incus`, `ip` and `sysctl` for a fresh machine, an old bridge ovnup with and without networks on
# it, a second run, and a failed read.
#
# Run:  bash mac/tests/incus-uplink_test.sh     (from the repo root; macOS bash 3.2 and python3)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROVISION="$HERE/../provision/incus.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

SECTION="$WORK/uplink.sh"
awk '/^# ── OVN uplink for public IPv6/ { inside = 1 } /^# ── / && !/OVN uplink for public IPv6/ { inside = 0 } inside' \
  "$PROVISION" > "$SECTION"
if [ ! -s "$SECTION" ] || ! bash -n "$SECTION"; then
  bad "no section '# ── OVN uplink for public IPv6' could be cut out of provision/incus.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

echo "== shape of the uplink =="
shape=$(python3 - "$SECTION" <<'PY'
import ipaddress, re, sys
text = re.sub(r"\\\n\s*", " ", open(sys.argv[1]).read())
prefix = re.search(r"^IPV6_BLOCK_PREFIX=(\S+)$", text, re.M)
if not prefix:
    print("no IPV6_BLOCK_PREFIX=…"); sys.exit()
text = text.replace("${IPV6_BLOCK_PREFIX}", prefix.group(1))
block = ipaddress.ip_network(prefix.group(1) + "00::/56")
first = next(block.subnets(new_prefix=64))
problems = []
lines = [l.strip() for l in text.splitlines() if not l.strip().startswith("#")]
parent = [l for l in lines if l.startswith("incus network create ovnbr ")]
if parent != ["incus network create ovnbr --type=bridge ipv4.address=none ipv6.address=none"]:
    problems.append("parent bridge: want one `incus network create ovnbr --type=bridge ipv4.address=none ipv6.address=none`, got %r" % parent)
uplink = [l for l in lines if l.startswith("incus network create ovnup ")]
if len(uplink) != 1:
    problems.append("want one `incus network create ovnup` line, got %d" % len(uplink))
else:
    words = uplink[0].split()
    if "--type=physical" not in words or "parent=ovnbr" not in words:
        problems.append("ovnup is not --type=physical parent=ovnbr")
    cfg = dict(w.split("=", 1) for w in words if "=" in w and not w.startswith("--"))
    gateway = ipaddress.ip_interface(cfg.get("ipv6.gateway", "::/0"))
    if gateway.ip != first[1] or gateway.network.prefixlen != 64:
        problems.append("ipv6.gateway %s is not ::1 of the first /64 %s" % (gateway, first))
    low, _, high = cfg.get("ipv6.ovn.ranges", "-").partition("-")
    routers = [ipaddress.ip_address(a) for a in (low, high) if a]
    if len(routers) != 2 or any(a not in first for a in routers) or int(routers[1]) - int(routers[0]) + 1 < 255:
        problems.append("ipv6.ovn.ranges %s is not 255+ router addresses inside %s" % (cfg.get("ipv6.ovn.ranges"), first))
    routes = [ipaddress.ip_network(r) for r in cfg.get("ipv6.routes", "").split(",") if r]
    if any(not r.subnet_of(block) or r.overlaps(first) for r in routes) or sum(r.num_addresses for r in routes) != block.num_addresses - first.num_addresses:
        problems.append("ipv6.routes do not cover exactly the /56 minus its first /64")
    private = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    if sorted(ipaddress.ip_network(r) for r in cfg.get("ipv4.routes", "").split(",") if r) != private:
        problems.append("ipv4.routes is not the three private ranges: Incus refuses a network whose IPv4 CIDR the uplink does not route")
    if cfg.get("ipv4.routes.anycast") != "true":
        problems.append("ipv4.routes.anycast is not true: two tenants could not pick the same CIDR")
    if cfg.get("ovn.ingress_mode") != "routed":
        problems.append("ovn.ingress_mode is not routed: the host routes each /64 to its router")
    for key in ("ipv4.gateway", "ipv4.ovn.ranges", "ipv4.nat", "ipv6.nat", "ipv4.address", "ipv6.address"):
        if key in cfg:
            problems.append("%s set on ovnup: IPv4 must not leave, nothing is NATed, the host holds the gateway" % key)
if any(re.match(r"incus network (set|unset) ovnup\b", l) for l in lines):
    problems.append("ovnup is changed after it is created: its keys belong to the create line")
print("; ".join(problems))
PY
) || shape="python3 exited $?: $shape"
if [ -z "$shape" ]; then
  ok "ovnup: physical on ovnbr, gateway ::1 and routers in the first /64, routes = the other /64s, private IPv4 anycast, no IPv4 gateway, no NAT"
else
  bad "ovnup shape: $shape"
fi

host=$(python3 - "$SECTION" <<'PY'
import re, sys
lines = [l.strip() for l in open(sys.argv[1]).read().splitlines() if l.strip() and not l.strip().startswith("#")]
def at(pattern):
    return next((i for i, l in enumerate(lines) if re.search(pattern, l)), -1)
sysctl = at(r"^sysctl -qw net\.ipv6\.conf\.ovnbr\.disable_ipv6=0$")
gateway = at(r"^ip -6 addr replace \$\{IPV6_BLOCK_PREFIX\}00::1/64 dev ovnbr$")
route = at(r'^ip -6 route replace "\$\{IPV6_BLOCK_PREFIX\}\$\{hex\}::/64" via "\$\{IPV6_BLOCK_PREFIX\}00::1\$\{hex\}" dev ovnbr$')
uplink = at(r"^incus network create ovnup ")
problems = []
if -1 in (sysctl, gateway, route):
    problems.append("missing: IPv6 on ovnbr (%d), the gateway on ovnbr (%d), the /64 routes via ovnbr (%d)" % (sysctl, gateway, route))
elif not sysctl < gateway < route:
    problems.append("IPv6 must be on before the gateway, the gateway before the routes")
if any(re.search(r"\bdev ovnup\b", l) for l in lines):
    problems.append("a host address or route still on ovnup, which is no longer a host interface")
print("; ".join(problems))
PY
) || host="python3 exited $?: $host"
if [ -z "$host" ]; then
  ok "host: IPv6 on ovnbr, then the gateway ::1/64 on it, then the 255 routes via ovnbr"
else
  bad "host side of ovnbr: $host"
fi

echo "== the section run against a fake incus =="
# The fake keeps one file per network: <state>/<name> holds its type, <state>/<name>.users its used_by count.
# Every call is appended to <state>/calls. FAKE_QUERY_FAILS=yes makes `incus query` fail.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/incus" <<'FAKE'
#!/bin/bash
state="$FAKE_STATE"
echo "incus $*" >> "$state/calls"
case "$1 $2" in
  "network show")
    [ -f "$state/$3" ]; exit $? ;;
  "network create")
    type=bridge
    for w in "$@"; do case "$w" in --type=*) type="${w#--type=}" ;; esac; done
    echo "$type" > "$state/$3"; echo 0 > "$state/$3.users"; exit 0 ;;
  "network delete")
    rm -f "$state/$3" "$state/$3.users"; exit 0 ;;
esac
if [ "$1" = "query" ]; then
  if [ "${FAKE_QUERY_FAILS:-}" = "yes" ]; then echo "Error: cannot reach the daemon" >&2; exit 1; fi
  name="${2##*/}"
  [ -f "$state/$name" ] || { echo "Error: Network not found" >&2; exit 1; }
  users=$(cat "$state/$name.users")
  python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "type": sys.argv[2], "used_by": ["/1.0/networks/net-%d?project=t-x" % i for i in range(int(sys.argv[3]))]}))' "$name" "$(cat "$state/$name")" "$users"
  exit 0
fi
echo "fake incus: unexpected arguments: $*" >&2
exit 3
FAKE
for tool in ip sysctl; do
  printf '#!/bin/bash\necho "%s $*" >> "$FAKE_STATE/calls"\n' "$tool" > "$WORK/bin/$tool"
done
chmod 755 "$WORK/bin/"*

# run_section <case>: runs the section with errexit like provision does; prints its exit code
run_section() {
  local state="$WORK/$1"
  FAKE_STATE="$state" PATH="$WORK/bin:$PATH" bash -c "set -euo pipefail; . '$SECTION'" > "$state/out" 2>&1
  echo $?
}
calls_of() { grep -c -E "$2" "$WORK/$1/calls" 2>/dev/null || true; }

mkdir -p "$WORK/fresh"; : > "$WORK/fresh/calls"
rc=$(run_section fresh)
if [ "$rc" = 0 ] && [ "$(cat "$WORK/fresh/ovnbr" 2>/dev/null)" = bridge ] && [ "$(cat "$WORK/fresh/ovnup" 2>/dev/null)" = physical ] \
   && [ "$(calls_of fresh '^incus network delete')" = 0 ] && [ "$(calls_of fresh '^ip -6 route replace .* dev ovnbr$')" = 255 ]; then
  ok "fresh machine: ovnbr then a physical ovnup, nothing deleted, 255 routes via ovnbr"
else
  bad "fresh machine: exit=$rc ovnbr=$(cat "$WORK/fresh/ovnbr" 2>/dev/null) ovnup=$(cat "$WORK/fresh/ovnup" 2>/dev/null) routes=$(calls_of fresh '^ip -6 route replace .* dev ovnbr$') — $(tail -3 "$WORK/fresh/out")"
fi

mkdir -p "$WORK/old-unused"; : > "$WORK/old-unused/calls"
echo bridge > "$WORK/old-unused/ovnup"; echo 0 > "$WORK/old-unused/ovnup.users"
rc=$(run_section old-unused)
if [ "$rc" = 0 ] && [ "$(cat "$WORK/old-unused/ovnup" 2>/dev/null)" = physical ] && [ "$(calls_of old-unused '^incus network delete ovnup$')" = 1 ]; then
  ok "old bridge ovnup with nothing on it: deleted once, created again as physical"
else
  bad "old bridge ovnup unused: exit=$rc ovnup=$(cat "$WORK/old-unused/ovnup" 2>/dev/null) deletes=$(calls_of old-unused '^incus network delete ovnup$') — $(tail -3 "$WORK/old-unused/out")"
fi

mkdir -p "$WORK/old-used"; : > "$WORK/old-used/calls"
echo bridge > "$WORK/old-used/ovnup"; echo 2 > "$WORK/old-used/ovnup.users"
rc=$(run_section old-used)
if [ "$rc" != 0 ] && [ "$(cat "$WORK/old-used/ovnup")" = bridge ] && [ "$(calls_of old-used '^incus network (delete|create) ovnup')" = 0 ] \
   && grep -q '^ERROR: ' "$WORK/old-used/out"; then
  ok "old bridge ovnup with networks on it: stops with ERROR, ovnup untouched"
else
  bad "old bridge ovnup used: exit=$rc ovnup=$(cat "$WORK/old-used/ovnup") ovnup calls=$(calls_of old-used '^incus network (delete|create) ovnup') — $(tail -3 "$WORK/old-used/out")"
fi

mkdir -p "$WORK/again"; : > "$WORK/again/calls"
echo bridge > "$WORK/again/ovnbr"; echo 0 > "$WORK/again/ovnbr.users"
echo physical > "$WORK/again/ovnup"; echo 3 > "$WORK/again/ovnup.users"
rc=$(run_section again)
if [ "$rc" = 0 ] && [ "$(calls_of again '^incus network (create|delete)')" = 0 ] && [ "$(calls_of again '^ip -6 addr replace .* dev ovnbr$')" = 1 ]; then
  ok "second run on a physical ovnup in use: no network created or deleted, the host gateway set again"
else
  bad "second run: exit=$rc network calls=$(calls_of again '^incus network (create|delete)') — $(tail -3 "$WORK/again/out")"
fi

mkdir -p "$WORK/read-fails"; : > "$WORK/read-fails/calls"
echo bridge > "$WORK/read-fails/ovnup"; echo 0 > "$WORK/read-fails/ovnup.users"
rc=$(FAKE_QUERY_FAILS=yes run_section read-fails)
if [ "$rc" != 0 ] && [ "$(cat "$WORK/read-fails/ovnup")" = bridge ] && [ "$(calls_of read-fails '^incus network delete')" = 0 ]; then
  ok "a failed read of ovnup stops the section before anything is deleted"
else
  bad "failed read: exit=$rc ovnup=$(cat "$WORK/read-fails/ovnup") deletes=$(calls_of read-fails '^incus network delete') — $(tail -3 "$WORK/read-fails/out")"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
