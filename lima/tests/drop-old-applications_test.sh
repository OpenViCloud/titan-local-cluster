#!/usr/bin/env bash
# drop-old-applications_test.sh — lima/scripts/drop-old-applications.sh removes the Applications of the old names.
#
# WHY this file exists: the Applications were renamed from *-local-mac to *-local (and root-local-mac to root-local). The
# old root lists itself, so it may not prune itself, and two roots with prune and selfHeal would fight over the same
# children. The script deletes every old Application that still exists, only by name, and only when none of them has a
# finalizer: without one, deleting an Application leaves its resources to the new Application. It runs against a fake
# `kubectl`.
#
# Run:  bash lima/tests/drop-old-applications_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/drop-old-applications.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# kubectl --kubeconfig K --request-timeout=T VERB …: `get applications.argoproj.io -o json` prints $FAKE_APPS, `delete` is logged.
printf '%s\n' "$*" >> "$FAKE_LOG"
shift 3
case "$1" in
  get) cat "$FAKE_APPS" ;;
  delete) ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/kubectl"

apps() {  # apps NAME[:finalizer] ...
  python3 -c '
import json, sys
items = []
for arg in sys.argv[1:]:
    name, _, fin = arg.partition(":")
    meta = {"name": name, "namespace": "argocd"}
    if fin:
        meta["finalizers"] = [fin]
    items.append({"metadata": meta})
print(json.dumps({"items": items}))' "$@" > "$WORK/apps.json"
}

run() {
  : > "$WORK/kubectl.log"
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/kubectl.log" FAKE_APPS="$WORK/apps.json" \
    bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

echo "a cluster with both the old and the new names"
apps root-local-mac titan-db-local-mac keycloak-local-mac root-local titan-db-local cnpg-operator seaweedfs
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q 'delete applications.argoproj.io -n argocd --wait=false root-local-mac titan-db-local-mac keycloak-local-mac$' \
  "$WORK/kubectl.log" && ok "deletes the three old Applications, by name, in one call" || bad "delete: $(grep delete "$WORK/kubectl.log")"
grep 'delete' "$WORK/kubectl.log" | grep -qE ' (root-local|titan-db-local|cnpg-operator|seaweedfs)( |$)' \
  && bad "deleted a current Application" || ok "keeps every current Application"

echo "nothing old left"
apps root-local titan-db-local cnpg-operator
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q 'delete' "$WORK/kubectl.log" && bad "deleted something" || ok "deletes nothing"

echo "an old Application with a finalizer"
apps root-local-mac titan-db-local-mac:resources-finalizer.argocd.argoproj.io root-local
run
[ "$RC" -ne 0 ] && ok "stops" || bad "rc=$RC $OUT"
grep -q 'delete' "$WORK/kubectl.log" && bad "deleted although a delete would cascade" || ok "deletes nothing"
printf '%s' "$OUT" | grep -q 'titan-db-local-mac' && ok "names the Application" || bad "no name: $OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
