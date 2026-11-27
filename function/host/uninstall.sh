#!/bin/bash
# function/host/uninstall.sh: everything install.sh put on the host, and nothing else. It is destructive: it starts k3s if it is
# stopped, force-deletes every pod (`--grace-period=0 --force`), runs k3s-uninstall.sh, removes /opt/kata, /etc/rancher/k3s,
# /var/lib/rancher/k3s, the k3s.service drop-in, /usr/local/lib/fn-cluster and /var/lib/fn-cluster (the thin pool and the
# registry's images with it), and sets the two forwarding sysctls back to the values kept in /var/lib/fn-cluster/host-state.
# It leaves /tmp/fn-cluster-*.log.
#
#   sudo bash function/host/uninstall.sh [log file]
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo: sudo bash $0" >&2; exit 1; }
LOG=${1:-/tmp/fn-cluster-uninstall.log}
ROOT=/var/lib/fn-cluster
rm -f "$LOG"
{ printf '# sudo bash function/host/uninstall.sh · %s · %s\n' "$(hostname)" "$(date -u +%FT%TZ)"; } > "$LOG"
chmod 0644 "$LOG"
exec > >(tee -a "$LOG") 2>&1
set -x
if command -v k3s >/dev/null; then
  systemctl start k3s || true
  k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml delete pods --all -A --grace-period=0 --force --timeout=60s || true
  k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n kube-system delete helmchart kata-deploy --timeout=180s || true   # runs the chart's cleanup job
  sleep 30
fi
[ -x /usr/local/bin/k3s-uninstall.sh ] && /usr/local/bin/k3s-uninstall.sh
rm -rf /opt/kata /etc/rancher/k3s /var/lib/rancher/k3s /etc/systemd/system/k3s.service.d/fn-devpool.conf /usr/local/lib/fn-cluster
systemctl daemon-reload
dmsetup remove devpool || true
for d in $(losetup -j $ROOT/devmapper/data -O NAME --noheadings) $(losetup -j $ROOT/devmapper/meta -O NAME --noheadings); do losetup -d "$d"; done
if [ -f $ROOT/host-state ]; then
  read -r v4 v6 < $ROOT/host-state
  sysctl -w net.ipv4.ip_forward="$v4" net.ipv6.conf.all.forwarding="$v6"
fi
rm -rf $ROOT
set +x
echo "LEFT: $(ls -d /opt/kata /var/lib/rancher/k3s $ROOT /usr/local/bin/k3s 2>/dev/null | tr '\n' ' ')"
dmsetup ls; ip link show | grep -E 'cni0|flannel|kube' || echo "no cni links"
echo UNINSTALL_RESULT=OK
