#!/usr/bin/env bash
# bootstrap-secrets_test.sh — what mac/scripts/bootstrap-secrets.sh keeps in ~/.config/titan-local-cluster/secrets.env and
# puts into the cluster.
#
# WHY this file exists: the script is the only place the dev cluster's secrets come from, and it must work for someone with
# no vault and no GitHub token. The values it generates once must survive a rebuild (the database restored from a backup
# holds the first password), so a second run must keep every value in the file. The script runs here against a fake
# `kubectl` and `openssl` on PATH, and an `infisical` that fails if called: the values must reach kubectl on stdin and
# nowhere else, and the Secret key names must be the ones their readers use.
#
# Run:  bash mac/tests/bootstrap-secrets_test.sh     (from the repo root; macOS bash 3.2 and python3)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/bootstrap-secrets.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/infisical" <<'FAKE'
#!/bin/bash
printf 'called\n' >> "$FAKE_LOG.infisical"
exit 1
FAKE
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# Records every call; `create secret generic NAME` keeps what came on stdin. `get secret` finds every Secret, unless
# FAKE_EMPTY_CLUSTER=1: then each one is NotFound, as on a cluster created a moment ago.
printf '%s\n' "$*" >> "$FAKE_LOG.kubectl"
case "$*" in
  *"create secret generic"*)
    name=$(printf '%s\n' "$*" | sed -E 's/.*create secret generic ([^ ]+).*/\1/')
    cat > "$FAKE_LOG.stdin.$name" ;;
  *"get secret"*)
    if [ -n "${FAKE_EMPTY_CLUSTER-}" ]; then
      echo 'Error from server (NotFound): secrets "x" not found' >&2
      exit 1
    fi
    exit 0 ;;
  *) cat > /dev/null ;;
esac
exit 0
FAKE
cat > "$WORK/bin/openssl" <<'FAKE'
#!/bin/bash
[ -n "${FAKE_OPENSSL_FAIL-}" ] && exit 1
# A different value on each call, so the test can tell which generated value went where.
count=$(( $(cat "$FAKE_LOG.openssl" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$FAKE_LOG.openssl"
printf 'random%s' "$count"
FAKE
chmod +x "$WORK/bin/"*

# run CASE HOME_DIR VAR=value ...: runs the script with that HOME and environment; sets RC, OUT (stderr+stdout), FAKE_LOG.
# No GitHub token and no Infisical login exist in its environment.
run() {
  local case_name=$1
  local home=$2
  shift 2
  FAKE_LOG="$WORK/$case_name"
  export FAKE_LOG
  OUT=$(env -u GITHUB_TOKEN -u GH_TOKEN -u INFISICAL_TOKEN HOME="$home" PATH="$WORK/bin:$PATH" FAKE_LOG="$FAKE_LOG" "$@" \
    bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

# value FILE KEY: the value of KEY in an env file.
value() { sed -n "s/^$2=//p" "$1"; }

KEYS="TITAN_DB_PASSWORD INTERNAL_TOKEN CLUSTER_ENCRYPTION_KEY KEYCLOAK_ADMIN_PASSWORD BETA_USER_PASSWORD BETA_USER_2_PASSWORD"

echo "first run on a new cluster: no vault, no GitHub token, no secrets.env"
mkdir -p "$WORK/fresh"
run fresh "$WORK/fresh" FAKE_EMPTY_CLUSTER=1
FILE="$WORK/fresh/.config/titan-local-cluster/secrets.env"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ ! -e "$WORK/fresh.infisical" ] && ok "infisical is never called" || bad "infisical was called"
[ -f "$FILE" ] && ok "secrets.env is created" || bad "no $FILE"
[ "$(stat -f '%Lp' "$FILE" 2>/dev/null)" = "600" ] && ok "secrets.env is mode 600" || bad "mode $(stat -f '%Lp' "$FILE" 2>&1)"
[ "$(stat -f '%Lp' "$(dirname "$FILE")" 2>/dev/null)" = "700" ] && ok "its folder is mode 700" \
  || bad "folder mode $(stat -f '%Lp' "$(dirname "$FILE")" 2>&1)"
missing=""
for key in $KEYS; do
  [ -n "$(value "$FILE" "$key")" ] || missing="$missing $key"
done
[ -z "$missing" ] && ok "every generated value is in the file" || bad "missing or empty:$missing"
db=$(value "$FILE" TITAN_DB_PASSWORD)
token=$(value "$FILE" INTERNAL_TOKEN)
key=$(value "$FILE" CLUSTER_ENCRYPTION_KEY)
printf 'username=titan\npassword=%s\n' "$db" | cmp -s - "$WORK/fresh.stdin.titan-db-credentials" \
  && ok "the database's Secret carries the file's password" || bad "titan-db-credentials differs from the file"
grep -q "Password=$db\$" "$WORK/fresh.stdin.control-plane-db" \
  && ok "the control plane's connection string carries the same password" || bad "control-plane-db differs from the file"
printf 'Internal__Token=%s\nEncryption__ClusterKey=%s\n' "$token" "$key" | cmp -s - "$WORK/fresh.stdin.control-plane-secrets" \
  && ok "the control plane gets the file's internal token and cluster key" || bad "control-plane-secrets differs from the file"
printf 'CP_INTERNAL_TOKEN=%s\n' "$token" | cmp -s - "$WORK/fresh.stdin.worker-secrets" \
  && ok "the worker gets the same internal token" || bad "worker-secrets differs from the file"
printf 'admin-password=%s\n' "$(value "$FILE" KEYCLOAK_ADMIN_PASSWORD)" | cmp -s - "$WORK/fresh.stdin.keycloak-admin-secret" \
  && ok "Keycloak's admin password comes from the file" || bad "keycloak-admin-secret differs from the file"
printf 'password=%s\n' "$(value "$FILE" BETA_USER_PASSWORD)" | cmp -s - "$WORK/fresh.stdin.beta-user-credentials" \
  && ok "beta-user's password comes from the file" || bad "beta-user-credentials differs from the file"
printf 'password=%s\n' "$(value "$FILE" BETA_USER_2_PASSWORD)" | cmp -s - "$WORK/fresh.stdin.beta-user-2-credentials" \
  && ok "beta-user-2's password comes from the file" || bad "beta-user-2-credentials differs from the file"
grep -q 'github-creds' "$WORK/fresh.kubectl" && bad "a GitHub repository credential was made" \
  || ok "no GitHub repository credential: the repository is public"
printf '{"auths": {}}\n' | cmp -s - "$WORK/fresh.stdin.ghcr-credentials" \
  && ok "ghcr-credentials has no auth: images are pulled anonymously" \
  || bad "stdin of ghcr-credentials was: $(cat "$WORK/fresh.stdin.ghcr-credentials" 2>&1)"
grep -q 'create secret generic ghcr-credentials -n titan-staging --type=kubernetes.io/dockerconfigjson' "$WORK/fresh.kubectl" \
  && ok "as a dockerconfigjson Secret in titan-staging" || bad "wrong type, name or namespace for ghcr-credentials"
leaked=""
for key in $KEYS; do
  v=$(value "$FILE" "$key")
  if grep -qF -- "$v" "$WORK/fresh.kubectl" || printf '%s' "$OUT" | grep -qF -- "$v"; then
    leaked="$leaked $key"
  fi
done
[ -z "$leaked" ] && ok "no generated value in any kubectl argument or in the output" || bad "leaked:$leaked"

echo "second run: the file is kept as it is"
cp "$FILE" "$WORK/first-secrets.env"
run again "$WORK/fresh" FAKE_EMPTY_CLUSTER=1
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
cmp -s "$FILE" "$WORK/first-secrets.env" && ok "secrets.env is byte for byte the same" || bad "secrets.env changed"
printf 'username=titan\npassword=%s\n' "$db" | cmp -s - "$WORK/again.stdin.titan-db-credentials" \
  && ok "a cluster rebuilt from scratch gets the first database password again" || bad "the rebuilt cluster got another password"

echo "a file from an older script, without some keys"
mkdir -p "$WORK/old/.config/titan-local-cluster"
OLD="$WORK/old/.config/titan-local-cluster/secrets.env"
# A key that starts with another key's name comes first: a lookup by prefix would read it.
printf 'TITAN_DB_PASSWORD_BEFORE_ROTATION=not-this\nTITAN_DB_PASSWORD=kept-db\nCLUSTER_ENCRYPTION_KEY=kept/key+b64=\n' > "$OLD"
chmod 644 "$OLD"
chmod 755 "$(dirname "$OLD")"
run old "$WORK/old" FAKE_EMPTY_CLUSTER=1
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(value "$OLD" TITAN_DB_PASSWORD)" = "kept-db" ] && [ "$(value "$OLD" CLUSTER_ENCRYPTION_KEY)" = "kept/key+b64=" ] \
  && ok "the values already there are kept" || bad "a kept value changed: $(sed 's/=.*/=<value>/' "$OLD")"
missing=""
for key in $KEYS; do
  [ -n "$(value "$OLD" "$key")" ] || missing="$missing $key"
done
[ -z "$missing" ] && ok "the missing keys are added" || bad "still missing:$missing"
[ "$(stat -f '%Lp' "$OLD")" = "600" ] && ok "the file is set back to mode 600" || bad "mode $(stat -f '%Lp' "$OLD")"
[ "$(stat -f '%Lp' "$(dirname "$OLD")")" = "700" ] && ok "its folder is set back to mode 700" \
  || bad "folder mode $(stat -f '%Lp' "$(dirname "$OLD")")"
printf 'username=titan\npassword=kept-db\n' | cmp -s - "$WORK/old.stdin.titan-db-credentials" \
  && ok "the value is read by its exact name, not by a prefix" || bad "titan-db-credentials did not get kept-db"
grep -q 'Encryption__ClusterKey=kept/key+b64=$' "$WORK/old.stdin.control-plane-secrets" \
  && ok "a value with / + = reaches the Secret unchanged" || bad "control-plane-secrets lost the cluster key"

echo "openssl failing"
mkdir -p "$WORK/nossl"
run nossl "$WORK/nossl" FAKE_EMPTY_CLUSTER=1 FAKE_OPENSSL_FAIL=1
NFILE="$WORK/nossl/.config/titan-local-cluster/secrets.env"
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'ERROR: could not generate TITAN_DB_PASSWORD' \
  && ok "the script stops and names the value" || bad "rc=$RC $OUT"
grep -q '=$' "$NFILE" && bad "an empty value was written" || ok "no empty value is written"
ls "$WORK"/nossl.stdin.* > /dev/null 2>&1 && bad "a Secret was applied" || ok "no Secret is applied"

echo "a running cluster that has its secrets already"
run running "$WORK/fresh"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q 'internal secrets already exist; kept' && ok "says it keeps them" || bad "$OUT"
over=""
for name in titan-db-credentials control-plane-secrets worker-secrets keycloak-admin-secret beta-user-credentials beta-user-2-credentials; do
  [ -e "$WORK/running.stdin.$name" ] && over="$over $name"
done
[ -z "$over" ] && ok "no generated Secret is applied over the cluster's own values" || bad "applied over the cluster:$over"
grep -q 'get secret.*-o \|get secret.*jsonpath\|get secret.*yaml\|get secret.*json' "$WORK/running.kubectl" \
  && bad "the script reads a Secret's content" || ok "the script never reads a Secret's content"
printf 'password=admin-test-local-only\n' | cmp -s - "$WORK/running.stdin.admin-test-credentials" \
  && ok "admin-test gets its fixed test password" || bad "stdin of admin-test-credentials was: $(cat "$WORK/running.stdin.admin-test-credentials" 2>&1)"
grep -q 'create secret generic admin-test-credentials -n titan-auth-staging' "$WORK/running.kubectl" \
  && ok "in titan-auth-staging, where Keycloak's realm import reads it" || bad "wrong namespace or name for admin-test-credentials"

echo "backup keys in secrets.env"
mkdir -p "$WORK/backup"
run backup0 "$WORK/backup"
BFILE="$WORK/backup/.config/titan-local-cluster/secrets.env"
printf 'BACKUP_S3_ACCESS_KEY_ID=kid-123\nBACKUP_S3_SECRET_ACCESS_KEY=sec-456\n' >> "$BFILE"
run both "$WORK/backup"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q WARNING && bad "a warning with both keys present: $OUT" || ok "no warning with both keys present"
printf 'ACCESS_KEY_ID=kid-123\nACCESS_SECRET_KEY=sec-456\n' | cmp -s - "$WORK/both.stdin.titan-db-backup-credentials" \
  && ok "CNPG's Secret has ACCESS_KEY_ID and ACCESS_SECRET_KEY, the names the ObjectStore reads" \
  || bad "stdin of titan-db-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/both.stdin.titan-db-backup-credentials" 2>&1)"
grep -q 'create secret generic titan-db-backup-credentials -n titan-db-staging' "$WORK/both.kubectl" \
  && ok "in titan-db-staging" || bad "wrong namespace or name for titan-db-backup-credentials"
printf 'BackupTarget__AccessKeyId=kid-123\nBackupTarget__SecretAccessKey=sec-456\n' | cmp -s - "$WORK/both.stdin.control-plane-backup-credentials" \
  && ok "the control plane's Secret has the same pair under its setting names" \
  || bad "stdin of control-plane-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/both.stdin.control-plane-backup-credentials" 2>&1)"
printf 'BACKUP_S3_ACCESS_KEY_ID=kid-123\nBACKUP_S3_SECRET_ACCESS_KEY=sec-456\n' | cmp -s - "$WORK/both.stdin.incus-worker-backup-credentials" \
  && ok "the worker's Secret has the same pair under the names the worker reads" \
  || bad "stdin of incus-worker-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/both.stdin.incus-worker-backup-credentials" 2>&1)"
grep -q 'create secret generic control-plane-backup-credentials -n titan-staging' "$WORK/both.kubectl" \
  && grep -q 'create secret generic incus-worker-backup-credentials -n titan-staging' "$WORK/both.kubectl" \
  && ok "both in titan-staging" || bad "wrong namespace or name for the control plane's or the worker's backup Secret"
if grep -q -e 'kid-123' -e 'sec-456' "$WORK/both.kubectl" || printf '%s' "$OUT" | grep -q -e 'kid-123' -e 'sec-456'; then
  bad "a key value appears in a kubectl argument or in the output"
else
  ok "no key value in any kubectl argument or in the output"
fi

echo "backup keys absent"
[ ! -e "$WORK/backup0.stdin.titan-db-backup-credentials" ] && [ ! -e "$WORK/backup0.stdin.control-plane-backup-credentials" ] \
  && [ ! -e "$WORK/backup0.stdin.incus-worker-backup-credentials" ] \
  && ok "no backup Secret is applied, not even an empty one" || bad "a backup Secret was applied"
sed -i '' '/^BACKUP_S3_SECRET_ACCESS_KEY=/d' "$BFILE"
run half "$WORK/backup"
[ "$RC" -eq 0 ] && ok "exit 0: the bootstrap goes on" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q 'WARNING: BACKUP_S3_ACCESS_KEY_ID or BACKUP_S3_SECRET_ACCESS_KEY is missing' \
  && ok "a warning names the missing keys" || bad "no warning: $OUT"
[ ! -e "$WORK/half.stdin.titan-db-backup-credentials" ] && [ ! -e "$WORK/half.stdin.control-plane-backup-credentials" ] \
  && [ ! -e "$WORK/half.stdin.incus-worker-backup-credentials" ] \
  && ok "half a pair is not applied" || bad "half a pair was applied"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
