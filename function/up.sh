#!/bin/bash
# function/up.sh: Knative Serving, net-kourier, the Kata RuntimeClass, the registry and the function worker on the
# function cluster of this host (function/host/install.sh first). No sudo. The worker's token is the dev control plane's
# internal token, read from secrets.env (docs/topology.md#secrets): the local cluster is up first. Safe to run again: a second run changed none of the ConfigMaps, Services,
# Deployments and the RuntimeClass it applies (server-side apply; CRDs, RBAC, webhooks and Secrets were not compared).
#
#   bash function/up.sh
#
# It talks to the function cluster's own kubeconfig only, never to the default one: that is titan-k3s's (Lima).
# FN_KUBECONFIG, FN_KUBECTL, FN_SECRETS_ENV and HOST_MEMINFO stand in for /etc/rancher/k3s/k3s.yaml, kubectl,
# ~/.config/titan-local-cluster/secrets.env and /proc/meminfo (tests/test_function_cluster.py).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kubeconfig=${FN_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
if [ -n "${FN_KUBECTL:-}" ]; then kc=("$FN_KUBECTL"); elif command -v kubectl >/dev/null; then kc=(kubectl); else kc=(k3s kubectl); fi
kc+=(--kubeconfig "$kubeconfig")
secrets_env=${FN_SECRETS_ENV:-$HOME/.config/titan-local-cluster/secrets.env}

[ -r "$kubeconfig" ] || { echo "ERROR: cannot read $kubeconfig: sudo systemctl start k3s, or sudo bash function/host/install.sh first." >&2; exit 1; }
grep -Eq "server:[[:space:]]*['\"]?https://127\.0\.0\.1:6444" "$kubeconfig" || {
  echo "ERROR: $kubeconfig does not point at the function cluster (https://127.0.0.1:6444): refusing to apply to another cluster." >&2; exit 1; }
mem=$(bash "$here/../lima/scripts/host-memory.sh" 2>&1) || { echo "$mem" >&2; echo "ERROR: too little memory on the host to grow the function cluster (docs/topology.md#host-memory)." >&2; exit 1; }
echo "$mem"
token=""
if [ -r "$secrets_env" ]; then token=$(sed -n '/^INTERNAL_TOKEN=/{s///p;q}' "$secrets_env"); fi
[ -n "$token" ] || { echo "ERROR: no INTERNAL_TOKEN in $secrets_env: bring the local cluster up first (lima/scripts/up.sh)." >&2; exit 1; }

"${kc[@]}" apply --server-side --force-conflicts -k "$here/manifests/crds"
"${kc[@]}" wait --for=condition=Established crd --all --timeout=120s
"${kc[@]}" apply --server-side --force-conflicts -k "$here/manifests/cluster"
for deploy in $("${kc[@]}" -n knative-serving get deploy -o name); do
  "${kc[@]}" -n knative-serving rollout status "$deploy" --timeout=300s
done
"${kc[@]}" -n kourier-system rollout status deploy/3scale-kourier-gateway --timeout=300s
"${kc[@]}" -n registry rollout status deploy/registry --timeout=300s
"${kc[@]}" apply --server-side --force-conflicts -k "$here/manifests/worker"
# The token goes through stdin, never argv. The worker reads it at start (envFrom): a rotated token reaches it once
# the pod restarts (kubectl -n titan-function-system rollout restart deploy/function-worker).
printf 'CP_INTERNAL_TOKEN=%s\n' "$token" |
  "${kc[@]}" -n titan-function-system create secret generic function-worker-secrets --from-env-file=/dev/stdin \
    --dry-run=client -o json |
  "${kc[@]}" apply --server-side --force-conflicts -f -
unset token
"${kc[@]}" -n titan-function-system rollout status deploy/function-worker --timeout=300s
echo "Function cluster up (kubectl --kubeconfig $kubeconfig). Check it: bash function/verify.sh"
