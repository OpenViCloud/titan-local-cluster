#!/bin/bash
# Provision of titan-incus (mac/titan-incus.yaml): Incus 7.0 LTS with an LVM thin pool and
# a single-node OVN, the same shape as the labs recorded in OpenViCloud/incus-worker:incus/provider/testdata/
# (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md#replaces-incus-lab). Lima runs it as root on every boot,
# so every step checks before it creates.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── apt ───────────────────────────────────────────────────────────────────────
# An unattended upgrade at first boot can hold the dpkg lock; wait instead of failing.
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/90-titan-lock-timeout

apt_update() {
  for attempt in $(seq 1 30); do
    if apt-get update; then
      return 0
    fi
    sleep 10
  done
  return 1
}

apt_install() {
  for attempt in $(seq 1 30); do
    if apt-get install -y "$@"; then
      return 0
    fi
    sleep 10
  done
  return 1
}

# ── Incus from the Zabbly LTS repository ──────────────────────────────────────
# Debian's own incus package is 6.0.4, not 7.0. The key file must hold exactly one key,
# with the fingerprint the Zabbly README publishes: apt trusts every key in the file.
if [ ! -f /etc/apt/sources.list.d/zabbly-incus.sources ]; then
  apt_update
  apt_install curl gnupg
  curl -fsSL https://pkgs.zabbly.com/key.asc -o /var/tmp/zabbly.asc
  key_records=$(gpg --show-keys --with-colons /var/tmp/zabbly.asc)
  key_count=$(grep -c '^pub:' <<< "$key_records") || key_count=0
  fingerprint=$(awk -F: '/^fpr:/ { print $10; exit }' <<< "$key_records")
  if [ "$key_count" != "1" ] || [ "$fingerprint" != "4EFC590696CB15B87C73A3AD82CC8797C838DCFD" ]; then
    echo "ERROR: the Zabbly key file holds $key_count key(s), first fingerprint $fingerprint; expected one key, 4EFC590696CB15B87C73A3AD82CC8797C838DCFD." >&2
    exit 1
  fi
  install -d -m 755 /etc/apt/keyrings
  install -m 644 /var/tmp/zabbly.asc /etc/apt/keyrings/zabbly.asc
  rm -f /var/tmp/zabbly.asc
  cat > /etc/apt/sources.list.d/zabbly-incus.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/lts-7.0
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
fi

if ! command -v incus >/dev/null 2>&1 || ! command -v ovn-nbctl >/dev/null 2>&1 || ! command -v nft >/dev/null 2>&1; then
  apt_update
  # incus-base runs containers only; incus also runs VMs.
  apt_install incus lvm2 thin-provisioning-tools ovn-central ovn-host nftables
fi

if [ ! -e /dev/kvm ]; then
  echo "ERROR: no /dev/kvm; Incus cannot run virtual machines here. Is nestedVirtualization on?" >&2
  exit 1
fi

if ! incus admin waitready --timeout=300; then
  echo "ERROR: the Incus daemon did not start within 5 minutes." >&2
  exit 1
fi

# ── OVN, single node ──────────────────────────────────────────────────────────
# Northbound and southbound databases on local sockets; Geneve to itself.
ovs-vsctl set open_vswitch . \
  external_ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock \
  external_ids:ovn-encap-type=geneve \
  external_ids:ovn-encap-ip=127.0.0.1
systemctl enable --now ovn-central ovn-host

# ── Storage pool ──────────────────────────────────────────────────────────────
# lvm thin on a loop file, as in the labs: volume and snapshot behaviour was recorded on this driver.
if ! incus storage show default >/dev/null 2>&1; then
  incus admin init --preseed <<'PRESEED'
config:
  network.ovn.northbound_connection: unix:/var/run/ovn/ovnnb_db.sock
storage_pools:
- name: default
  driver: lvm
  config:
    size: 40GiB
profiles:
- name: default
  devices:
    root:
      path: /
      pool: default
      type: disk
PRESEED
fi

# ── OVN uplink for public IPv6 ────────────────────────────────────────────────
# ovnup is the zone's OVN uplink, in the shape of singapore01's (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/network.md#uplink):
# physical on ovnbr, a bridge with no address of Incus's. Only a network with public IPv6 goes on it; every other
# tenant network keeps network=none (OpenViCloud/incus-worker:resource/network/create.go). Incus refuses a network whose
# IPv4 CIDR the uplink does not route: the private ranges are listed, anycast because two tenants may pick the same
# CIDR, and with no IPv4 gateway IPv4 never leaves. A physical uplink puts no route of ipv4.routes on this host, so
# ipv4.address=auto still finds a 10.x subnet.
IPV6_BLOCK_PREFIX=2001:db8:0:d4
if ! incus network show ovnbr >/dev/null 2>&1; then
  incus network create ovnbr --type=bridge ipv4.address=none ipv6.address=none
fi
# An earlier provision made ovnup a bridge with no ipv4.routes, on which Incus refused every network asking for IPv6:
# it is replaced while nothing uses it.
if incus network show ovnup >/dev/null 2>&1; then
  uplink=$(incus query /1.0/networks/ovnup)
  uplink_type=$(python3 -c 'import json, sys; print(json.load(sys.stdin)["type"])' <<< "$uplink")
  if [ "$uplink_type" != "physical" ]; then
    users=$(python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("used_by") or []))' <<< "$uplink")
    if [ "$users" != "0" ]; then
      echo "ERROR: ovnup is a $uplink_type network that $users object(s) use; delete the networks on it, then provision again." >&2
      exit 1
    fi
    incus network delete ovnup
  fi
fi
# The first /64 of the /56 holds the gateway and the routers (::100-::1ff), every other /64 is a network's, routed to
# its router below the way OVH routes it there (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/network.md#ipv6).
if ! incus network show ovnup >/dev/null 2>&1; then
  incus network create ovnup --type=physical parent=ovnbr \
    ipv6.gateway=${IPV6_BLOCK_PREFIX}00::1/64 \
    ipv6.ovn.ranges=${IPV6_BLOCK_PREFIX}00::100-${IPV6_BLOCK_PREFIX}00::1ff \
    ipv6.routes=${IPV6_BLOCK_PREFIX}01::/64,${IPV6_BLOCK_PREFIX}02::/63,${IPV6_BLOCK_PREFIX}04::/62,${IPV6_BLOCK_PREFIX}08::/61,${IPV6_BLOCK_PREFIX}10::/60,${IPV6_BLOCK_PREFIX}20::/59,${IPV6_BLOCK_PREFIX}40::/58,${IPV6_BLOCK_PREFIX}80::/57 \
    ipv4.routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
    ipv4.routes.anycast=true \
    ovn.ingress_mode=routed
fi
# This host is the gateway ::1 of the first /64, as OVH's router is for singapore01. Incus creates ovnbr with IPv6 off
# (ipv6.address=none), so it is turned on before the address goes on.
sysctl -qw net.ipv6.conf.ovnbr.disable_ipv6=0
ip -6 addr replace ${IPV6_BLOCK_PREFIX}00::1/64 dev ovnbr
# /64 number n goes to router ::(0x100 + n) of the first /64 (https://github.com/OpenViCloud/titan/blob/main/docs/infra/incus/design.md#ipv6-address-plan): the
# static route OVH holds for singapore01, held here by the host.
for n in $(seq 1 255); do
  hex=$(printf '%02x' "$n")
  ip -6 route replace "${IPV6_BLOCK_PREFIX}${hex}::/64" via "${IPV6_BLOCK_PREFIX}00::1${hex}" dev ovnbr
done

# ── ipv4.address=auto on this VM ──────────────────────────────────────────────
# Incus also skips a 10.x subnet whose .1 or .254 address answers ping or TCP 22. Every 10.x address tried got a ping
# reply through eth0, so without this table ipv4.address=auto finds no subnet. The table also drops ping and TCP 22
# from this VM to any real 10.x host behind the Mac (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/network.md#uplink).
if nft list table inet titan-auto-subnet >/dev/null 2>&1; then
  nft delete table inet titan-auto-subnet
fi
nft -f - <<'NFT'
table inet titan-auto-subnet {
  chain out {
    type filter hook output priority filter; policy accept;
    oifname "eth0" ip daddr 10.0.0.0/8 icmp type echo-request drop
    oifname "eth0" ip daddr 10.0.0.0/8 tcp dport 22 drop
  }
}
NFT

# ── Guest logs ────────────────────────────────────────────────────────────────
# Incus 7.0.1 keeps /var/log/incus/<project>_<instance>/ after the instance is deleted, and its API refuses to delete
# qemu.log: a timer removes the directory of an instance that no longer exists
# (https://github.com/OpenViCloud/titan/blob/main/docs/features/vm/design.md#vm-design-debts). mac/tests/incus-log-sweeper_test.sh tests this text.
cat > /usr/local/sbin/incus-log-sweeper <<'SWEEPER'
#!/bin/bash
# Removes the log directory of an Incus instance that no longer exists.
set -euo pipefail
LOG_ROOT=${INCUS_LOG_ROOT:-/var/log/incus}
INCUS=${INCUS_BIN:-incus}
MIN_AGE_MINUTES=10

# Directories first, instances second: an instance created between the two reads is missing from the list, but its
# directory is younger than MIN_AGE_MINUTES and is not a candidate.
candidates=""
for path in "$LOG_ROOT"/*/; do
  [ -d "$path" ] || continue
  dir=$(basename "$path")
  if [ -n "$(find "$LOG_ROOT/$dir" -maxdepth 0 -mmin +"$MIN_AGE_MINUTES")" ]; then
    candidates="$candidates$dir
"
  fi
done
[ -n "$candidates" ] || exit 0

# A failed list stops the script (set -e) before anything is removed.
live=$("$INCUS" list --all-projects --format csv --columns en)
keep="|"
while IFS=, read -r project name; do
  [ -n "$name" ] || continue
  if [ "$project" = "default" ]; then
    keep="$keep$name|"
  else
    keep="$keep${project}_${name}|"
  fi
done <<< "$live"

printf '%s' "$candidates" | while read -r dir; do
  case "$keep" in
    *"|$dir|"*) continue ;;
  esac
  rm -rf -- "${LOG_ROOT:?}/$dir"
  echo "incus-log-sweeper: removed $LOG_ROOT/$dir"
done
SWEEPER
chmod 755 /usr/local/sbin/incus-log-sweeper
cat > /etc/systemd/system/incus-log-sweeper.service <<'UNIT'
[Unit]
Description=Remove log directories of deleted Incus instances
After=incus.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/incus-log-sweeper
UNIT
cat > /etc/systemd/system/incus-log-sweeper.timer <<'UNIT'
[Unit]
Description=Remove log directories of deleted Incus instances every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now incus-log-sweeper.timer

# ── buildkit for scripts/build-local.py ───────────────────────────────────────
# Builds another repository's images from a checkout on the Mac (the Mac runs no Docker, titan-k3s has no RAM to
# spare). Debian has no buildkit package; the release tarball also holds buildkit-runc, which buildkitd prefers.
if [ "$(/usr/local/bin/buildkitd --version 2>/dev/null | awk '{ print $3 }')" != "v0.34.0" ]; then
  curl -fsSL -o /var/tmp/buildkit.tgz \
    https://github.com/moby/buildkit/releases/download/v0.34.0/buildkit-v0.34.0.linux-arm64.tar.gz
  echo "0619ca3e3205a32ea2beb115e0242136e4a0716cc1917ba0ceaa4ef4d52382c9  /var/tmp/buildkit.tgz" | sha256sum -c -
  tar -xzf /var/tmp/buildkit.tgz -C /usr/local
  rm -f /var/tmp/buildkit.tgz
fi
mkdir -p /etc/buildkit
# Build steps run under runc in their own cgroup, /buildkit/<id> by default: outside the unit, so a cap on the unit
# left `dotnet publish` uncapped (measured). defaultCgroupParent puts them under buildkit.slice, which holds the cap.
# Host network keeps build steps off OVN's bridges. The cache shares the root disk with the Incus pool: GC keeps it
# at 10 GB (five images took 4.5 GB).
cat > /etc/buildkit/buildkitd.toml <<'TOML'
[worker.oci]
  enabled = true
  gc = true
  reservedSpace = "1GB"
  maxUsedSpace = "10GB"
  minFreeSpace = "10GB"
  defaultCgroupParent = "buildkit.slice"
[worker.containerd]
  enabled = false
TOML
# 1536M: control-plane, the largest build, peaked at 729 MiB of anonymous memory and took 73 s under this cap (193 s
# under 1G, page cache squeezed). The cap does not keep guests alive when they already hold the RAM: then the whole
# VM runs out, and OOMScoreAdjust=1000 (inherited by build steps) makes the kernel kill the build, not a guest's qemu.
cat > /etc/systemd/system/buildkit.slice <<'UNIT'
[Unit]
Description=buildkitd and its build steps

[Slice]
MemoryMax=1536M
MemorySwapMax=0
UNIT
cat > /etc/systemd/system/buildkit.service <<'UNIT'
[Unit]
Description=buildkitd for scripts/build-local.py
After=network-online.target

[Service]
Slice=buildkit.slice
ExecStart=/usr/local/bin/buildkitd --oci-worker-net=host
OOMScoreAdjust=1000

[Install]
WantedBy=multi-user.target
UNIT
cat > /usr/local/sbin/buildkit-check <<'CHECK'
#!/bin/bash
# What scripts/build-local.py reads before it builds: buildkitd is active, runs in buildkit.slice, and puts its build
# steps there too.
systemctl is-active buildkit.service
cat "/proc/$(systemctl show -p MainPID --value buildkit.service)/cgroup"
grep -E '^\s*defaultCgroupParent\s*=' /etc/buildkit/buildkitd.toml
exit 0
CHECK
chmod 755 /usr/local/sbin/buildkit-check
systemctl daemon-reload
systemctl enable buildkit.service
# Restarted on every provision (every boot), so a changed toml or cap takes effect; a build running then fails.
systemctl restart buildkit.service

# ── API on the user-v2 address only ───────────────────────────────────────────
# user-v2 is this VM's only NIC (it also carries the default route); its address comes from Lima's
# DHCP, keyed on the instance's MAC. Read it from the default route, not from an interface name.
api_address=""
for attempt in $(seq 1 30); do
  uplink_dev=$(ip -4 route show default | awk '{ print $5; exit }') || uplink_dev=""
  if [ -n "$uplink_dev" ]; then
    api_address=$(ip -4 -o addr show dev "$uplink_dev" | awk '{ split($4, a, "/"); print a[1]; exit }') || api_address=""
  fi
  if [ -n "$api_address" ]; then
    break
  fi
  sleep 2
done
if [ -z "$api_address" ]; then
  echo "ERROR: no IPv4 address on the default-route interface; is the user-v2 network attached?" >&2
  exit 1
fi
incus config set core.https_address="$api_address:8443"
echo "titan-incus: Incus API on https://$api_address:8443"
