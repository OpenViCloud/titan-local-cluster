#!/bin/bash
# Starts the local cluster (docs/topology.md#layout): both Lima VMs, created on first use and brought to their Lima
# file's cpus and memory (docs/topology.md#ram-budget) and provision scripts (docs/topology.md#provision-sync), then an
# extra CA of the host if it has one (docs/topology.md#extra-ca; the VMs first, ArgoCD once it is up, the regression
# runner's ConfigMap once its namespace is made), the secrets, the S3 CA, cluster local joined to titan-incus, the
# metrics certificate VictoriaMetrics reads Incus with (lima/scripts/incus-metrics.sh), and ArgoCD's root application
# (and the Applications of the names before 2026-10-27 dropped). Safe to run again.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
kubeconfig="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
source "$here/scripts/host-os.sh"
if ! vms=$(vm_dir "$(uname -s)"); then
  echo "ERROR: no Lima VM files for $(uname -s); lima/ has macos/ and ubuntu/." >&2
  exit 1
fi

# Docker (on macOS, its VM) plus both of these does not fit in 16 GB (docs/topology.md#ram-budget).
if docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is running; stop it first." >&2
  exit 1
fi

# The folder titan-k3s mounts for SeaweedFS's data (titan-k3s.yaml): Lima does not make a missing one.
mkdir -p "$HOME/.local/share/titan-local-cluster/s3"

for vm in titan-incus titan-k3s; do
  status=$(limactl list --format '{{.Status}}' "$vm" 2>/dev/null || true)
  if [ -z "$status" ]; then
    limactl create --name "$vm" --tty=false "$vms/$vm.yaml"
    status="Stopped"
  fi
  # create reads the file once: a VM made before its file's cpus or memory or provision scripts changed keeps the old ones
  # until it is edited, and Lima edits only a stopped VM (docs/topology.md#ram-budget, docs/topology.md#provision-sync).
  resize=$(limactl list --json "$vm" | python3 "$here/scripts/vm-size.py" "$vms/$vm.yaml")
  provision=$(limactl list --json "$vm" | python3 "$here/scripts/vm-provision.py" "$vms/$vm.yaml")
  reprovision=()
  while IFS= read -r expression; do
    [ -z "$expression" ] || reprovision+=(--set "$expression")
  done <<< "$provision"
  if [ -n "$resize" ] || [ -n "$provision" ]; then
    [ -z "$resize" ] || echo "$vm: resizing to $resize of $vm.yaml."
    [ -z "$provision" ] || echo "$vm: copying in $((${#reprovision[@]} / 2)) provision script(s) changed in lima/provision/."
    if [ "$status" = "Running" ]; then
      echo "$vm: stopping it for a minute or two."
      limactl stop "$vm"
    fi
    # $resize unquoted: two flags and their values, or none. The array form keeps bash 3.2 (macOS) quiet under set -u
    # when it is empty.
    limactl edit --tty=false "$vm" $resize ${reprovision[@]+"${reprovision[@]}"}
    status="Stopped"
  fi
  if [ "$status" != "Running" ]; then
    limactl list --json "$vm" | python3 "$here/scripts/ports-free.py"
    # Lima stops waiting for a first boot's provision after about 10 minutes, whatever --timeout says, and exits 1 with the
    # VM Running; the first provision of titan-incus (apt installs Incus and OVN) measured 689 s.
    if ! limactl start "$vm" --tty=false; then
      [ "$(limactl list --format '{{.Status}}' "$vm")" = "Running" ] || exit 1
      echo "$vm is still provisioning; waiting for it (up to 30 minutes)."
    fi
  fi
  # Wait for cloud-init in the VM itself, also when up.sh runs again on a VM still provisioning; it returns at once on a
  # provisioned VM. The provision check below says whether it finished.
  limactl shell "$vm" -- sudo timeout 30m cloud-init status --wait >/dev/null || true
  # Lima says READY even when the provision script failed (acceptance S-0, K-1): read the script's own last word.
  last=$(limactl shell "$vm" -- sudo grep -E "^$vm: |Failed to execute /mnt/lima-cidata/provision" /var/log/cloud-init-output.log | tail -n 1)
  case "$last" in
    "$vm: "*) echo "$last" ;;
    *)
      echo "ERROR: provisioning of $vm did not finish; see /var/log/cloud-init-output.log in the VM. If it is still installing (a slow link), run up.sh again later: it picks up where it stopped." >&2
      exit 1
      ;;
  esac
done

# Behind a TLS-inspecting proxy the VMs reach no https site until they trust its CA (docs/topology.md#extra-ca).
bash "$here/scripts/trust-extra-ca.sh"
bash "$here/scripts/bootstrap-secrets.sh"
bash "$here/scripts/trust-s3-ca.sh"
bash "$here/scripts/join-cluster.sh"
bash "$here/scripts/incus-metrics.sh"

# k3s's helm controller installs ArgoCD after provisioning ends: on a fresh VM the Application kind does not
# exist yet, and applying root fails with NotFound.
crd="crd/applications.argoproj.io"
for attempt in $(seq 1 60); do
  if kubectl --kubeconfig "$kubeconfig" --request-timeout=30s get "$crd" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "ERROR: ArgoCD's Application CRD did not appear within 10 minutes." >&2
    exit 1
  fi
  sleep 10
done
kubectl --kubeconfig "$kubeconfig" --request-timeout=30s wait --for=condition=Established "$crd" --timeout=120s >/dev/null
# ArgoCD and the namespaces exist now: the first run above could give the extra CA only to the VMs (a new titan-k3s), or skip
# the regression runner's ConfigMap (titan-auth-dev not made yet).
bash "$here/scripts/trust-extra-ca.sh"
kubectl --kubeconfig "$kubeconfig" --request-timeout=30s apply -f "$repo/gitops/apps/root.yaml"
bash "$here/scripts/drop-old-applications.sh"

cat <<URLS
Local cluster up (kubectl: KUBECONFIG=$kubeconfig):
  portal  http://portal.localhost:8080
  admin   http://admin.localhost:8080
  api     http://api.localhost:8080
  auth    http://auth.localhost:8080/auth
  argocd  http://argocd.localhost:8080
URLS
