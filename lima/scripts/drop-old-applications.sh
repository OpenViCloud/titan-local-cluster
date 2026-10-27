#!/bin/bash
# Deletes the Applications of the names before 2026-10-27 (*-local-mac, root-local-mac) that still exist, after up.sh has
# applied root-local. The old root lists itself and may not prune itself; two roots with prune and selfHeal would fight
# over the same children. Without a finalizer, deleting an Application leaves its resources to the new Application, so the
# script stops, deleting nothing, if any old one has a finalizer. Safe to run again.
set -euo pipefail

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

read -r -a old < <(k get applications.argoproj.io -n argocd -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
old = [a for a in items if a["metadata"]["name"].endswith("-local-mac")]
held = [a["metadata"]["name"] for a in old if a["metadata"].get("finalizers")]
if held:
    print("ERROR: these old Applications have a finalizer, so deleting them would delete their resources: " + " ".join(held), file=sys.stderr)
    sys.exit(1)
print(" ".join(a["metadata"]["name"] for a in old))')
if [ "${#old[@]}" -eq 0 ]; then
  exit 0
fi
k delete applications.argoproj.io -n argocd --wait=false "${old[@]}" >/dev/null
echo "old Applications deleted (their resources stay with the new ones): ${old[*]}"
