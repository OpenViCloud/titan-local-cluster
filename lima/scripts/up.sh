#!/bin/bash
# Starts the local cluster (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#layout): both Lima VMs, created on first use,
# then the secrets, cluster local joined to titan-incus, dev's rows of the old id local-mac moved to it, and ArgoCD's root
# application. Safe to run again.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
kubeconfig="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
source "$here/scripts/host-os.sh"
if ! vms=$(vm_dir "$(uname -s)"); then
  echo "ERROR: no Lima VM files for $(uname -s); lima/ has macos/ and ubuntu/." >&2
  exit 1
fi

# Docker (on macOS, its VM) plus both of these does not fit in 16 GB (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#ram-budget).
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
  if [ "$status" != "Running" ]; then
    limactl start "$vm" --tty=false
  fi
  # Lima says READY even when the provision script failed (acceptance S-0, K-1): read the script's own last word.
  last=$(limactl shell "$vm" -- sudo grep -E "^$vm: |Failed to execute /mnt/lima-cidata/provision" /var/log/cloud-init-output.log | tail -n 1)
  case "$last" in
    "$vm: "*) echo "$last" ;;
    *)
      echo "ERROR: provisioning of $vm did not finish; see /var/log/cloud-init-output.log in the VM." >&2
      exit 1
      ;;
  esac
done

bash "$here/scripts/bootstrap-secrets.sh"
bash "$here/scripts/trust-s3-ca.sh"
bash "$here/scripts/join-cluster.sh"
bash "$here/scripts/rename-cluster-id.sh"

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
kubectl --kubeconfig "$kubeconfig" --request-timeout=30s apply -f "$repo/gitops/apps/root.yaml"

cat <<URLS
Local cluster up (kubectl: KUBECONFIG=$kubeconfig):
  portal  http://portal.localhost:8080
  admin   http://admin.localhost:8080
  api     http://api.localhost:8080
  auth    http://auth.localhost:8080/auth
  argocd  http://argocd.localhost:8080
URLS
