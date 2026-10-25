#!/bin/bash
# Puts the local cluster's secrets into titan-k3s (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#secrets):
# - the two GitHub tokens from Infisical env "local" (re-applied every run, so a rotated token lands);
# - the fixed test passwords of the integration-test role titan_it and of the realm user admin-test (re-applied every run);
# - the S3 key pair of the dev backup bucket (R2 token scoped to titan-backup-dev) from Infisical env "local", folder
#   /infra, as two Secrets with the same pair (CNPG reads one, the control plane the other: a Secret cannot be shared across
#   namespaces); re-applied every run, so a rotated key lands, and the control plane reads it again after a restart;
# - the internal ones (DB password, internal token, cluster key, the Keycloak admin and beta-user passwords), generated once: a second
#   run keeps them, because the database already holds the first password;
# - the password of the second regression test tenant (beta-user-2), generated once too (a rerun keeps it, or Keycloak
#   and the Secret disagree), but ahead of the early exit below so a cluster bootstrapped before it existed gets it.
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

# The value, or nothing when the key is absent: measured, an absent key is exit 0 with empty output. Any other exit means
# Infisical itself failed (not logged in, no network) and its stdout is a login prompt, never a value: stop, so that text is
# not applied as a token or a key.
read_infisical() {
  local name=$1
  local folder=${2:-$INFISICAL_FOLDER}
  local value
  local status=0
  value=$(infisical secrets get "$name" --projectId="$INFISICAL_PROJECT_ID" --env=local --path="$folder" --plain --silent 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    echo "ERROR: infisical failed (exit $status) reading $name from folder $folder; run 'infisical login'." >&2
    exit 1
  fi
  if [ "$value" = "*not found*" ]; then
    value=""
  fi
  printf '%s' "$value"
}

from_infisical() {
  local name=$1
  local folder=${2:-$INFISICAL_FOLDER}
  local value
  value=$(read_infisical "$name" "$folder")
  if [ -z "$value" ]; then
    echo "ERROR: $name is missing in Infisical env local, folder $folder." >&2
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
# test-all.sh of OpenViCloud/titan-control-plane needs the same value.
printf 'username=titan_it\npassword=titan-it-local-only\n' |
  k create secret generic titan-it-credentials -n titan-db-staging --type=kubernetes.io/basic-auth \
    --from-env-file=/dev/stdin --dry-run=client -o yaml | k apply -f - >/dev/null
echo "secret titan-db-staging/titan-it-credentials applied"

# User admin-test (platform-admin) of the dev realm: a fixed test password, so an agent can sign in to the admin console on dev
# without reading a Secret. Not a secret for the same reason as titan_it: dev's hosts are *.localhost. Keycloak takes a changed
# value at the next run of keycloak-config-cli, a PostSync hook: sync keycloak-local-mac once after this
# (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#secrets).
printf 'password=admin-test-local-only\n' | apply_secret titan-auth-staging admin-test-credentials

# ── Backup key of the dev bucket, re-applied every run ────────────────────────
# titan-db-backup-credentials: key names the Barman Cloud Plugin reads from the Secret of the ObjectStore (gitops/titan-db of titan-ops).
# control-plane-backup-credentials: the setting names of the control plane's BackupTarget section (gitops/control-plane of titan-ops).
# Absent keys skip both Secrets with a warning and do not stop the bootstrap; but gitops/titan-db runs the backup component,
# so until they are there CNPG cannot archive WAL (it piles up on the PVC) and the Backups page has no key pair.
backup_key_id=$(read_infisical BACKUP_DEV_ACCESS_KEY_ID /infra)
backup_secret_key=$(read_infisical BACKUP_DEV_SECRET_ACCESS_KEY /infra)
if [ -n "$backup_key_id" ] && [ -n "$backup_secret_key" ]; then
  printf 'ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n' "$backup_key_id" "$backup_secret_key" |
    apply_secret titan-db-staging titan-db-backup-credentials
  printf 'BackupTarget__AccessKeyId=%s\nBackupTarget__SecretAccessKey=%s\n' "$backup_key_id" "$backup_secret_key" |
    apply_secret titan-staging control-plane-backup-credentials
else
  echo "WARNING: BACKUP_DEV_ACCESS_KEY_ID or BACKUP_DEV_SECRET_ACCESS_KEY is missing in Infisical env local, folder /infra:" \
    "secrets titan-db-staging/titan-db-backup-credentials and titan-staging/control-plane-backup-credentials not applied." >&2
fi
unset backup_key_id backup_secret_key

# ── beta-user-2 (second regression test tenant): generated once, a rerun keeps it ─────────────────────────────
# Ahead of the early exit below: a cluster bootstrapped before this tenant existed gets its Secret on the next run.
# Only a NotFound counts as absent: a timeout must not regenerate a password Keycloak already holds.
# The error goes into a variable first: under pipefail, `kubectl … | grep -q` is false when grep exits early.
beta_user_2_lookup=$(k get secret beta-user-2-credentials -n titan-auth-staging 2>&1 >/dev/null || true)
if grep -q NotFound <<< "$beta_user_2_lookup"; then
  printf 'password=%s\n' "$(openssl rand -hex 16)" | apply_secret titan-auth-staging beta-user-2-credentials
fi

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
printf 'password=%s\n' "$(openssl rand -hex 16)" | apply_secret titan-auth-staging beta-user-credentials
# GitHub login has no OAuth app for localhost: the realm import needs the keys, the provider just never works.
printf 'github-client-id=local-disabled\ngithub-client-secret=local-disabled\n' | apply_secret titan-auth-staging social-login-credentials
unset db_password internal_token cluster_key
