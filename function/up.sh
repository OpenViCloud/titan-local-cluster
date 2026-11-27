#!/bin/bash
# function/up.sh: Knative Serving, net-kourier, the Kata RuntimeClass and the registry on the function cluster of this
# host (function/host/install.sh first). No sudo. Safe to run again: a second run changed none of the ConfigMaps, Services,
# Deployments and the RuntimeClass it applies (server-side apply; CRDs, RBAC, webhooks and Secrets were not compared).
#
#   bash function/up.sh
#
# It talks to the function cluster's own kubeconfig only, never to the default one: that is titan-k3s's (Lima).
# FN_KUBECONFIG, FN_KUBECTL and HOST_MEMINFO stand in for /etc/rancher/k3s/k3s.yaml, kubectl and /proc/meminfo
# (tests/test_function_cluster.py).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kubeconfig=${FN_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
if [ -n "${FN_KUBECTL:-}" ]; then kc=("$FN_KUBECTL"); elif command -v kubectl >/dev/null; then kc=(kubectl); else kc=(k3s kubectl); fi
kc+=(--kubeconfig "$kubeconfig")

[ -r "$kubeconfig" ] || { echo "ERROR: cannot read $kubeconfig: sudo systemctl start k3s, or sudo bash function/host/install.sh first." >&2; exit 1; }
grep -Eq "server:[[:space:]]*['\"]?https://127\.0\.0\.1:6444" "$kubeconfig" || {
  echo "ERROR: $kubeconfig does not point at the function cluster (https://127.0.0.1:6444): refusing to apply to another cluster." >&2; exit 1; }
mem=$(bash "$here/../lima/scripts/host-memory.sh" 2>&1) || { echo "$mem" >&2; echo "ERROR: too little memory on the host to grow the function cluster (docs/topology.md#host-memory)." >&2; exit 1; }
echo "$mem"

"${kc[@]}" apply --server-side --force-conflicts -k "$here/manifests/crds"
"${kc[@]}" wait --for=condition=Established crd --all --timeout=120s
"${kc[@]}" apply --server-side --force-conflicts -k "$here/manifests/cluster"
for deploy in $("${kc[@]}" -n knative-serving get deploy -o name); do
  "${kc[@]}" -n knative-serving rollout status "$deploy" --timeout=300s
done
"${kc[@]}" -n kourier-system rollout status deploy/3scale-kourier-gateway --timeout=300s
"${kc[@]}" -n registry rollout status deploy/registry --timeout=300s
echo "Function cluster up (kubectl --kubeconfig $kubeconfig). Check it: bash function/verify.sh"
