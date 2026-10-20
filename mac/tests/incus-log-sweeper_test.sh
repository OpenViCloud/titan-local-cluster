#!/usr/bin/env bash
# incus-log-sweeper_test.sh — the guest-log sweeper that provision/incus.sh installs on titan-incus.
#
# WHY this file exists: the sweeper deletes directories under /var/log/incus as root on a timer. Wrong once, it deletes
# the log of a running VM, or nothing at all, and nobody looks at that host. The script under test is cut out of
# provision/incus.sh, so what passes here is what gets installed. A fake `incus` stands in for the instance list.
#
# Run:  bash mac/tests/incus-log-sweeper_test.sh     (from the repo root; macOS bash 3.2 is fine)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PROVISION="$HERE/../provision/incus.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

SWEEPER="$WORK/incus-log-sweeper"
awk '/^cat > \/usr\/local\/sbin\/incus-log-sweeper <<.SWEEPER.$/ { inside = 1; next } /^SWEEPER$/ { inside = 0 } inside' \
  "$PROVISION" > "$SWEEPER"
chmod 755 "$SWEEPER"
if [ ! -s "$SWEEPER" ] || ! bash -n "$SWEEPER"; then
  bad "the sweeper could not be cut out of provision/incus.sh"
  echo "PASS=$PASS FAIL=$((FAIL))"
  exit 1
fi

# The fake prints FAKE_INSTANCES as `incus list --all-projects --format csv --columns en` would, or fails.
cat > "$WORK/incus" <<'FAKE'
#!/bin/bash
if [ "${FAKE_INCUS_FAILS:-}" = "yes" ]; then
  echo "Error: cannot reach the daemon" >&2
  exit 1
fi
if [ "$*" != "list --all-projects --format csv --columns en" ]; then
  echo "fake incus: unexpected arguments: $*" >&2
  exit 2
fi
printf '%s' "${FAKE_INSTANCES:-}"
FAKE
chmod 755 "$WORK/incus"

# A log root: three old directories of instances that exist (one per project shape), one old of a deleted instance, one
# new of an instance the list does not show yet, and a log file of the host.
make_root() {
  local root="$WORK/log-$1"
  mkdir -p "$root/t-aaa_vmlive" "$root/t-aaa_vmgone" "$root/vmdefault" "$root/t-aaa_vmnew"
  echo guest > "$root/t-aaa_vmgone/console.log"
  echo dns > "$root/dnsmasq.ovnup.log"
  touch -t 202001010000 "$root/t-aaa_vmlive" "$root/t-aaa_vmgone" "$root/vmdefault" "$root/dnsmasq.ovnup.log"
  echo "$root"
}

LIVE=$'t-aaa,vmlive\ndefault,vmdefault\n'

echo "sweeps what no instance owns"
root=$(make_root sweep)
output=$(INCUS_LOG_ROOT="$root" INCUS_BIN="$WORK/incus" FAKE_INSTANCES="$LIVE" "$SWEEPER" 2>&1)
status=$?
[ $status -eq 0 ] && ok "exit 0" || bad "exit $status: $output"
[ ! -e "$root/t-aaa_vmgone" ] && ok "old directory of a deleted instance removed" || bad "t-aaa_vmgone still there"
[ -d "$root/t-aaa_vmlive" ] && ok "directory of a tenant instance kept" || bad "t-aaa_vmlive removed"
[ -d "$root/vmdefault" ] && ok "directory of a default-project instance kept" || bad "vmdefault removed"
[ -d "$root/t-aaa_vmnew" ] && ok "young directory kept though no instance is listed" || bad "t-aaa_vmnew removed"
[ -f "$root/dnsmasq.ovnup.log" ] && ok "a log file of the host is not touched" || bad "dnsmasq.ovnup.log removed"
case "$output" in
  *"removed $root/t-aaa_vmgone"*) ok "says what it removed" ;;
  *) bad "no removal line: $output" ;;
esac

echo "a failed list removes nothing"
root=$(make_root failed)
INCUS_LOG_ROOT="$root" INCUS_BIN="$WORK/incus" FAKE_INCUS_FAILS=yes "$SWEEPER" >/dev/null 2>&1
status=$?
[ $status -ne 0 ] && ok "exits non-zero" || bad "exit 0 on a failed list"
[ -d "$root/t-aaa_vmgone" ] && [ -d "$root/t-aaa_vmlive" ] && ok "nothing removed" || bad "removed on a failed list"

echo "harness self-check: the same root with every instance listed removes nothing"
root=$(make_root control)
INCUS_LOG_ROOT="$root" INCUS_BIN="$WORK/incus" FAKE_INSTANCES="$LIVE"$'t-aaa,vmgone\n' "$SWEEPER" >/dev/null 2>&1
[ -d "$root/t-aaa_vmgone" ] && ok "a listed instance keeps its directory" || bad "removed a listed instance's directory"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
