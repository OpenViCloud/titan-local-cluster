#!/usr/bin/env bash
# bootstrap-secrets_test.sh — what lima/scripts/bootstrap-secrets.sh keeps in ~/.config/titan-local-cluster/ (secrets.env,
# the S3 CA and SeaweedFS's certificate) and puts into the cluster.
#
# WHY this file exists: the script is the only place the dev cluster's secrets come from, and it must work for someone with
# no vault and no GitHub token. The values it generates once must survive a rebuild (the database restored from a backup
# holds the first password), so a second run must keep every value in the file. The script runs here against a fake
# `kubectl` and `openssl` on PATH, and an `infisical` that fails if called: the values must reach kubectl on stdin and
# nowhere else, and the Secret key names must be the ones their readers use.
#
# Run:  bash lima/tests/bootstrap-secrets_test.sh     (from the repo root; macOS bash 3.2 and python3)

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
# `rand`: a different value on each call, so the test can tell which generated value went where. Anything else (keys,
# certificates): writes a placeholder to each -out and -keyout file; the real openssl case below checks the real files.
count=$(( $(cat "$FAKE_LOG.openssl" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$FAKE_LOG.openssl"
# Files carry a count over every run of the test, so a file made again never equals the one before it.
files=$(( $(cat "$FAKE_FILES" 2>/dev/null || echo 0) + 1 ))
echo "$files" > "$FAKE_FILES"
if [ "$1" = rand ]; then
  printf 'random%s' "$count"
  exit 0
fi
previous=""
for arg in "$@"; do
  case "$previous" in -out|-keyout) printf 'pem%s\n' "$files" > "$arg" ;; esac
  previous=$arg
done
FAKE
chmod +x "$WORK/bin/"*
export FAKE_FILES="$WORK/openssl-files"

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

KEYS="TITAN_DB_PASSWORD INTERNAL_TOKEN KEYCLOAK_ADMIN_PASSWORD BETA_USER_PASSWORD BETA_USER_2_PASSWORD
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY"

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
printf 'username=titan\npassword=%s\n' "$db" | cmp -s - "$WORK/fresh.stdin.titan-db-credentials" \
  && ok "the database's Secret carries the file's password" || bad "titan-db-credentials differs from the file"
grep -q "Password=$db\$" "$WORK/fresh.stdin.control-plane-db" \
  && ok "the control plane's connection string carries the same password" || bad "control-plane-db differs from the file"
printf 'Internal__Token=%s\n' "$token" | cmp -s - "$WORK/fresh.stdin.control-plane-secrets" \
  && ok "the control plane gets the file's internal token, and no cluster key" || bad "control-plane-secrets differs from the file"
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
grep -q 'create secret generic ghcr-credentials -n titan-dev --type=kubernetes.io/dockerconfigjson' "$WORK/fresh.kubectl" \
  && ok "as a dockerconfigjson Secret in titan-dev" || bad "wrong type, name or namespace for ghcr-credentials"
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
printf 'TITAN_DB_PASSWORD_BEFORE_ROTATION=not-this\nTITAN_DB_PASSWORD=kept-db\nBETA_USER_PASSWORD=kept/pw+b64=\n' > "$OLD"
chmod 644 "$OLD"
chmod 755 "$(dirname "$OLD")"
run old "$WORK/old" FAKE_EMPTY_CLUSTER=1
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ "$(value "$OLD" TITAN_DB_PASSWORD)" = "kept-db" ] && [ "$(value "$OLD" BETA_USER_PASSWORD)" = "kept/pw+b64=" ] \
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
grep -q 'password=kept/pw+b64=$' "$WORK/old.stdin.beta-user-credentials" \
  && ok "a value with / + = reaches the Secret unchanged" || bad "beta-user-credentials lost the kept password"

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
grep -q 'create secret generic admin-test-credentials -n titan-auth-dev' "$WORK/running.kubectl" \
  && ok "in titan-auth-dev, where Keycloak's realm import reads it" || bad "wrong namespace or name for admin-test-credentials"

echo "the S3 key pair, generated once"
kid=$(value "$FILE" BACKUP_S3_ACCESS_KEY_ID)
sec=$(value "$FILE" BACKUP_S3_SECRET_ACCESS_KEY)
printf 'ACCESS_KEY_ID=%s\nACCESS_SECRET_KEY=%s\n' "$kid" "$sec" | cmp -s - "$WORK/fresh.stdin.titan-db-backup-credentials" \
  && ok "CNPG's Secret has ACCESS_KEY_ID and ACCESS_SECRET_KEY, the names the ObjectStore reads" \
  || bad "stdin of titan-db-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/fresh.stdin.titan-db-backup-credentials" 2>&1)"
grep -q 'create secret generic titan-db-backup-credentials -n titan-db-dev' "$WORK/fresh.kubectl" \
  && ok "in titan-db-dev" || bad "wrong namespace or name for titan-db-backup-credentials"
printf 'BackupTarget__AccessKeyId=%s\nBackupTarget__SecretAccessKey=%s\n' "$kid" "$sec" | cmp -s - "$WORK/fresh.stdin.control-plane-backup-credentials" \
  && ok "the control plane's Secret has the same pair under its setting names" \
  || bad "stdin of control-plane-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/fresh.stdin.control-plane-backup-credentials" 2>&1)"
printf 'BACKUP_S3_ACCESS_KEY_ID=%s\nBACKUP_S3_SECRET_ACCESS_KEY=%s\n' "$kid" "$sec" | cmp -s - "$WORK/fresh.stdin.incus-worker-backup-credentials" \
  && ok "the worker's Secret has the same pair under the names the worker reads" \
  || bad "stdin of incus-worker-backup-credentials was: $(sed 's/=.*/=<value>/' "$WORK/fresh.stdin.incus-worker-backup-credentials" 2>&1)"
grep -q 'create secret generic control-plane-backup-credentials -n titan-dev' "$WORK/fresh.kubectl" \
  && grep -q 'create secret generic incus-worker-backup-credentials -n titan-dev' "$WORK/fresh.kubectl" \
  && ok "both in titan-dev" || bad "wrong namespace or name for the control plane's or the worker's backup Secret"
python3 - "$WORK/fresh.stdin.seaweedfs-s3-config" "$kid" "$sec" <<'PY' && ok "SeaweedFS's S3 identity has the same pair" || bad "seaweedfs-s3-config does not carry the pair"
import json, sys
config = json.load(open(sys.argv[1]))
credentials = [c for identity in config["identities"] for c in identity["credentials"]]
assert credentials == [{"accessKey": sys.argv[2], "secretKey": sys.argv[3]}], credentials
assert config["identities"][0]["actions"] == ["Read", "Write", "List", "Tagging"], config
PY
grep -q 'create secret generic seaweedfs-s3-config -n seaweedfs' "$WORK/fresh.kubectl" \
  && ok "in namespace seaweedfs" || bad "wrong namespace or name for seaweedfs-s3-config"
if grep -q -e "$kid" -e "$sec" "$WORK/fresh.kubectl" || printf '%s' "$OUT" | grep -q -e "$kid" -e "$sec"; then
  bad "a key value appears in a kubectl argument or in the output"
else
  ok "no key value in any kubectl argument or in the output"
fi
printf '%s' "$OUT" | grep -q WARNING && bad "a warning on a normal run: $OUT" || ok "no warning"

echo "the S3 CA and SeaweedFS's certificate, made once on the Mac"
DIR="$WORK/fresh/.config/titan-local-cluster"
for name in s3-ca.crt s3-ca.key s3.crt s3.key; do
  [ -s "$DIR/$name" ] || bad "no $name"
done
[ "$(stat -f '%Lp' "$DIR/s3-ca.key")" = "600" ] && [ "$(stat -f '%Lp' "$DIR/s3.key")" = "600" ] \
  && ok "both private keys are mode 600" || bad "key modes $(stat -f '%Lp' "$DIR/s3-ca.key" "$DIR/s3.key" 2>&1)"
grep -q "create secret tls seaweedfs-tls -n seaweedfs --cert=$DIR/s3.crt --key=$DIR/s3.key" "$WORK/fresh.kubectl" \
  && ok "SeaweedFS gets its certificate and key as seaweedfs/seaweedfs-tls" || bad "no seaweedfs-tls from the two files"
grep -q "create secret generic s3-ca -n titan-db-dev --from-file=ca.crt=$DIR/s3-ca.crt" "$WORK/fresh.kubectl" \
  && grep -q "create secret generic s3-ca -n titan-dev --from-file=ca.crt=$DIR/s3-ca.crt" "$WORK/fresh.kubectl" \
  && ok "the CA certificate goes to titan-db-dev (barman) and titan-dev (control plane, worker)" \
  || bad "s3-ca missing in titan-db-dev or titan-dev"
grep -q "s3-ca.key" "$WORK/fresh.kubectl" && bad "the CA's private key reached kubectl" || ok "the CA's private key never reaches the cluster"
for name in s3-ca.crt s3-ca.key s3.crt s3.key; do cp "$DIR/$name" "$WORK/first-$name"; done
run certs-again "$WORK/fresh"
same=yes
for name in s3-ca.crt s3-ca.key s3.crt s3.key; do cmp -s "$DIR/$name" "$WORK/first-$name" || same=no; done
[ "$same" = yes ] && ok "a second run keeps the CA and the certificate" || bad "a second run changed the CA or the certificate"
rm "$DIR/s3.crt"
run cert-missing "$WORK/fresh"
cmp -s "$DIR/s3-ca.crt" "$WORK/first-s3-ca.crt" && [ -s "$DIR/s3.crt" ] \
  && ok "a missing certificate is made again from the same CA" || bad "the CA changed, or no new certificate"
cp "$DIR/s3.crt" "$WORK/second-s3.crt"
rm "$DIR/s3-ca.key"
run ca-missing "$WORK/fresh"
! cmp -s "$DIR/s3-ca.crt" "$WORK/first-s3-ca.crt" && ! cmp -s "$DIR/s3.crt" "$WORK/second-s3.crt" \
  && ok "a new CA signs a new certificate: the old one would not verify against it" || bad "the certificate outlived its CA"
chmod 644 "$DIR/s3-ca.key" "$DIR/s3.key"
run key-modes "$WORK/fresh"
[ "$(stat -f '%Lp' "$DIR/s3-ca.key")" = "600" ] && [ "$(stat -f '%Lp' "$DIR/s3.key")" = "600" ] \
  && ok "keys left readable by others are set back to mode 600" || bad "key modes $(stat -f '%Lp' "$DIR/s3-ca.key" "$DIR/s3.key")"

for real in /opt/homebrew/bin/openssl /usr/bin/openssl; do
  [ -x "$real" ] || continue
  echo "real $("$real" version)"
  case_name=real-$(basename "$(dirname "$(dirname "$real")")")
  mkdir -p "$WORK/$case_name/bin" "$WORK/$case_name/home"
  ln -s "$WORK/bin/kubectl" "$WORK/$case_name/bin/kubectl"
  ln -s "$real" "$WORK/$case_name/bin/openssl"
  FAKE_LOG="$WORK/$case_name/log"
  OUT=$(env HOME="$WORK/$case_name/home" PATH="$WORK/$case_name/bin:/usr/bin:/bin" FAKE_LOG="$FAKE_LOG" FAKE_EMPTY_CLUSTER=1 \
    bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
  RDIR="$WORK/$case_name/home/.config/titan-local-cluster"
  [ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
  "$real" verify -CAfile "$RDIR/s3-ca.crt" "$RDIR/s3.crt" > /dev/null 2>&1 \
    && ok "the certificate verifies against the CA" || bad "$("$real" verify -CAfile "$RDIR/s3-ca.crt" "$RDIR/s3.crt" 2>&1)"
  text=$("$real" x509 -in "$RDIR/s3.crt" -noout -text 2>&1)
  ca_text=$("$real" x509 -in "$RDIR/s3-ca.crt" -noout -text 2>&1)
  printf '%s' "$text" | grep -q 'DNS:lima-titan-k3s.internal' && ok "its name is lima-titan-k3s.internal" || bad "SAN: $text"
  printf '%s' "$text" | grep -q 'TLS Web Server Authentication' && ok "it is a server certificate" || bad "no serverAuth"
  printf '%s' "$ca_text" | grep -q 'CA:TRUE' && ok "the CA says CA:TRUE" || bad "CA basic constraints: $ca_text"
  printf '%s' "$text" | grep -q 'CA:TRUE' && bad "the server certificate is a CA" || ok "the server certificate is not a CA"
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
