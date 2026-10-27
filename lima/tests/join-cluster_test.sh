#!/usr/bin/env bash
# join-cluster_test.sh — lima/scripts/join-cluster.sh joins cluster local to titan-incus with no step by hand.
#
# WHY this file exists: the control plane reads its cluster from config and its client identity from a Secret
# (https://github.com/OpenViCloud/titan-ops/blob/main/docs/features/cluster/design.md#cluster-from-config). titan-incus
# gets a new server certificate each time it is rebuilt, so the fingerprint cannot live in git; the endpoint differs by
# host OS, so git holds only macOS's and the Secret carries this host's; and Incus must trust Titan's certificate before
# any VM can be made. The script reads the fingerprint and the endpoint, makes the certificate trusted, and must not
# restart the control plane when nothing changed. It runs against a fake `limactl` and a fake `kubectl` that keep the
# VM's and the cluster's state in folders, and a fake `uname` for the OS.
#
# Run:  bash lima/tests/join-cluster_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/join-cluster.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

SERVER_FP=e84a69da00000000000000000000000000000000000000000000000000001234
mkdir -p "$WORK/bin" "$WORK/vm" "$WORK/k8s" "$WORK/home/.config/titan-local-cluster"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl shell titan-incus -- sudo CMD ARGS, against $FAKE_VM: incus info, incus config get core.https_address,
# incus config trust show|add-certificate, tee, rm.
printf '%s\n' "$*" >> "$FAKE_VM.log"
[ "$1 $2 $3 $4" = "shell titan-incus -- sudo" ] || { echo "unexpected: $*" >&2; exit 2; }
shift 4
case "$1 $2 $3 $4" in
  "incus config get core.https_address") cat "$FAKE_VM/https-address" ;;
  "incus info  ") printf 'config: {}\nenvironment:\n  certificate_fingerprint: %s\n  server_name: titan-incus\n' "$(cat "$FAKE_VM/server-fp")" ;;
  "incus config trust show") grep -qx "$5" "$FAKE_VM/trusted" 2>/dev/null || { echo "Error: Certificate not found" >&2; exit 1; } ;;
  "incus config trust add-certificate")
    openssl x509 -in "$FAKE_VM/$(basename "$5")" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' >> "$FAKE_VM/trusted" ;;
  *)
    case "$1" in
      tee) cat > "$FAKE_VM/$(basename "$2")" ;;
      rm) rm -f "$FAKE_VM/$(basename "${@: -1}")" ;;
      *) echo "unexpected: $*" >&2; exit 2 ;;
    esac ;;
esac
FAKE
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# kubectl --kubeconfig K --request-timeout=T VERB …, against $FAKE_K8S. `create secret … --dry-run` renders its
# literals and files; `apply -f -` compares with what the cluster holds.
printf '%s\n' "$*" >> "$FAKE_K8S.log"
shift 3
case "$1" in
  create)
    for arg in "$@"; do
      case "$arg" in
        --from-literal=*) printf '%s\n' "${arg#--from-literal=}" ;;
        --from-file=*) spec=${arg#--from-file=}; printf '%s=' "${spec%%=*}"; cat "${spec#*=}"; echo ;;
      esac
    done ;;
  apply)
    rendered=$(cat)
    if [ ! -e "$FAKE_K8S/secret" ]; then state=created
    elif [ "$rendered" = "$(cat "$FAKE_K8S/secret")" ]; then state=unchanged
    else state=configured; fi
    printf '%s' "$rendered" > "$FAKE_K8S/secret"
    echo "secret/control-plane-cluster $state" ;;
  get) [ -e "$FAKE_K8S/deployment" ] || { echo 'Error from server (NotFound): deployments.apps "control-plane" not found' >&2; exit 1; } ;;
  rollout) ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
cat > "$WORK/bin/uname" <<'FAKE'
#!/bin/bash
# uname -s, as $FAKE_UNAME: the host's OS picks the endpoint (lima/scripts/host-os.sh).
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

client_fp() {
  openssl x509 -in "$CONFIG/titan-client.crt" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

echo "a fresh Mac and a fresh titan-incus"
printf '%s' "$SERVER_FP" > "$WORK/vm/server-fp"
printf '192.168.104.1:8443\n' > "$WORK/vm/https-address"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ -s "$CONFIG/titan-client.crt" ] && [ -s "$CONFIG/titan-client.key" ] && ok "Titan's client identity is made on the host" || bad "no identity files"
[ "$(stat -c %a "$CONFIG/titan-client.key" 2>/dev/null || stat -f %Lp "$CONFIG/titan-client.key")" = "600" ] \
  && ok "the key is readable by the owner only" || bad "key mode is not 600"
openssl x509 -in "$CONFIG/titan-client.crt" -noout -text | grep -q 'TLS Web Client Authentication' \
  && ok "the certificate is for client authentication" || bad "no clientAuth EKU"
openssl x509 -in "$CONFIG/titan-client.crt" -noout -text | grep -q 'secp384r1\|P-384' \
  && ok "the key is ECDSA P-384, like the identity the control plane used to make" || bad "not P-384"
grep -qx "$(client_fp)" "$WORK/vm/trusted" && ok "titan-incus trusts Titan's certificate" || bad "not trusted: $(cat "$WORK/vm.log")"
grep -q 'add-certificate .* --name titan-local$' "$WORK/vm.log" && ok "under the name titan-local" || bad "wrong trust name"
[ ! -e "$WORK/vm/titan-client.crt" ] && ok "the copy in the VM is removed" || bad "the certificate was left in the VM's /tmp"
grep -q "^Clusters__0__ServerFingerprint=$SERVER_FP$" "$WORK/k8s/secret" && ok "the server fingerprint read from incus info goes in the Secret" || bad "fingerprint missing: $(head -c 300 "$WORK/k8s/secret")"
grep -q '^Clusters__0__Endpoint=https://192.168.104.1:8443$' "$WORK/k8s/secret" && ok "on macOS the endpoint is titan-incus's user-v2 address, in the Secret" || bad "endpoint: $(grep Endpoint "$WORK/k8s/secret")"
grep -q '^ProviderClientIdentity__CertificatePem=-----BEGIN CERTIFICATE-----' "$WORK/k8s/secret" && ok "the certificate goes in the Secret" || bad "certificate missing"
grep -q '^ProviderClientIdentity__KeyPem=-----BEGIN PRIVATE KEY-----' "$WORK/k8s/secret" && ok "the key goes in the Secret, as PKCS#8" || bad "key missing or not PKCS#8"
grep -q 'create secret generic control-plane-cluster -n titan-staging' "$WORK/k8s.log" && ok "Secret titan-staging/control-plane-cluster" || bad "wrong Secret name or namespace"
printf '%s' "$OUT" | grep -q 'PRIVATE KEY' && bad "the key was printed" || ok "the key is never printed"
grep -q 'rollout' "$WORK/k8s.log" && bad "restarted a control plane that does not exist yet" || ok "no control plane yet, so no restart"

echo "run again, nothing changed"
cp "$CONFIG/titan-client.crt" "$WORK/first.crt"
touch "$WORK/k8s/deployment"
rm -f "$WORK/vm.log" "$WORK/k8s.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
cmp -s "$CONFIG/titan-client.crt" "$WORK/first.crt" && ok "the identity is kept, so trust survives" || bad "a new identity was made"
grep -q 'add-certificate' "$WORK/vm.log" && bad "trusted it again" || ok "the trust is not added twice"
grep -q 'rollout' "$WORK/k8s.log" && bad "restarted the control plane for nothing" || ok "the control plane keeps running"

echo "titan-incus rebuilt: new server certificate, empty trust store"
printf '%s' "${SERVER_FP%1234}9999" > "$WORK/vm/server-fp"
rm -f "$WORK/vm/trusted" "$WORK/vm.log" "$WORK/k8s.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q "^Clusters__0__ServerFingerprint=${SERVER_FP%1234}9999$" "$WORK/k8s/secret" && ok "the new fingerprint replaces the old" || bad "old fingerprint kept"
grep -qx "$(client_fp)" "$WORK/vm/trusted" && ok "the same identity is trusted again" || bad "not trusted after the rebuild"
grep -q 'rollout restart deployment/control-plane -n titan-staging' "$WORK/k8s.log" && ok "the control plane restarts to read the new fingerprint" || bad "no restart"

echo "incus info without a fingerprint"
printf 'garbage' > "$WORK/vm/server-fp"
cp "$WORK/k8s/secret" "$WORK/secret-before"
rm -f "$WORK/k8s.log"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'certificate_fingerprint' && ok "stops and says what it could not read" || bad "rc=$RC $OUT"
cmp -s "$WORK/k8s/secret" "$WORK/secret-before" && ok "the Secret is left as it was" || bad "the Secret was changed"

echo "Ubuntu: titan-incus is reached through the host"
FAKE_UNAME=Linux
# The fingerprint the Secret already holds, so only the endpoint changes.
printf '%s' "${SERVER_FP%1234}9999" > "$WORK/vm/server-fp"
printf '192.168.5.15:8443\n' > "$WORK/vm/https-address"
rm -f "$WORK/k8s.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q '^Clusters__0__Endpoint=https://192.168.5.2:8443$' "$WORK/k8s/secret" && ok "the endpoint is the host's forward, 192.168.5.2" || bad "endpoint: $(grep Endpoint "$WORK/k8s/secret")"
grep -q 'rollout restart deployment/control-plane -n titan-staging' "$WORK/k8s.log" && ok "a changed endpoint restarts the control plane" || bad "no restart after the endpoint changed"

echo "titan-incus reports no API address"
FAKE_UNAME=Linux
: > "$WORK/vm/https-address"
cp "$WORK/k8s/secret" "$WORK/secret-before"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'core.https_address' && ok "stops and names what it could not read" || bad "rc=$RC $OUT"
cmp -s "$WORK/k8s/secret" "$WORK/secret-before" && ok "the Secret is left as it was" || bad "the Secret was changed"

echo "a host OS with no Lima VM files"
printf '192.168.5.15:8443\n' > "$WORK/vm/https-address"
FAKE_UNAME=FreeBSD
cp "$WORK/k8s/secret" "$WORK/secret-before"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no Incus endpoint for FreeBSD' && ok "stops and names the OS" || bad "rc=$RC $OUT"
cmp -s "$WORK/k8s/secret" "$WORK/secret-before" && ok "the Secret is left as it was" || bad "the Secret was changed"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
