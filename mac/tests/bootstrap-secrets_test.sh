#!/usr/bin/env bash
# bootstrap-secrets_test.sh — the dev backup key pair and the fixed admin-test password that mac/scripts/bootstrap-secrets.sh
# puts into the cluster.
#
# WHY this file exists: the script is the only way the dev Secret titan-db-backup-credentials gets its two keys, and a wrong
# key name or a missing key only shows when CNPG cannot archive WAL. The script runs here against a fake `infisical`,
# `kubectl` and `openssl` on PATH: the values must reach kubectl on stdin and nowhere else, the names must be the ones
# the ObjectStore reads, missing backup keys must skip the Secret with a warning without stopping the rest, and a missing
# GitHub token must still stop the script.
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
# infisical secrets get NAME ... --path=FOLDER: the value comes from FAKE_<NAME>, empty when unset.
name=$3
for arg in "$@"; do
  case "$arg" in --path=*) path=${arg#--path=} ;; esac
done
printf '%s %s\n' "$name" "$path" >> "$FAKE_LOG.infisical"
# FAKE_INFISICAL_FAIL=1: not logged in. The real CLI then exits 1 with a login prompt on STDOUT.
if [ -n "${FAKE_INFISICAL_FAIL-}" ]; then
  printf 'Select your hosting option: junk-that-must-never-be-applied'
  exit 1
fi
var="FAKE_$name"
printf '%s' "${!var-}"
FAKE
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# Records every call; `create secret generic NAME` keeps what came on stdin; `get secret` finds the internal ones.
printf '%s\n' "$*" >> "$FAKE_LOG.kubectl"
case "$*" in
  *"create secret generic"*)
    name=$(printf '%s\n' "$*" | sed -E 's/.*create secret generic ([^ ]+).*/\1/')
    cat > "$FAKE_LOG.stdin.$name" ;;
  *"get secret"*) exit 0 ;;
  *) cat > /dev/null ;;
esac
exit 0
FAKE
cat > "$WORK/bin/openssl" <<'FAKE'
#!/bin/bash
printf 'fixedrandom'
FAKE
chmod +x "$WORK/bin/"*

# run NAME VAR=value ...: runs the script with those Infisical values; sets RC, OUT (stderr+stdout) and FAKE_LOG.
run() {
  local case_name=$1
  shift
  FAKE_LOG="$WORK/$case_name"
  export FAKE_LOG
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_LOG="$FAKE_LOG" "$@" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}
mkdir -p "$WORK/home"

TOKENS=(FAKE_ARGOCD_GITHUB_PAT=argocd-token-value FAKE_GHCR_PAT=ghcr-token-value)

echo "both backup keys present"
run both "${TOKENS[@]}" FAKE_BACKUP_DEV_ACCESS_KEY_ID=kid-123 FAKE_BACKUP_DEV_SECRET_ACCESS_KEY=sec-456
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
printf 'ACCESS_KEY_ID=kid-123\nACCESS_SECRET_KEY=sec-456\n' | cmp -s - "$WORK/both.stdin.titan-db-backup-credentials" \
  && ok "kubectl got ACCESS_KEY_ID and ACCESS_SECRET_KEY on stdin, the names the ObjectStore reads" \
  || bad "stdin of the backup Secret was: $(cat "$WORK/both.stdin.titan-db-backup-credentials" 2>&1 | sed 's/=.*/=<value>/')"
printf 'BackupTarget__AccessKeyId=kid-123\nBackupTarget__SecretAccessKey=sec-456\n' | cmp -s - "$WORK/both.stdin.control-plane-backup-credentials" \
  && ok "the control plane's Secret carries the same pair under the names its config reads" \
  || bad "stdin of the control plane's backup Secret was: $(cat "$WORK/both.stdin.control-plane-backup-credentials" 2>&1 | sed 's/=.*/=<value>/')"
grep -q 'create secret generic control-plane-backup-credentials -n titan-staging' "$WORK/both.kubectl" \
  && ok "that Secret is made in titan-staging, where the control plane runs" || bad "wrong namespace or name for the control plane's Secret"
grep -q 'titan-db-staging' "$WORK/both.kubectl" && grep -q 'create secret generic titan-db-backup-credentials -n titan-db-staging' "$WORK/both.kubectl" \
  && ok "the Secret is made in titan-db-staging" || bad "wrong namespace or name"
if grep -q -e 'kid-123' -e 'sec-456' "$WORK/both.kubectl" || printf '%s' "$OUT" | grep -q -e 'kid-123' -e 'sec-456'; then
  bad "a key value appears in a kubectl argument or in the output"
else
  ok "no key value in any kubectl argument or in the output"
fi
grep -q '^BACKUP_DEV_ACCESS_KEY_ID /infra$' "$WORK/both.infisical" && grep -q '^BACKUP_DEV_SECRET_ACCESS_KEY /infra$' "$WORK/both.infisical" \
  && ok "both keys are read from folder /infra" || bad "wrong Infisical folder: $(cat "$WORK/both.infisical")"
grep -q '^ARGOCD_GITHUB_PAT /secret$' "$WORK/both.infisical" && ok "the GitHub tokens still come from /secret" || bad "token folder changed"
printf 'password=admin-test-local-only\n' | cmp -s - "$WORK/both.stdin.admin-test-credentials" \
  && ok "admin-test gets its fixed test password on a cluster that already has its internal secrets" \
  || bad "stdin of admin-test-credentials was: $(cat "$WORK/both.stdin.admin-test-credentials" 2>&1)"
grep -q 'create secret generic admin-test-credentials -n titan-auth-staging' "$WORK/both.kubectl" \
  && ok "in titan-auth-staging, where Keycloak's realm import reads it" || bad "wrong namespace or name for admin-test-credentials"
[ ! -e "$WORK/both.stdin.beta-user-credentials" ] \
  && ok "beta-user keeps its generated password (not re-applied)" || bad "beta-user-credentials was re-applied"

echo "backup keys absent"
run absent "${TOKENS[@]}"
[ "$RC" -eq 0 ] && ok "exit 0: the bootstrap goes on" || bad "exit $RC: $OUT"
printf '%s' "$OUT" | grep -q 'WARNING: BACKUP_DEV_ACCESS_KEY_ID or BACKUP_DEV_SECRET_ACCESS_KEY is missing' \
  && ok "a warning names the missing keys" || bad "no warning: $OUT"
[ ! -e "$WORK/absent.stdin.titan-db-backup-credentials" ] && [ ! -e "$WORK/absent.stdin.control-plane-backup-credentials" ] \
  && ok "no backup Secret is applied, not even an empty one" || bad "a backup Secret was applied"
printf '%s' "$OUT" | grep -q 'internal secrets already exist; kept' \
  && ok "the script ran on past the warning to its end" || bad "the script stopped at the warning: $OUT"

echo "one backup key absent"
run half "${TOKENS[@]}" FAKE_BACKUP_DEV_ACCESS_KEY_ID=kid-123
[ "$RC" -eq 0 ] && [ ! -e "$WORK/half.stdin.titan-db-backup-credentials" ] && [ ! -e "$WORK/half.stdin.control-plane-backup-credentials" ] \
  && ok "half a pair is not applied" || bad "half a pair was applied or the script stopped: rc=$RC"

echo "a GitHub token absent"
run notoken FAKE_GHCR_PAT=ghcr-token-value
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'ARGOCD_GITHUB_PAT is missing' \
  && ok "the script still stops, naming the token" || bad "rc=$RC $OUT"

echo "Infisical itself failing (not logged in)"
run loggedout FAKE_INFISICAL_FAIL=1
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "run 'infisical login'" \
  && ok "the script stops and says to log in" || bad "rc=$RC $OUT"
if ls "$WORK"/loggedout.stdin.* > /dev/null 2>&1; then
  bad "a Secret was applied from a failed Infisical call"
else
  ok "no Secret was applied, so the login prompt text is never a token or a key"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
