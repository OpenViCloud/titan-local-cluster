#!/bin/bash
# Makes both VMs, ArgoCD and the regression runner trust an extra CA of the host, for a host behind a TLS-inspecting proxy
# (Cloudflare WARP Gateway): it signs every https site with its own CA, so without this ArgoCD cannot fetch this repository,
# containerd cannot pull from ghcr.io, Incus cannot pull images and the runner's npm cannot install
# (docs/topology.md#extra-ca). A host without ~/.config/titan-local-cluster/extra-ca.crt is left alone.
# The CA goes into each VM's system store; Incus and k3s (with its containerd) read that store once per process, so they
# restart when the CA changed, and only then. ArgoCD keeps its own store per host: argocd-tls-certs-cm gets one entry for
# every https host an Application of gitops/apps/ reads. The ConfigMap is the chart's, but a helm upgrade keeps keys only
# the live object has. Pods trust only their image's store: the regression runner's CronJobs mount ConfigMap titan-extra-ca
# of titan-auth-dev, written here, so its npm can install (docs/topology.md#extra-ca). The ConfigMap is not in git and carries
# no ArgoCD label, so no Application prunes it.
# Needs: both VMs running, kubectl and python3 on the host, k3s's kubeconfig copied to the host. ArgoCD not installed yet
# (a new titan-k3s) ⇒ only the VMs change: up.sh runs the script again once ArgoCD's CRD is there. Behind such a proxy that
# never happens on a new titan-k3s: its install job cannot fetch the chart (docs/topology.md#extra-ca). Namespace titan-auth-dev
# not there yet ⇒ the runner's ConfigMap waits for up.sh's run after bootstrap-secrets.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)

CA_CERT="$HOME/.config/titan-local-cluster/extra-ca.crt"
TARGET=/usr/local/share/ca-certificates/titan-extra-ca.crt
KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"

if [ ! -e "$CA_CERT" ]; then
  echo "no $CA_CERT; nothing to trust"
  exit 0
fi
if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$CA_CERT"; then
  echo "ERROR: $CA_CERT holds no PEM certificate." >&2
  exit 1
fi

in_vm() {
  local vm=$1
  shift
  limactl shell "$vm" -- sudo "$@"
}

# Writes $2 into $1:$3 when it differs: 0 written, 1 already there; a failed write stops the script.
put() {
  local vm=$1 content=$2 path=$3
  if [ "$(in_vm "$vm" cat "$path" 2>/dev/null || true)" = "$content" ]; then
    return 1
  fi
  if ! printf '%s\n' "$content" | in_vm "$vm" tee "$path" >/dev/null; then
    echo "ERROR: could not write $path in $vm." >&2
    exit 1
  fi
}

ca=$(cat "$CA_CERT")
for vm in titan-incus titan-k3s; do
  if put "$vm" "$ca" "$TARGET"; then
    in_vm "$vm" update-ca-certificates >/dev/null
    case "$vm" in
      titan-incus) in_vm "$vm" systemctl restart incus ;;
      titan-k3s) in_vm "$vm" systemctl restart k3s ;;
    esac
    echo "$vm trusts the extra CA; restarted"
  else
    echo "$vm already trusts the extra CA"
  fi
done

hosts=$(grep -h 'repoURL:' "$repo"/gitops/apps/*.yaml | sed -E 's#.*repoURL: *https://([^/]+).*#\1#' | sort -u)
patch="" live="" errors="" manifest=""
trap 'rm -f "$patch" "$live" "$errors" "$manifest"' EXIT
patch=$(mktemp)
live=$(mktemp)
errors=$(mktemp)
if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get configmap argocd-tls-certs-cm -n argocd -o json > "$live" 2> "$errors"; then
  if grep -q NotFound "$errors"; then
    echo "ArgoCD is not installed yet, so only the VMs got the extra CA; run up.sh again once ArgoCD is installed (docs/topology.md#extra-ca)"
    exit 0
  fi
  cat "$errors" >&2
  exit 1
fi
# The patch carries only the entries that differ: none ⇒ the ConfigMap is left as it is.
python3 -c '
import json, sys
live = json.load(sys.stdin).get("data") or {}
ca = open(sys.argv[1]).read()
want = {host: ca for host in sys.argv[3:] if live.get(host) != ca}
if want:
    json.dump({"data": want}, open(sys.argv[2], "w"))
' "$CA_CERT" "$patch" $hosts < "$live"
if [ -s "$patch" ]; then
  kubectl --kubeconfig "$KUBECONFIG_FILE" patch configmap argocd-tls-certs-cm -n argocd --type merge --patch-file "$patch" >/dev/null
  echo "ArgoCD trusts the extra CA for: $(echo $hosts)"
else
  echo "ArgoCD already trusts the extra CA"
fi

# The namespace comes from bootstrap-secrets.sh, which up.sh runs after this script: not there yet ⇒ skip, and up.sh's run
# after bootstrap-secrets.sh writes the ConfigMap. Stopping here would stop up.sh before it ever made the namespace.
if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get namespace titan-auth-dev -o name > /dev/null 2> "$errors"; then
  if grep -q NotFound "$errors"; then
    echo "namespace titan-auth-dev is not there yet, so the regression runner did not get the extra CA; up.sh gives it after bootstrap-secrets.sh (docs/topology.md#extra-ca)"
    exit 0
  fi
  cat "$errors" >&2
  exit 1
fi
manifest=$(mktemp)
if ! kubectl --kubeconfig "$KUBECONFIG_FILE" get configmap titan-extra-ca -n titan-auth-dev -o json > "$live" 2> "$errors"; then
  if ! grep -q NotFound "$errors"; then
    cat "$errors" >&2
    exit 1
  fi
  echo '{}' > "$live"
fi
# The manifest is written only when the ConfigMap's CA differs from the file: empty ⇒ the ConfigMap is left as it is.
python3 -c '
import json, sys
live = json.load(sys.stdin).get("data") or {}
ca = open(sys.argv[1]).read()
if live.get("extra-ca.crt") != ca:
    json.dump({"apiVersion": "v1", "kind": "ConfigMap",
               "metadata": {"name": "titan-extra-ca", "namespace": "titan-auth-dev"},
               "data": {"extra-ca.crt": ca}}, open(sys.argv[2], "w"))
' "$CA_CERT" "$manifest" < "$live"
if [ -s "$manifest" ]; then
  kubectl --kubeconfig "$KUBECONFIG_FILE" apply -f "$manifest" >/dev/null
  echo "the regression runner trusts the extra CA (ConfigMap titan-auth-dev/titan-extra-ca)"
else
  echo "the regression runner already trusts the extra CA"
fi
