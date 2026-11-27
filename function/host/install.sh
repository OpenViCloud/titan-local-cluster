#!/bin/bash
# function/host/install.sh: the function cluster on the Ubuntu dev host itself, not in a Lima VM. Kata's Firecracker
# shim needs KVM, and a VM would nest it (docs/topology.md#function-cluster).
#
#   sudo bash function/host/install.sh [log file]
#
# What it puts on the host (function/host/uninstall.sh takes all of it away):
#   - a thin pool `devpool` for containerd's `devmapper` snapshotter (Kata hands a pod's rootfs to Firecracker as a block
#     device only from that snapshotter): two sparse files under /var/lib/fn-cluster, rebuilt every time k3s starts by a
#     drop-in of k3s.service and /usr/local/lib/fn-cluster/devpool.sh;
#   - k3s (installer from get.k3s.io, binary from github.com, version pinned, the installer script itself is not hash-pinned) with
#     --secrets-encryption, API port 6444 and kubelet port 10350, both on every interface of the host (Lima's VMs hold 6443
#     and 10250 on 127.0.0.1); flannel host-gw (Lima holds UDP 8472). /usr/local/bin/k3s and its links, the service file,
#     /etc/rancher/k3s (kubeconfig readable by everyone, and registries.yaml, overwritten), /var/lib/rancher/k3s (with a
#     containerd template that adds the devmapper snapshotter);
#   - kata-deploy (chart 4.4.0 from ghcr.io, version pinned): /opt/kata, shim `fc`, snapshotter `devmapper`. Its own
#     RuntimeClass is off: function/manifests/cluster has ours, with the overhead measured on this cluster;
#   - net.ipv4.ip_forward and net.ipv6.conf.all.forwarding turned on by k3s; their old values are kept in
#     /var/lib/fn-cluster/host-state for uninstall.sh. k3s also adds iptables or nft chains, the cni0 bridge, routes for the pod
#     networks and IPv6 masquerade rules. ufw is not touched;
#   - downloads: get.k3s.io and github.com (k3s), ghcr.io (kata-deploy chart, job image), quay.io (kata-deploy and kubectl
#     images; the kubectl one is `latest`); docker.io and gcr.io images later.
# Then `bash function/up.sh` (no sudo) puts Knative, Kourier and the registry on it. The last step runs
# `systemctl disable k3s`: k3s holds about 2 GiB that the Lima VMs need. `sudo systemctl start k3s` starts it; `stop k3s` ends
# the server only (KillMode=process), `sudo k3s-killall.sh` is k3s's script to end the
# containers (whether it ends Kata pods is not measured).
#
# The gates run first and need no root. FN_KVM_DEVICE, FN_MACHINE and HOST_MEMINFO stand in for /dev/kvm, `uname -m` and
# /proc/meminfo (tests/test_function_cluster.py); FN_DRY_GATES=1 stops after them.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }

[ "${FN_MACHINE:-$(uname -m)}" = "x86_64" ] || die "Kata's Firecracker shim exists for x86_64 only (this host: ${FN_MACHINE:-$(uname -m)})"
[ -e "${FN_KVM_DEVICE:-/dev/kvm}" ] || die "Firecracker needs KVM and /dev/kvm is missing (looked at ${FN_KVM_DEVICE:-/dev/kvm})"
mem=$(bash "$here/../../lima/scripts/host-memory.sh" 2>&1) || { echo "$mem"; die "the host has too little memory for the function cluster (docs/topology.md#host-memory)"; }
echo "$mem"
if [ "${FN_DRY_GATES:-}" = "1" ]; then echo GATES_OK; exit 0; fi
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash $0"

LOG=${1:-/tmp/fn-cluster-install.log}
K3S_VERSION=v1.37.2+k3s1
ROOT=/var/lib/fn-cluster
LIB=/usr/local/lib/fn-cluster
rm -f "$LOG"
{ printf '# sudo bash function/host/install.sh · %s · %s\n' "$(hostname)" "$(date -u +%FT%TZ)"; } > "$LOG"
chmod 0644 "$LOG"
exec > >(tee -a "$LOG") 2>&1
set -x

V4=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
V6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
NODE_IP=$V4${V6:+,$V6}
CIDRS="--cluster-cidr=10.42.0.0/16 --service-cidr=10.43.0.0/16"
[ -z "$V6" ] || CIDRS="--cluster-cidr=10.42.0.0/16,fd42:42::/56 --service-cidr=10.43.0.0/16,fd43:43::/112 --flannel-ipv6-masq"

mkdir -p "$ROOT/devmapper/root" "$ROOT/registry" "$LIB"
# What uninstall.sh puts back: the forwarding switches are 0 on this host until k3s turns them on.
[ -f "$ROOT/host-state" ] || sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding | paste -sd' ' > "$ROOT/host-state"
[ -f "$ROOT/devmapper/data" ] || truncate -s 30G "$ROOT/devmapper/data"
[ -f "$ROOT/devmapper/meta" ] || truncate -s 2G "$ROOT/devmapper/meta"

cat > "$LIB/devpool.sh" <<'POOL'
#!/bin/bash
# The thin pool lives in two sparse files on loop devices; neither survives a reboot, so k3s's ExecStartPre makes it again.
set -euo pipefail
R=/var/lib/fn-cluster/devmapper
dmsetup info devpool >/dev/null 2>&1 && exit 0
data=$(losetup -j "$R/data" -O NAME --noheadings | head -1); [ -n "$data" ] || data=$(losetup --find --show "$R/data")
meta=$(losetup -j "$R/meta" -O NAME --noheadings | head -1); [ -n "$meta" ] || meta=$(losetup --find --show "$R/meta")
sectors=$(( $(blockdev --getsize64 "$data") / 512 ))
dmsetup create devpool --table "0 ${sectors} thin-pool ${meta} ${data} 128 32768 1 skip_block_zeroing"
POOL
chmod 0755 "$LIB/devpool.sh"
mkdir -p /etc/systemd/system/k3s.service.d
cat > /etc/systemd/system/k3s.service.d/fn-devpool.conf <<D
[Service]
ExecStartPre=$LIB/devpool.sh
D
"$LIB/devpool.sh"
dmsetup status devpool

mkdir -p /var/lib/rancher/k3s/agent/etc/containerd /etc/rancher/k3s
cat > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl <<'T'
{{ template "base" . }}
[plugins."io.containerd.snapshotter.v1.devmapper"]
  pool_name = "devpool"
  root_path = "/var/lib/fn-cluster/devmapper/root"
  base_image_size = "4GB"
  discard_blocks = true
T
cat > /etc/rancher/k3s/registries.yaml <<'T'
mirrors:
  "localhost:5100":
    endpoint: ["http://localhost:5100"]
T

if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server \
    --disable traefik --disable metrics-server --disable servicelb --write-kubeconfig-mode 644 \
    --secrets-encryption \
    --https-listen-port 6444 --kubelet-arg=port=10350 --flannel-backend=host-gw \
    --node-ip=$NODE_IP $CIDRS" sh -s -
fi
systemctl start k3s
k3s --version | head -1
for i in $(seq 1 120); do k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node -o name 2>/dev/null | grep -q node/ && break; sleep 2; done
k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml wait --for=condition=Ready node --all --timeout=300s
k3s secrets-encrypt status --server https://127.0.0.1:6444

cat <<'Y' | k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata: {name: kata-deploy, namespace: kube-system}
spec:
  chart: oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy
  version: 4.4.0
  targetNamespace: kube-system
  valuesContent: |-
    k8sDistribution: k3s
    snapshotter:
      setup: []
    shims:
      disableAll: true
      fc:
        enabled: true
        supportedArches: [amd64]
        allowedHypervisorAnnotations: [default_memory, default_vcpus]
        containerd:
          snapshotter: "devmapper"
    defaultShim:
      amd64: fc
    runtimeClasses:
      enabled: false
      createDefault: false
Y
for i in $(seq 1 300); do k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node -l katacontainers.io/kata-runtime=true -o name | grep -q node/ && break; sleep 2; done
k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get node -l katacontainers.io/kata-runtime=true -o name | grep -q node/
sleep 20; k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml wait --for=condition=Ready node --all --timeout=300s
cat /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/*.toml 2>/dev/null || true
k3s ctr plugins ls | grep -E 'snapshotter'
/opt/kata/bin/kata-runtime --version | head -1 || true
/opt/kata/bin/firecracker --version 2>/dev/null | head -1 || true
# It holds RAM the Lima VMs need: not at boot. `sudo systemctl start k3s` brings it back (the pool is made again first).
systemctl disable k3s || true
set +x
echo INSTALL_RESULT=OK
