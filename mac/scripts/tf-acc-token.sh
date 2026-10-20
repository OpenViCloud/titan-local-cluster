#!/bin/bash
# Gives the Terraform provider's acceptance tests (TF_ACC) an API token of beta-user on the dev cluster
# (https://github.com/OpenViCloud/titan/blob/main/docs/features/terraform-provider/design.md#acceptance-on-dev). The row goes straight into the dev
# database: beta-user's password stays in the cluster, and the script works again after the database is
# rebuilt, once beta-user has logged in to the portal (that first login creates the tenant). Each run
# replaces the one token named tf-acc, so runs never pile up against the 20-token cap.
# The token is written to a 0600 file outside git and never printed.
set -euo pipefail

KC="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
ENV_FILE="${OPENVICLOUD_TF_ACC_ENV:-$HOME/.config/openvicloud/tf-acc.env}"
API_URL="http://api.localhost:8080"
EMAIL="beta-user@openvicloud.com"

# The dev and staging clusters share namespace names; only the dev cluster answers on this address.
server=$(kubectl --kubeconfig "$KC" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
if [ "$server" != "https://127.0.0.1:6443" ]; then
  echo "refusing: kubeconfig points at $server, not the dev cluster" >&2
  exit 1
fi

pod=$(kubectl --kubeconfig "$KC" --request-timeout=10s -n titan-db-staging get pods \
  -l cnpg.io/instanceRole=primary -o name)
if [ -z "$pod" ]; then
  echo "no primary Postgres pod in titan-db-staging" >&2
  exit 1
fi

token=$(python3 -I -c 'import base64, secrets; print("ovc_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode())')
hash=$(printf '%s' "$token" | shasum -a 256 | cut -d' ' -f1)
prefix=${token:0:8}

# The SQL goes in on stdin: no kubectl command line carries the column names.
if ! result=$(kubectl --kubeconfig "$KC" -n titan-db-staging exec -i "$pod" -c postgres -- \
  psql -U postgres -d titan -v ON_ERROR_STOP=1 -At 2>&1 <<SQL
BEGIN;
DELETE FROM core.api_tokens
 WHERE name = 'tf-acc'
   AND tenant_id = (SELECT id FROM core.tenants WHERE email = '$EMAIL');
INSERT INTO core.api_tokens (id, tenant_id, keycloak_user_id, name, prefix, secret_hash, created_at, expires_at)
SELECT gen_random_uuid(), t.id, m.keycloak_user_id, 'tf-acc', '$prefix', '$hash', now(), now() + interval '30 days'
  FROM core.tenants t
  JOIN core.tenant_members m ON m.tenant_id = t.id
 WHERE t.email = '$EMAIL'
 LIMIT 1;
COMMIT;
SQL
); then
  echo "writing the token failed:" >&2
  printf '%s\n' "$result" >&2
  exit 1
fi
if ! printf '%s\n' "$result" | grep -qx 'INSERT 0 1'; then
  echo "no token written (is beta-user's tenant on the dev cluster?):" >&2
  printf '%s\n' "$result" >&2
  exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
( umask 077; printf 'OPENVICLOUD_API_URL=%s\nOPENVICLOUD_TOKEN=%s\n' "$API_URL" "$token" > "$ENV_FILE" )
chmod 600 "$ENV_FILE"

status=$(printf 'Authorization: Bearer %s\n' "$token" | \
  curl -s -o /dev/null -w '%{http_code}' -H @- "$API_URL/v1/tenant")
if [ "$status" != "200" ]; then
  echo "token written to $ENV_FILE but GET /v1/tenant answered $status" >&2
  exit 1
fi
echo "token tf-acc written to $ENV_FILE, valid 30 days; GET /v1/tenant 200"
