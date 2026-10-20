#!/bin/bash
# Puts the local cluster's secrets into titan-k3s (https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md#secrets):
# - the two GitHub tokens from Infisical env "local" (re-applied every run, so a rotated token lands);
# - the fixed test password of the integration-test role titan_it (re-applied every run);
# - the internal ones (DB password, internal token, cluster key, Keycloak passwords), generated once: a second
#   run keeps them, because the database already holds the first password.
# Values go through pipes only: no file, no command-line argument, nothing printed.
# Needs: `infisical login` done on this Mac, titan-k3s running.
set -euo pipefail

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
INFISICAL_PROJECT_ID="85de0720-f4a4-43e8-88b3-4da60d0c5925"
INFISICAL_FOLDER="/secret"
GHCR_USERNAME="openvicloud"

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

from_infisical() {
  local name=$1
  local value
  value=$(infisical secrets get "$name" --projectId="$INFISICAL_PROJECT_ID" --env=local --path="$INFISICAL_FOLDER" --plain --silent)
  if [ -z "$value" ] || [ "$value" = "*not found*" ]; then
    echo "ERROR: $name is missing in Infisical env local, folder $INFISICAL_FOLDER." >&2
    exit 1
  fi
  printf '%s' "$value"
}

# apply_secret NAMESPACE NAME: the secret's KEY=value lines come on stdin.
apply_secret() {
  k create secret generic "$2" -n "$1" --from-env-file=/dev/stdin --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "secret $1/$2 applied"
}

for namespace in argocd titan-staging titan-db-staging titan-auth-staging; do
  k create namespace "$namespace" --dry-run=client -o yaml | k apply -f - >/dev/null
done

# ── From Infisical ────────────────────────────────────────────────────────────
argocd_token=$(from_infisical ARGOCD_GITHUB_PAT)
printf 'type=git\nurl=https://github.com/OpenViCloud\nusername=x-access-token\npassword=%s\n' "$argocd_token" |
  k create secret generic github-creds -n argocd --from-env-file=/dev/stdin --dry-run=client -o yaml |
  k label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml |
  k apply -f - >/dev/null
echo "secret argocd/github-creds applied"
unset argocd_token

ghcr_token=$(from_infisical GHCR_PAT)
GHCR_TOKEN="$ghcr_token" GHCR_USERNAME="$GHCR_USERNAME" python3 -I -c '
import base64, json, os
user, token = os.environ["GHCR_USERNAME"], os.environ["GHCR_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
print(json.dumps({"auths": {"ghcr.io": {"username": user, "password": token, "auth": auth}}}))' |
  k create secret generic ghcr-credentials -n titan-staging --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml |
  k apply -f - >/dev/null
echo "secret titan-staging/ghcr-credentials applied"
unset ghcr_token

# ── Test values, re-applied every run ─────────────────────────────────────────
# Role titan_it of the dev database (gitops/titan-db): integration tests create and drop
# their own databases with it. A fixed test value, not a secret: the cluster only listens on 127.0.0.1, and
# test-all.sh of OpenViCloud/control-plane needs the same value.
printf 'username=titan_it\npassword=titan-it-local-only\n' |
  k create secret generic titan-it-credentials -n titan-db-staging --type=kubernetes.io/basic-auth \
    --from-env-file=/dev/stdin --dry-run=client -o yaml | k apply -f - >/dev/null
echo "secret titan-db-staging/titan-it-credentials applied"

# ── Generated once ────────────────────────────────────────────────────────────
if k get secret control-plane-secrets -n titan-staging >/dev/null 2>&1; then
  echo "internal secrets already exist; kept"
  exit 0
fi

db_password=$(openssl rand -hex 24)
internal_token=$(openssl rand -hex 32)
cluster_key=$(openssl rand -base64 32)

printf 'username=titan\npassword=%s\n' "$db_password" | apply_secret titan-db-staging titan-db-credentials
printf 'username=titan\npassword=%s\n' "$db_password" | apply_secret titan-auth-staging titan-db-credentials
printf 'ConnectionStrings__Titan=Host=titan-db-rw.titan-db-staging.svc.cluster.local;Port=5432;Database=titan;Username=titan;Password=%s\n' "$db_password" |
  apply_secret titan-staging control-plane-db
printf 'Internal__Token=%s\nEncryption__ClusterKey=%s\n' "$internal_token" "$cluster_key" | apply_secret titan-staging control-plane-secrets
printf 'CP_INTERNAL_TOKEN=%s\n' "$internal_token" | apply_secret titan-staging worker-secrets
printf 'admin-password=%s\n' "$(openssl rand -hex 16)" | apply_secret titan-auth-staging keycloak-admin-secret
printf 'password=%s\n' "$(openssl rand -hex 16)" | apply_secret titan-auth-staging admin-test-credentials
printf 'password=%s\n' "$(openssl rand -hex 16)" | apply_secret titan-auth-staging beta-user-credentials
# GitHub login has no OAuth app for localhost: the realm import needs the keys, the provider just never works.
printf 'github-client-id=local-disabled\ngithub-client-secret=local-disabled\n' | apply_secret titan-auth-staging social-login-credentials
unset db_password internal_token cluster_key
