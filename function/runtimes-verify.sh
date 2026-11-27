#!/bin/bash
# function/runtimes-verify.sh: do the runtime images of OVC Function (OpenViCloud/titan-function-runtimes) run a customer's
# function on this host's function cluster? For each of python3.15, nodejs26 and go: copy the image CI published to GHCR into
# the cluster registry, compose a function image from the sample zip of function/sample/runtimes/<language>/ (the runtime's
# layers mounted across repositories, one layer of code under function/), and run it as a Knative Service (the HTTP template of
# titan-ops features/ovc-function/design.md#k8s-templates) and as a CronJob (the cron template) on kata-fc pods.
# One line per check, PASS or FAIL, exit 1 if any FAIL. No sudo.
#
#   bash function/runtimes-verify.sh <commit sha of titan-function-runtimes that CI pushed>
#
# Needs: the cluster up (function/verify.sh), `go` on PATH (the go sample is built against the public library at that sha,
# as a customer would), network to ghcr.io and github.com. It leaves namespace `fn-runtimes` behind so a second run is fast;
# delete it with `kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml delete ns fn-runtimes`.
# FN_KUBECONFIG as in up.sh. RUNTIMES_SOURCE overrides the GHCR path (default ghcr.io/openvicloud/titan-function-runtimes).
set -uo pipefail

sha=${1:?usage: runtimes-verify.sh <commit sha of titan-function-runtimes>}
here=$(cd "$(dirname "$0")" && pwd)
kubeconfig=${FN_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
kc=(kubectl --kubeconfig "$kubeconfig")
command -v kubectl >/dev/null || kc=(k3s kubectl --kubeconfig "$kubeconfig")
SOURCE=${RUNTIMES_SOURCE:-ghcr.io/openvicloud/titan-function-runtimes}
REGISTRY=http://127.0.0.1:5100
NS=fn-runtimes
RUNTIMES="python3.15:python:main.handler nodejs26:node:index.handler go:go:bootstrap"
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

echo "cluster: $("${kc[@]}" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"
grep -Eq "server:[[:space:]]*['\"]?https://127\.0\.0\.1:6444" "$kubeconfig" || { echo "ERROR: $kubeconfig is not the function cluster" >&2; exit 1; }
curl -fsS "$REGISTRY/v2/" >/dev/null || { echo "ERROR: registry $REGISTRY does not answer" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
"${kc[@]}" create namespace "$NS" --dry-run=client -o yaml | "${kc[@]}" apply -f - >/dev/null

# the pod of one function, as the design's templates have it (labels, env, probe, security context); $1 trigger, $2 image, $3 handler
podspec() {
  cat <<Y
          runtimeClassName: kata-fc
          enableServiceLinks: false
          automountServiceAccountToken: false
          containers:
          - name: function
            image: $2
            imagePullPolicy: IfNotPresent
            env:
            - {name: TITAN_HANDLER, value: "$3"}
            - {name: TITAN_TRIGGER, value: "$1"}
            - {name: TITAN_FUNCTION_ID, value: "f-sample"}
            - {name: TITAN_VERSION_ID, value: "v-sample"}
            - {name: TITAN_TIMEOUT_SECONDS, value: "30"}
            - {name: TITAN_SCHEDULE, value: "* * * * *"}
            - {name: SAMPLE_CRON, value: "${SAMPLE_CRON:-}"}
            resources:
              requests: {memory: 256Mi, cpu: 250m}
              limits: {memory: 256Mi, cpu: "1"}
            securityContext:
              runAsNonRoot: true
              runAsUser: 1000
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: {drop: [ALL]}
            volumeMounts:
            - {name: tmp, mountPath: /tmp}
          volumes:
          - {name: tmp, emptyDir: {}}
Y
}

declare -A DIGEST HOSTS
kourier=$("${kc[@]}" -n kourier-system get svc kourier -o jsonpath='{.spec.clusterIP}')

echo "# images: GHCR -> the cluster registry -> a composed function image"
for entry in $RUNTIMES; do
  IFS=: read -r name lang handler <<<"$entry"
  if (cd "$here/sample" && python3 copy_image.py "$SOURCE/$name:$sha" "$REGISTRY" "runtime/$name:$sha") > "$work/copy-$lang.log" 2>&1; then
    pass "$name: image from GHCR in the registry ($(sed -n 's/^COPIED .* manifest=\(sha256:[0-9a-f]\{12\}\).*mediaType=\(.*\)$/\1 \2/p' "$work/copy-$lang.log"))"
  else
    cat "$work/copy-$lang.log"; fail "$name: image from GHCR in the registry"; continue
  fi
  cfg=$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$REGISTRY/v2/runtime/$name/manifests/$sha" | python3 -c "import json,sys; print(json.load(sys.stdin)['config']['digest'])")
  curl -fsS "$REGISTRY/v2/runtime/$name/blobs/$cfg" | python3 -c "
import json, sys
c = json.load(sys.stdin)
ok = c['os'] == 'linux' and c['architecture'] == 'amd64' and c['config'].get('User') == '1000:1000'
sys.exit(0 if ok else 1)" && pass "$name: linux/amd64, User 1000:1000, one manifest" || fail "$name: linux/amd64, User 1000:1000, one manifest"

  # the sample zip
  case "$lang" in
    go)
      mkdir -p "$work/gosrc" && cp "$here/sample/runtimes/go/main.go" "$work/gosrc/main.go"
      (cd "$work/gosrc" && { [ -f go.mod ] || go mod init sample >/dev/null 2>&1; } &&
        GOFLAGS=-mod=mod GOPROXY=direct GONOSUMDB='github.com/OpenViCloud/*' go get "github.com/OpenViCloud/titan-function-runtimes@$sha" >/dev/null 2>&1 &&
        GOFLAGS=-mod=mod GOPROXY=direct GONOSUMDB='github.com/OpenViCloud/*' CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o bootstrap . ) &&
        python3 - "$work/go.zip" "$work/gosrc/bootstrap" <<'P' || { fail "$name: sample built against the public library at $sha"; continue; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "bootstrap")
P
      pass "$name: sample built against the public library at $sha, static linux/amd64 bootstrap" ;;
    python) (cd "$here/sample/runtimes/python" && python3 -c "
import zipfile
with zipfile.ZipFile('$work/python.zip', 'w') as z:
    z.write('main.py')") ;;
    node) (cd "$here/sample/runtimes/node" && python3 -c "
import zipfile
with zipfile.ZipFile('$work/node.zip', 'w') as z:
    z.write('index.mjs')") ;;
  esac
  (cd "$here/sample" && python3 compose_image.py --registry "$REGISTRY" --zip "$work/$lang.zip" --repo "fn/runtimes/$lang" --tag "$sha" \
      --mode composed --runtime "runtime/$name:$sha") > "$work/compose-$lang.log" 2>&1
  digest=$(sed -n 's/^MANIFEST_DIGEST=\(sha256:[0-9a-f]*\).*/\1/p' "$work/compose-$lang.log")
  if [ -n "$digest" ]; then DIGEST[$lang]=$digest; pass "$name: function image composed (runtime layers mounted across repos)"; else cat "$work/compose-$lang.log"; fail "$name: function image composed"; fi
done

echo "# cron: a CronJob every minute, and a Job whose function throws (both pods start now; read below)"
for entry in $RUNTIMES; do
  IFS=: read -r name lang handler <<<"$entry"
  [ -n "${DIGEST[$lang]:-}" ] || continue
  img="localhost:5100/fn/runtimes/$lang@${DIGEST[$lang]}"
  "${kc[@]}" -n "$NS" delete cronjob "fn-$lang-cron" job "fn-$lang-cronfail" --ignore-not-found >/dev/null
  {
    cat <<Y
apiVersion: batch/v1
kind: CronJob
metadata: {name: fn-$lang-cron, namespace: $NS}
spec:
  schedule: "* * * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 60
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      activeDeadlineSeconds: 120
      ttlSecondsAfterFinished: 300
      template:
        metadata:
          labels: {titan/function-id: f-sample, titan/version-id: v-sample}
        spec:
          restartPolicy: Never
          terminationGracePeriodSeconds: 10
Y
    podspec cron "$img" "$handler"
    cat <<Y
---
apiVersion: batch/v1
kind: Job
metadata: {name: fn-$lang-cronfail, namespace: $NS}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
Y
    SAMPLE_CRON=fail podspec cron "$img" "$handler" | sed 's/^    //'   # a Job's pod spec sits one level higher than a CronJob's
  } | "${kc[@]}" apply -f - >/dev/null || fail "$name: CronJob and Job applied"
done

echo "# HTTP: a Knative Service per runtime"
for entry in $RUNTIMES; do
  IFS=: read -r name lang handler <<<"$entry"
  [ -n "${DIGEST[$lang]:-}" ] || continue
  img="localhost:5100/fn/runtimes/$lang@${DIGEST[$lang]}"
  # the Knative template has the pod spec one level up from a Job's: render it by hand rather than re-indenting text
  python3 - "$lang" "$img" "$handler" "$NS" > "$work/ksvc-$lang.yaml" <<'P'
import json, sys
lang, img, handler, ns = sys.argv[1:5]
svc = {
  "apiVersion": "serving.knative.dev/v1", "kind": "Service", "metadata": {"name": f"fn-{lang}", "namespace": ns},
  "spec": {"template": {
    "metadata": {"labels": {"titan/function-id": "f-sample", "titan/version-id": "v-sample"},
                 "annotations": {"autoscaling.knative.dev/min-scale": "0", "autoscaling.knative.dev/max-scale": "1"}},
    "spec": {
      "runtimeClassName": "kata-fc", "containerConcurrency": 1, "timeoutSeconds": 30,
      "enableServiceLinks": False, "automountServiceAccountToken": False,
      "containers": [{
        "image": img, "imagePullPolicy": "IfNotPresent",
        "env": [{"name": "TITAN_HANDLER", "value": handler}, {"name": "TITAN_TRIGGER", "value": "http"},
                {"name": "TITAN_FUNCTION_ID", "value": "f-sample"}, {"name": "TITAN_VERSION_ID", "value": "v-sample"},
                {"name": "TITAN_TIMEOUT_SECONDS", "value": "30"}],
        "readinessProbe": {"tcpSocket": {}, "periodSeconds": 1},
        "resources": {"requests": {"memory": "256Mi", "cpu": "250m"}, "limits": {"memory": "256Mi", "cpu": "1"}},
        "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]}],
      "volumes": [{"name": "tmp", "emptyDir": {}}]}}}}
print(json.dumps(svc))
P
  "${kc[@]}" apply -f "$work/ksvc-$lang.yaml" >/dev/null 2>"$work/apply-$lang.log" || { cat "$work/apply-$lang.log"; fail "$name: Knative Service applied (the design's template)"; continue; }
  "${kc[@]}" -n "$NS" wait "ksvc/fn-$lang" --for=condition=Ready --timeout=240s >/dev/null 2>&1 && pass "$name: Knative Service Ready" || { fail "$name: Knative Service Ready"; continue; }
  host=$("${kc[@]}" -n "$NS" get ksvc "fn-$lang" -o jsonpath='{.status.url}' | sed 's#http://##')
  out=$(curl -sS -m 60 -D "$work/h-$lang" -H "Host: $host" -H 'X-Request-Id: r-1' "http://$kourier/some/path?x=1")
  status=$(head -1 "$work/h-$lang" | awk '{print $2}')
  [ "$status" = 201 ] && grep -qi "^x-runtime: $lang" "$work/h-$lang" && pass "$name: statusCode 201 and header x-runtime come back" || fail "$name: statusCode 201 and header x-runtime come back (status $status)"
  case "$out" in "hello $lang kernel="*) pass "$name: body: $out" ;; *) fail "$name: body: '$out'" ;; esac
  guest=$(sed -n 's/.* kernel=\([^ ]*\) .*/\1/p' <<<"$out")
  [ -n "$guest" ] && [ "$guest" != "$(uname -r)" ] && pass "$name: pod kernel ($guest) differs from the host's" || fail "$name: pod kernel differs from the host's"
  case "$out" in *" uid=1000 "*) pass "$name: runs as uid 1000" ;; *) fail "$name: runs as uid 1000" ;; esac
  case "$out" in *" fnwrite=denied tmpwrite=ok "*) pass "$name: /function is read-only, /tmp is writable" ;; *) fail "$name: /function is read-only, /tmp is writable" ;; esac
  case "$out" in *" path=/some/path fn=f-sample version=v-sample left="[0-9]*) pass "$name: event path and context (function id, version, time left) arrive" ;; *) fail "$name: event path and context arrive" ;; esac
  pod=$("${kc[@]}" -n "$NS" get pods -l "serving.knative.dev/service=fn-$lang" -o jsonpath='{.items[0].metadata.name}')
  [ "$("${kc[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.runtimeClassName}')" = kata-fc ] && pass "$name: pod runs kata-fc" || fail "$name: pod runs kata-fc"
  err=$(curl -sS -m 60 -o "$work/b-$lang" -w '%{http_code}' -H "Host: $host" "http://$kourier/fail")
  [ "$err" = 500 ] && [ "$(cat "$work/b-$lang")" = "Internal Server Error" ] && pass "$name: a throwing function is a generic 500" || fail "$name: a throwing function is a generic 500 ($err)"
  "${kc[@]}" -n "$NS" logs "$pod" -c user-container 2>/dev/null | grep -q "sample failure" && pass "$name: the error is in the pod log" || fail "$name: the error is in the pod log"
done

echo "# scale to zero, then answer again"
for entry in $RUNTIMES; do
  IFS=: read -r name lang handler <<<"$entry"
  [ -n "${DIGEST[$lang]:-}" ] || continue
  for _ in $(seq 1 60); do
    [ "$("${kc[@]}" -n "$NS" get pods -l "serving.knative.dev/service=fn-$lang" --no-headers 2>/dev/null | grep -c .)" = 0 ] && break
    sleep 5
  done
  [ "$("${kc[@]}" -n "$NS" get pods -l "serving.knative.dev/service=fn-$lang" --no-headers 2>/dev/null | grep -c .)" = 0 ] && pass "$name: no pod left after idle (the adapter ended on SIGTERM)" || fail "$name: no pod left after idle"
  host=$("${kc[@]}" -n "$NS" get ksvc "fn-$lang" -o jsonpath='{.status.url}' | sed 's#http://##')
  out=$(curl -sS -m 60 -H "Host: $host" "http://$kourier/")
  case "$out" in "hello $lang kernel="*) pass "$name: cold request answered" ;; *) fail "$name: cold request answered: '$out'" ;; esac
done

echo "# cron results"
for entry in $RUNTIMES; do
  IFS=: read -r name lang handler <<<"$entry"
  [ -n "${DIGEST[$lang]:-}" ] || continue
  ok=""
  for _ in $(seq 1 40); do
    job=$("${kc[@]}" -n "$NS" get jobs -o json | python3 -c "
import json, sys
for j in json.load(sys.stdin)['items']:
    if j['metadata']['name'].startswith('fn-$lang-cron-') and j.get('status', {}).get('succeeded') == 1:
        print(j['metadata']['name']); break")
    [ -n "$job" ] && { ok=$job; break; }
    sleep 5
  done
  if [ -n "$ok" ]; then
    pod=$("${kc[@]}" -n "$NS" get pods -l "job-name=$ok" -o jsonpath='{.items[0].metadata.name}')
    log=$("${kc[@]}" -n "$NS" logs "$pod" -c function 2>&1)
    n=$(grep -c '^CRON-EVENT ' <<<"$log")
    ev=$(grep '^CRON-EVENT ' <<<"$log" | head -1 | sed 's/^CRON-EVENT //')
    [ "$n" = 1 ] && python3 -c "
import json, re, sys
e = json.loads(sys.argv[1])
sys.exit(0 if sorted(e) == ['schedule', 'scheduledTime', 'trigger'] and e['trigger'] == 'cron' and e['schedule'] == '* * * * *'
          and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:00Z', e['scheduledTime']) else 1)" "$ev" \
      && pass "$name: the CronJob ran the function once with the cron event, and the Job completed" || fail "$name: the CronJob ran once with the cron event ($n lines: $log)"
  else
    fail "$name: the CronJob completed a Job within 200 s"
  fi
  "${kc[@]}" -n "$NS" wait job "fn-$lang-cronfail" --for=condition=Failed --timeout=150s >/dev/null 2>&1 && pass "$name: a throwing cron function fails the Job" || fail "$name: a throwing cron function fails the Job"
  pod=$("${kc[@]}" -n "$NS" get pods -l "job-name=fn-$lang-cronfail" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  code=$("${kc[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
  [ "$code" = 1 ] && "${kc[@]}" -n "$NS" logs "$pod" -c function 2>&1 | grep -q "sample cron failure" && pass "$name: exit code 1, the error in the pod log" || fail "$name: exit code 1, the error in the pod log (exit $code)"
  "${kc[@]}" -n "$NS" delete cronjob "fn-$lang-cron" --ignore-not-found >/dev/null
done

[ "$fails" -eq 0 ] && echo "RUNTIMES_VERIFY_RESULT=OK" || { echo "RUNTIMES_VERIFY_RESULT=FAIL ($fails)"; exit 1; }
