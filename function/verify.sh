#!/bin/bash
# function/verify.sh: does the function cluster of this host do what function/README.md says? One line per check,
# PASS or FAIL, exit 1 if any FAIL. No sudo. It copies `library/python:3.12-slim` from Docker Hub (anonymous, rate-limited) into
# the cluster registry as `runtime/python`, composes `fn/sample/hello` there and runs it. It leaves the namespace `fn-sample`
# (a function and its image) behind so a second run is fast; delete it with `kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml delete ns fn-sample`.
#
#   bash function/verify.sh
#
# FN_KUBECONFIG as in up.sh. TITAN_KUBECONFIG (titan-k3s's) adds one INFO line, the restart count of dev's containers, to compare
# between two runs; it is not a check.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
kubeconfig=${FN_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
kc=(kubectl --kubeconfig "$kubeconfig")
command -v kubectl >/dev/null || kc=(k3s kubectl --kubeconfig "$kubeconfig")
REGISTRY=http://127.0.0.1:5100
NS=fn-sample
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

echo "# the node, the secrets, the runtime"
check "node Ready" bash -c "[ \"\$(${kc[*]} get node -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}')\" = True ]"
# k3s's service file carries the flags (ps shows only `k3s server`); root's `k3s secrets-encrypt status --server https://127.0.0.1:6444` says the same.
check "k3s runs with --secrets-encryption" grep -q -- "'--secrets-encryption'" /etc/systemd/system/k3s.service
check "RuntimeClass kata-fc has our overhead" bash -c "[ \"\$(${kc[*]} get runtimeclass kata-fc -o jsonpath='{.overhead.podFixed.cpu}')\" != 250m ] && ${kc[*]} get runtimeclass kata-fc -o jsonpath='{.handler}' | grep -qx kata-fc"
pods=$("${kc[@]}" -n knative-serving get pods --no-headers 2>&1)
if [ -n "$pods" ] && printf '%s\n' "$pods" | awk '{split($2, r, "/"); if ($3 == "Completed") next; if ($3 != "Running" || r[1] != r[2]) bad = 1} END {exit bad}'; then pass "Knative pods Running and Ready"; else fail "Knative pods Running and Ready: $pods"; fi

echo "# a function from a composed image"
if ! curl -fsS "$REGISTRY/v2/" >/dev/null; then fail "registry answers on $REGISTRY"; else
  pass "registry answers on $REGISTRY"
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  (cd "$here/sample" && python3 copy_image.py library/python:3.12-slim "$REGISTRY" runtime/python:3.12-slim) > "$work/copy.log" 2>&1 && pass "runtime image in the registry" || { cat "$work/copy.log"; fail "runtime image in the registry"; }
  (cd "$here/sample/hello" && python3 -c "
import zipfile
with zipfile.ZipFile('$work/hello.zip', 'w') as z:
    z.write('adapter.py'); z.write('main.py')")
  (cd "$here/sample" && python3 compose_image.py --registry "$REGISTRY" --zip "$work/hello.zip" --repo fn/sample/hello --tag v1 \
      --mode composed --runtime runtime/python:3.12-slim) > "$work/compose.log" 2>&1
  digest=$(sed -n 's/^MANIFEST_DIGEST=\(sha256:[0-9a-f]*\).*/\1/p' "$work/compose.log")
  [ -n "$digest" ] && pass "image composed, runtime layers mounted across repos (201, nothing copied)" || { cat "$work/compose.log"; fail "image composed"; }
  if [ -n "$digest" ]; then
    "${kc[@]}" apply -f - >/dev/null <<Y
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: serving.knative.dev/v1
kind: Service
metadata: {name: hello, namespace: $NS}
spec:
  template:
    metadata:
      annotations: {autoscaling.knative.dev/min-scale: "0"}
    spec:
      runtimeClassName: kata-fc
      containers:
      - image: localhost:5100/fn/sample/hello@$digest
        command: ["python3", "/function/adapter.py"]
        ports: [{containerPort: 8080}]
        readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 1}
        resources: {limits: {memory: 256Mi}}
        securityContext: {runAsUser: 1000, readOnlyRootFilesystem: true}
Y
    "${kc[@]}" -n "$NS" wait ksvc/hello --for=condition=Ready --timeout=240s >/dev/null 2>&1 && pass "Knative Service Ready" || fail "Knative Service Ready"
    host=$("${kc[@]}" -n "$NS" get ksvc hello -o jsonpath='{.status.url}' | sed 's#http://##')
    kourier=$("${kc[@]}" -n kourier-system get svc kourier -o jsonpath='{.spec.clusterIP}')
    body=$(curl -fsS -m 60 -H "Host: $host" "http://$kourier/")
    case "$body" in "hello kernel="*) pass "GET answers: $body" ;; *) fail "GET answers: '$body'" ;; esac
    guest=${body#hello kernel=}
    [ -n "$guest" ] && [ "$guest" != "$(uname -r)" ] && pass "pod kernel ($guest) differs from the host's ($(uname -r))" || fail "pod kernel differs from the host's"
    pod=$("${kc[@]}" -n "$NS" get pods -l serving.knative.dev/service=hello -o jsonpath='{.items[0].metadata.name}')
    [ "$("${kc[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')" = kata-fc ] && pass "pod runs kata-fc" || fail "pod runs kata-fc"
    out=$("${kc[@]}" -n "$NS" exec "$pod" -c user-container -- sh -c 'touch /function/x' 2>&1)   # not piped into grep -q: pipefail sees its early exit
    case "$out" in *"Read-only file system"*) pass "/function is read-only" ;; *) fail "/function is read-only: '$out'" ;; esac

    echo "# scale to zero, then answer again"
    for _ in $(seq 1 60); do
      [ "$("${kc[@]}" -n "$NS" get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null | grep -c .)" = 0 ] && break
      sleep 5
    done
    [ "$("${kc[@]}" -n "$NS" get pods -l serving.knative.dev/service=hello --no-headers 2>/dev/null | grep -c .)" = 0 ] && pass "no pod left after idle" || fail "no pod left after idle"
    body=$(curl -fsS -m 60 -H "Host: $host" "http://$kourier/")
    case "$body" in "hello kernel="*) pass "cold request answered" ;; *) fail "cold request answered: '$body'" ;; esac
  fi
fi

if [ -n "${TITAN_KUBECONFIG:-}" ]; then
  echo "# dev's pods"
  restarts=$(kubectl --kubeconfig "$TITAN_KUBECONFIG" get pods -A -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')
  echo "INFO titan-k3s restarts since boot: $restarts (compare with a run before and after)"
fi
[ "$fails" -eq 0 ] && echo "VERIFY_RESULT=OK" || { echo "VERIFY_RESULT=FAIL ($fails)"; exit 1; }
