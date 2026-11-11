#!/usr/bin/env bash
# incus-metrics_test.sh — lima/scripts/incus-metrics.sh gives VictoriaMetrics a certificate that reads Incus's
# /1.0/metrics and nothing else.
#
# WHY this file exists: the scraper must not hold Titan's own client certificate, which can delete every tenant's
# VMs. The script makes a second identity, has titan-incus trust it as type "metrics", and writes the address, the
# name on the server's certificate, the cluster id, the server's certificate and the identity into Secret
# monitoring/incus-metrics. It runs against a fake
# `limactl` and a fake `kubectl` that keep the VM's and the cluster's state in folders, and a fake `uname`.
#
# Run:  bash lima/tests/incus-metrics_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/incus-metrics.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/vm" "$WORK/k8s" "$WORK/home/.config/titan-local-cluster"
# A server certificate like the one Incus makes for itself: its name is the VM's host name.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -keyout "$WORK/server.key" \
  -subj "/O=Linux Containers/CN=root@lima-titan-incus" -addext "subjectAltName=DNS:lima-titan-incus,IP:127.0.0.1" \
  -days 30 -out "$WORK/vm/server.crt" 2>/dev/null

cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl shell titan-incus -- sudo CMD ARGS, against $FAKE_VM.
printf '%s\n' "$*" >> "$FAKE_VM.log"
[ "$1 $2 $3 $4" = "shell titan-incus -- sudo" ] || { echo "unexpected: $*" >&2; exit 2; }
shift 4
case "$1 $2 $3 $4" in
  "incus config get core.https_address") cat "$FAKE_VM/https-address" ;;
  "incus config trust show") grep -qx "$5" "$FAKE_VM/trusted" 2>/dev/null || { echo "Error: Certificate not found" >&2; exit 1; } ;;
  "incus config trust add-certificate")
    openssl x509 -in "$FAKE_VM/$(basename "$5")" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' >> "$FAKE_VM/trusted" ;;
  *)
    case "$1" in
      cat) cat "$FAKE_VM/$(basename "$2")" ;;
      tee) cat > "$FAKE_VM/$(basename "$2")" ;;
      rm) rm -f "$FAKE_VM/$(basename "${@: -1}")" ;;
      *) echo "unexpected: $*" >&2; exit 2 ;;
    esac ;;
esac
FAKE
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# kubectl --kubeconfig K --request-timeout=T VERB …, against $FAKE_K8S: one namespace, one Secret, one StatefulSet.
printf '%s\n' "$*" >> "$FAKE_K8S.log"
shift 3
case "$1 $2" in
  "create namespace") echo "namespace: $3" ;;
  "create secret")
    for arg in "$@"; do
      case "$arg" in
        --from-literal=*) printf '%s\n' "${arg#--from-literal=}" ;;
        --from-file=*) spec=${arg#--from-file=}; printf '%s=' "${spec%%=*}"; cat "${spec#*=}"; echo ;;
      esac
    done ;;
  "apply -f")
    rendered=$(cat)
    case "$rendered" in
      namespace:*) echo "namespace/monitoring unchanged"; exit 0 ;;
    esac
    if [ ! -e "$FAKE_K8S/secret" ]; then state=created
    elif [ "$rendered" = "$(cat "$FAKE_K8S/secret")" ]; then state=unchanged
    else state=configured; fi
    printf '%s' "$rendered" > "$FAKE_K8S/secret"
    echo "secret/incus-metrics $state" ;;
  "get statefulset") [ -e "$FAKE_K8S/statefulset" ] || { echo 'Error from server (NotFound)' >&2; exit 1; } ;;
  "rollout restart") ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
cat > "$WORK/bin/uname" <<'FAKE'
#!/bin/bash
[ "$1" = "-s" ] && { echo "$FAKE_UNAME"; exit 0; }
exec /usr/bin/uname "$@"
FAKE
chmod +x "$WORK/bin/limactl" "$WORK/bin/kubectl" "$WORK/bin/uname"
FAKE_UNAME=Darwin
CONFIG="$WORK/home/.config/titan-local-cluster"

run() {
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_VM="$WORK/vm" FAKE_K8S="$WORK/k8s" FAKE_UNAME="$FAKE_UNAME" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

metrics_fp() {
  openssl x509 -in "$CONFIG/incus-metrics.crt" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

echo "a fresh Mac and a fresh titan-incus"
printf '192.168.104.1:8443\n' > "$WORK/vm/https-address"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ -s "$CONFIG/incus-metrics.crt" ] && [ -s "$CONFIG/incus-metrics.key" ] && ok "the metrics identity is made on the host" || bad "no identity files"
[ "$(stat -c %a "$CONFIG/incus-metrics.key" 2>/dev/null || stat -f %Lp "$CONFIG/incus-metrics.key")" = "600" ] \
  && ok "the key is readable by the owner only" || bad "key mode is not 600"
[ ! -e "$CONFIG/titan-client.crt" ] && ok "Titan's own identity is not touched" || bad "titan-client.crt appeared"
grep -qx "$(metrics_fp)" "$WORK/vm/trusted" && ok "titan-incus trusts the metrics certificate" || bad "not trusted: $(cat "$WORK/vm.log")"
grep -q 'add-certificate .* --type=metrics --name titan-local-metrics$' "$WORK/vm.log" && ok "as type metrics, named titan-local-metrics" || bad "wrong type or name: $(grep add-certificate "$WORK/vm.log")"
[ ! -e "$WORK/vm/incus-metrics.crt" ] && ok "the copy in the VM is removed" || bad "the certificate was left in the VM's /tmp"
grep -q 'create namespace monitoring' "$WORK/k8s.log" && ok "namespace monitoring is made if missing" || bad "no namespace"
grep -q 'create secret generic incus-metrics -n monitoring' "$WORK/k8s.log" && ok "Secret monitoring/incus-metrics" || bad "wrong Secret name or namespace"
grep -q '^address=192.168.104.1:8443$' "$WORK/k8s/secret" && ok "on macOS the address is titan-incus's own" || bad "address: $(grep '^address' "$WORK/k8s/secret")"
grep -q '^serverName=lima-titan-incus$' "$WORK/k8s/secret" && ok "the server name is the DNS name on Incus's certificate" || bad "serverName: $(grep serverName "$WORK/k8s/secret")"
grep -q '^cluster=local$' "$WORK/k8s/secret" && ok "the cluster label is local" || bad "cluster missing"
grep -q '^server.crt=-----BEGIN CERTIFICATE-----' "$WORK/k8s/secret" && ok "Incus's server certificate goes in the Secret" || bad "server.crt missing"
grep -q '^client.crt=-----BEGIN CERTIFICATE-----' "$WORK/k8s/secret" && ok "the metrics certificate goes in the Secret" || bad "client.crt missing"
grep -q '^client.key=-----BEGIN' "$WORK/k8s/secret" && ok "the metrics key goes in the Secret" || bad "client.key missing"
printf '%s' "$OUT" | grep -q 'PRIVATE KEY' && bad "the key was printed" || ok "the key is never printed"
grep -q 'rollout' "$WORK/k8s.log" && bad "restarted a VictoriaMetrics that does not exist yet" || ok "no VictoriaMetrics yet, so no restart"

echo "run again, nothing changed"
cp "$CONFIG/incus-metrics.crt" "$WORK/first.crt"
touch "$WORK/k8s/statefulset"
rm -f "$WORK/vm.log" "$WORK/k8s.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
cmp -s "$CONFIG/incus-metrics.crt" "$WORK/first.crt" && ok "the identity is kept" || bad "a new identity was made"
grep -q 'add-certificate' "$WORK/vm.log" && bad "trusted it again" || ok "the trust is not added twice"
grep -q 'rollout' "$WORK/k8s.log" && bad "restarted VictoriaMetrics for nothing" || ok "VictoriaMetrics keeps running"

echo "Ubuntu: titan-incus is reached through the host"
FAKE_UNAME=Linux
printf '192.168.5.15:8443\n' > "$WORK/vm/https-address"
rm -f "$WORK/k8s.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q '^address=192.168.5.2:8443$' "$WORK/k8s/secret" && ok "the address is the host's forward" || bad "address: $(grep '^address' "$WORK/k8s/secret")"
grep -q 'rollout restart statefulset/victoria-metrics -n monitoring' "$WORK/k8s.log" && ok "a changed Secret restarts VictoriaMetrics, which reads it at start" || bad "no restart"

echo "titan-incus reports no API address"
: > "$WORK/vm/https-address"
cp "$WORK/k8s/secret" "$WORK/secret-before"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'core.https_address' && ok "stops and names what it could not read" || bad "rc=$RC $OUT"
cmp -s "$WORK/k8s/secret" "$WORK/secret-before" && ok "the Secret is left as it was" || bad "the Secret was changed"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
