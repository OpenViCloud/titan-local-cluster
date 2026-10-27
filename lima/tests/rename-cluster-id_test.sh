#!/usr/bin/env bash
# rename-cluster-id_test.sh — lima/scripts/rename-cluster-id.sh moves dev's rows from cluster id local-mac to local.
#
# WHY this file exists: the control plane keys every resource, command and template sync state by cluster id, and the
# local cluster's id changed from local-mac to local. A running dev database still holds local-mac; until its rows move,
# the control plane finds no cluster for them. The script runs one statement, so the rows move together or not at all,
# and restarts the control plane and the worker only when something moved. It runs against a fake `kubectl`.
#
# Run:  bash lima/tests/rename-cluster-id_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/rename-cluster-id.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# kubectl --kubeconfig K --request-timeout=T VERB …: `get pod` prints $FAKE_POD, `exec … psql` saves its SQL and prints
# $FAKE_MOVED (or fails when $FAKE_EXEC_FAILS is set), `rollout restart` is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
shift 3
case "$1" in
  # Like kubectl: no match is exit 0 with a note on stderr.
  get) if [ -n "$FAKE_POD" ]; then echo "$FAKE_POD"; else echo "No resources found in titan-db-staging namespace." >&2; fi ;;
  exec)
    [ -n "${FAKE_EXEC_FAILS:-}" ] && { echo "ERROR: relation does not exist" >&2; exit 1; }
    for arg in "$@"; do last=$arg; done
    printf '%s' "$last" > "$FAKE_SQL"
    echo "$FAKE_MOVED" ;;
  rollout) ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/kubectl"

run() {
  : > "$WORK/kubectl.log"; rm -f "$WORK/sql"
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/kubectl.log" FAKE_SQL="$WORK/sql" \
    FAKE_POD="$1" FAKE_MOVED="$2" FAKE_EXEC_FAILS="${3:-}" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

echo "a fresh cluster: no titan-db yet"
run "" 0
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q ' exec ' "$WORK/kubectl.log" && bad "ran SQL without a database" || ok "no SQL"
grep -q 'rollout' "$WORK/kubectl.log" && bad "restarted something" || ok "no restart"

echo "a running cluster whose rows still say local-mac"
run "pod/titan-db-1" 7
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q 'exec -n titan-db-staging pod/titan-db-1 -c postgres -- psql -d titan' "$WORK/kubectl.log" \
  && ok "psql on the primary, database titan" || bad "exec: $(grep exec "$WORK/kubectl.log")"
grep -q 'cnpg.io/instanceRole=primary' "$WORK/kubectl.log" && ok "the pod is the primary's" || bad "pod not chosen by role"
for table in vms volumes networks load_balancers provider_commands vm_template_clusters; do
  grep -q "UPDATE core.$table SET cluster_id = 'local' WHERE cluster_id = 'local-mac'" "$WORK/sql" \
    && ok "moves core.$table" || bad "core.$table not moved"
done
grep -q "DELETE FROM core.vm_template_clusters" "$WORK/sql" && ok "drops a local-mac sync state that a local one replaced" \
  || bad "no delete of a duplicate template state"
[ "$(grep -c ';' "$WORK/sql")" -le 1 ] && ok "one statement: all rows move or none" || bad "several statements"
grep -q 'rollout restart deployment/control-plane -n titan-staging' "$WORK/kubectl.log" && ok "the control plane restarts" \
  || bad "control plane not restarted"
grep -q 'rollout restart deployment/incus-worker -n titan-staging' "$WORK/kubectl.log" && ok "the worker restarts" \
  || bad "worker not restarted"
printf '%s' "$OUT" | grep -q '7' && ok "says how many rows moved" || bad "no count: $OUT"

echo "run again: nothing left to move"
run "pod/titan-db-1" 0
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q 'rollout' "$WORK/kubectl.log" && bad "restarted for nothing" || ok "no restart"

echo "psql fails"
run "pod/titan-db-1" 0 yes
[ "$RC" -ne 0 ] && ok "stops" || bad "rc=$RC $OUT"
grep -q 'rollout' "$WORK/kubectl.log" && bad "restarted after a failure" || ok "no restart"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
