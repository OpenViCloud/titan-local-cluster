#!/bin/bash
# Puts the local cluster's secrets into titan-k3s (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#secrets).
# Needs no vault and no token: the repositories and the images are public.
# - ~/.config/titan-local-cluster/secrets.env (mode 600) keeps every value generated once: the DB password, the internal
#   token, the cluster key, the Keycloak admin and the two beta-user passwords. The first run writes them; later runs read
#   them and only add a key a newer script needs. The file outlives the VM, so a cluster rebuilt with `limactl delete`
#   gets the same values, which the database restored from a backup already holds. It also keeps the key pair of dev's S3
#   (SeaweedFS, gitops/seaweedfs), generated the same way.
# - The S3 CA and SeaweedFS's server certificate (name lima-titan-k3s.internal), made once with openssl next to secrets.env:
#   the CA's key never enters the cluster, and a rebuilt cluster trusts the same CA. Incus trusts it through titan-incus's
#   system store (mac/scripts/trust-s3-ca.sh); barman, the control plane and the worker through Secret s3-ca.
# - Those Secrets are applied only when the cluster has none yet: a running cluster keeps its own values, and the script
#   never reads a Secret back.
# - The S3 key pair as SeaweedFS's identity and as three Secrets with the same pair (CNPG reads one, the control plane one,
#   the worker one for Incus's uploads: CNPG is in another namespace, and each reader has its own key names); re-applied
#   every run.
# - ghcr-credentials with no auth: the shared base names it as the pull Secret, and GHCR serves the images anonymously.
# - The fixed test passwords of the integration-test role titan_it and of the realm user admin-test, re-applied every run.
# Values go through pipes and the file only: no command-line argument, nothing printed.
# Needs: titan-k3s running.
set -euo pipefail

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
SECRETS_DIR="$HOME/.config/titan-local-cluster"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
CA_CERT="$SECRETS_DIR/s3-ca.crt"
CA_KEY="$SECRETS_DIR/s3-ca.key"
S3_CERT="$SECRETS_DIR/s3.crt"
S3_KEY="$SECRETS_DIR/s3.key"
# The name every S3 client uses: it resolves to titan-k3s on Lima's user-v2 network, from titan-incus and from pods alike,
# whatever address DHCP gives the VM.
S3_HOST="lima-titan-k3s.internal"

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

# The value of NAME in secrets.env, or nothing. Read line by line, never sourced: a value is data, not shell.
from_file() {
  local name=$1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$SECRETS_FILE"
}

# ensure_value NAME COMMAND...: adds NAME with COMMAND's output when the file lacks it; a value already there is kept.
ensure_value() {
  local name=$1
  shift
  local value
  if [ -z "$(from_file "$name")" ]; then
    value=$("$@") || value=""
    if [ -z "$value" ]; then
      echo "ERROR: could not generate $name; $SECRETS_FILE is unchanged." >&2
      exit 1
    fi
    printf '%s=%s\n' "$name" "$value" >> "$SECRETS_FILE"
  fi
}

# apply_secret NAMESPACE NAME: the secret's KEY=value lines come on stdin.
apply_secret() {
  k create secret generic "$2" -n "$1" --from-env-file=/dev/stdin --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "secret $1/$2 applied"
}

# Only a NotFound counts as absent: a timeout must not apply a value over one the cluster already holds.
# The error goes into a variable first: under pipefail, `kubectl … | grep -q` is false when grep exits early.
secret_absent() {
  local lookup
  lookup=$(k get secret "$2" -n "$1" 2>&1 >/dev/null || true)
  grep -q NotFound <<< "$lookup"
}

# ── secrets.env ───────────────────────────────────────────────────────────────
umask 077
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
touch "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
ensure_value TITAN_DB_PASSWORD openssl rand -hex 24
ensure_value INTERNAL_TOKEN openssl rand -hex 32
ensure_value CLUSTER_ENCRYPTION_KEY openssl rand -base64 32
ensure_value KEYCLOAK_ADMIN_PASSWORD openssl rand -hex 16
ensure_value BETA_USER_PASSWORD openssl rand -hex 16
ensure_value BETA_USER_2_PASSWORD openssl rand -hex 16
ensure_value BACKUP_S3_ACCESS_KEY_ID openssl rand -hex 10
ensure_value BACKUP_S3_SECRET_ACCESS_KEY openssl rand -hex 20
echo "secrets.env at $SECRETS_FILE"

# ── S3 CA and certificate ─────────────────────────────────────────────────────
# Extensions come from a file, not -addext: macOS's own openssl (LibreSSL) and Homebrew's OpenSSL both read it.
extensions=$(mktemp)
trap 'rm -f "$extensions" "$S3_CERT.csr"' EXIT
cat > "$extensions" <<EXT
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:$S3_HOST
EXT
if [ ! -s "$CA_CERT" ] || [ ! -s "$CA_KEY" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
  openssl req -new -key "$CA_KEY" -subj "/CN=titan-local-cluster S3 CA" -out "$S3_CERT.csr"
  openssl x509 -req -in "$S3_CERT.csr" -signkey "$CA_KEY" -days 3650 -sha256 \
    -extfile "$extensions" -extensions ca -out "$CA_CERT"
  rm -f "$S3_CERT"
  echo "S3 CA made at $CA_CERT"
fi
if [ ! -s "$S3_CERT" ] || [ ! -s "$S3_KEY" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$S3_KEY"
  openssl req -new -key "$S3_KEY" -subj "/CN=$S3_HOST" -out "$S3_CERT.csr"
  openssl x509 -req -in "$S3_CERT.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -set_serial "0x$(openssl rand -hex 8)" \
    -days 3650 -sha256 -extfile "$extensions" -extensions server -out "$S3_CERT"
  echo "S3 certificate made at $S3_CERT"
fi
chmod 600 "$CA_KEY" "$S3_KEY"

for namespace in argocd titan-staging titan-db-staging titan-auth-staging seaweedfs; do
  k create namespace "$namespace" --dry-run=client -o yaml | k apply -f - >/dev/null
done

# ── Pull Secret ───────────────────────────────────────────────────────────────
printf '{"auths": {}}\n' |
  k create secret generic ghcr-credentials -n titan-staging --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml |
  k apply -f - >/dev/null
echo "secret titan-staging/ghcr-credentials applied"

# ── Test values, re-applied every run ─────────────────────────────────────────
# Role titan_it of the dev database (base/titan-db): integration tests create and drop
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

# ── S3 of dev (SeaweedFS), re-applied every run ───────────────────────────────
k create secret tls seaweedfs-tls -n seaweedfs --cert="$S3_CERT" --key="$S3_KEY" --dry-run=client -o yaml | k apply -f - >/dev/null
echo "secret seaweedfs/seaweedfs-tls applied"
for namespace in titan-db-staging titan-staging; do
  k create secret generic s3-ca -n "$namespace" --from-file=ca.crt="$CA_CERT" --dry-run=client -o yaml | k apply -f - >/dev/null
  echo "secret $namespace/s3-ca applied"
done
backup_key_id=$(from_file BACKUP_S3_ACCESS_KEY_ID)
backup_secret_key=$(from_file BACKUP_S3_SECRET_ACCESS_KEY)
# SeaweedFS's one identity (weed server -s3.config). No Admin: the bucket Job of gitops/seaweedfs goes through master and filer.
printf '{"identities": [{"name": "titan", "credentials": [{"accessKey": "%s", "secretKey": "%s"}], "actions": ["Read", "Write", "List", "Tagging"]}]}\n' \
  "$backup_key_id" "$backup_secret_key" |
  k create secret generic seaweedfs-s3-config -n seaweedfs --from-file=s3.json=/dev/stdin --dry-run=client -o yaml |
  k apply -f - >/dev/null
echo "secret seaweedfs/seaweedfs-s3-config applied"
# titan-db-backup-credentials: key names the Barman Cloud Plugin reads from the Secret of the ObjectStore (base/titan-db/components/backup).
# control-plane-backup-credentials: the setting names of the control plane's BackupTarget section (gitops/control-plane/patch-env.yaml).
# incus-worker-backup-credentials: the worker's BACKUP_S3_* names; the worker hands the pair to Incus, which uploads VM and
# volume backups itself (https://github.com/OpenViCloud/titan-ops/blob/main/docs/features/backup/design.md#incus-backup).
printf 'ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n' "$backup_key_id" "$backup_secret_key" |
  apply_secret titan-db-staging titan-db-backup-credentials
printf 'BackupTarget__AccessKeyId=%s\nBackupTarget__SecretAccessKey=%s\n' "$backup_key_id" "$backup_secret_key" |
  apply_secret titan-staging control-plane-backup-credentials
printf 'BACKUP_S3_ACCESS_KEY_ID=%s\nBACKUP_S3_SECRET_ACCESS_KEY=%s\n' "$backup_key_id" "$backup_secret_key" |
  apply_secret titan-staging incus-worker-backup-credentials
unset backup_key_id backup_secret_key

# ── beta-user-2 (second regression test tenant) ───────────────────────────────
# Ahead of the early exit below: a cluster bootstrapped before this tenant existed gets its Secret on the next run.
if secret_absent titan-auth-staging beta-user-2-credentials; then
  printf 'password=%s\n' "$(from_file BETA_USER_2_PASSWORD)" | apply_secret titan-auth-staging beta-user-2-credentials
fi

# ── Generated once, applied when the cluster has none ─────────────────────────
if ! secret_absent titan-staging control-plane-secrets; then
  echo "internal secrets already exist; kept"
  exit 0
fi

db_password=$(from_file TITAN_DB_PASSWORD)
internal_token=$(from_file INTERNAL_TOKEN)

printf 'username=titan\npassword=%s\n' "$db_password" | apply_secret titan-db-staging titan-db-credentials
printf 'username=titan\npassword=%s\n' "$db_password" | apply_secret titan-auth-staging titan-db-credentials
printf 'ConnectionStrings__Titan=Host=titan-db-rw.titan-db-staging.svc.cluster.local;Port=5432;Database=titan;Username=titan;Password=%s\n' "$db_password" |
  apply_secret titan-staging control-plane-db
printf 'Internal__Token=%s\nEncryption__ClusterKey=%s\n' "$internal_token" "$(from_file CLUSTER_ENCRYPTION_KEY)" |
  apply_secret titan-staging control-plane-secrets
printf 'CP_INTERNAL_TOKEN=%s\n' "$internal_token" | apply_secret titan-staging worker-secrets
printf 'admin-password=%s\n' "$(from_file KEYCLOAK_ADMIN_PASSWORD)" | apply_secret titan-auth-staging keycloak-admin-secret
printf 'password=%s\n' "$(from_file BETA_USER_PASSWORD)" | apply_secret titan-auth-staging beta-user-credentials
# GitHub login has no OAuth app for localhost: the realm import needs the keys, the provider just never works.
printf 'github-client-id=local-disabled\ngithub-client-secret=local-disabled\n' | apply_secret titan-auth-staging social-login-credentials
unset db_password internal_token
