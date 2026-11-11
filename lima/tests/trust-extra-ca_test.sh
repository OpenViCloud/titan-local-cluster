#!/usr/bin/env bash
# trust-extra-ca_test.sh — lima/scripts/trust-extra-ca.sh makes both VMs, ArgoCD and the regression runner trust an extra CA
# of the host.
#
# WHY this file exists: a host behind a TLS-inspecting proxy (Cloudflare WARP Gateway) sees every https site signed by the
# proxy's CA. The VMs do not trust it, so ArgoCD cannot fetch this repository, containerd cannot pull from ghcr.io and Incus
# cannot pull images. The CA must reach both system stores, the daemons that read them once per process must restart when it
# changed (and only then), and ArgoCD, which keeps its own store, must get it for every host its Applications read. Pods trust
# only their image's store, so the regression runner's npm cannot install: the CA goes into ConfigMap titan-extra-ca of
# titan-auth-dev, which the runner's CronJobs mount. A host without the file must be left alone. The script runs against a
# fake `limactl` that keeps each VM's files in a folder, and a fake `kubectl` that keeps each ConfigMap in a file.
#
# Run:  bash lima/tests/trust-extra-ca_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="$HERE/../scripts/trust-extra-ca.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/bin" "$WORK/vm/titan-incus" "$WORK/vm/titan-k3s" "$WORK/home/.config/titan-local-cluster"
cat > "$WORK/bin/limactl" <<'FAKE'
#!/bin/bash
# limactl shell VM -- sudo CMD ARGS: records "VM CMD ARGS"; `cat FILE` and `tee FILE` read and write $FAKE_VM/VM/<basename>.
[ "$1 $3 $4" = "shell -- sudo" ] || { echo "unexpected: $*" >&2; exit 2; }
vm=$2; shift 4
printf '%s %s\n' "$vm" "$*" >> "$FAKE_VM.log"
case "$1" in
  cat) cat "$FAKE_VM/$vm/$(basename "$2")" 2>/dev/null || { echo "cat: $2: No such file or directory" >&2; exit 1; } ;;
  tee) [ -z "${FAKE_TEE_FAILS:-}" ] || { echo "limactl: instance $vm is not running" >&2; exit 1; }; cat > "$FAKE_VM/$vm/$(basename "$2")" ;;
  update-ca-certificates|systemctl) ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/limactl"
cat > "$WORK/bin/kubectl" <<'FAKE'
#!/bin/bash
# kubectl --kubeconfig KC get|patch configmap argocd-tls-certs-cm -n argocd ...: `get` prints $FAKE_VM/argocd-tls.json,
# `patch --patch-file F` stores F there. get configmap titan-extra-ca -n titan-auth-dev prints $FAKE_VM/extra-ca-cm.json
# (NotFound when absent); `apply -f F` stores F there. get namespace titan-auth-dev answers unless FAKE_NO_NAMESPACE.
printf 'kubectl %s\n' "$*" >> "$FAKE_VM.log"
case "$*" in
  *" get configmap argocd-tls-certs-cm -n argocd -o json")
    [ -z "${FAKE_NO_ARGOCD:-}" ] || { echo 'Error from server (NotFound): configmaps "argocd-tls-certs-cm" not found' >&2; exit 1; }
    [ -z "${FAKE_API_DOWN:-}" ] || { echo 'The connection to the server 127.0.0.1:6443 was refused' >&2; exit 1; }
    cat "$FAKE_VM/argocd-tls.json" 2>/dev/null || echo '{"data":null}' ;;
  *" patch configmap argocd-tls-certs-cm -n argocd --type merge --patch-file "*) cp "${@: -1}" "$FAKE_VM/argocd-tls.json" ;;
  *" get configmap titan-extra-ca -n titan-auth-dev -o json")
    [ -z "${FAKE_CM_GET_FAILS:-}" ] || { echo 'Error from server (Forbidden): configmaps "titan-extra-ca" is forbidden' >&2; exit 1; }
    cat "$FAKE_VM/extra-ca-cm.json" 2>/dev/null || { echo 'Error from server (NotFound): configmaps "titan-extra-ca" not found' >&2; exit 1; } ;;
  *" get namespace titan-auth-dev -o name")
    [ -z "${FAKE_NO_NAMESPACE:-}" ] || { echo 'Error from server (NotFound): namespaces "titan-auth-dev" not found' >&2; exit 1; }
    [ -z "${FAKE_NS_GET_FAILS:-}" ] || { echo 'Error from server (Forbidden): namespaces "titan-auth-dev" is forbidden' >&2; exit 1; }
    echo namespace/titan-auth-dev ;;
  *" apply -f "*) cp "${@: -1}" "$FAKE_VM/extra-ca-cm.json" ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/kubectl"
CA="$WORK/home/.config/titan-local-cluster/extra-ca.crt"
CERT=$(printf -- '-----BEGIN CERTIFICATE-----\nMIIfirst\n-----END CERTIFICATE-----')

run() {
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_VM="$WORK/vm" "$@" bash "$SCRIPT" 2>&1 </dev/null)
  RC=$?
}

echo "no extra CA on the host"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[ ! -e "$WORK/vm.log" ] && ok "no VM is touched" || bad "a VM was touched: $(cat "$WORK/vm.log")"

echo "a file that is not a certificate"
printf 'not a certificate\n' > "$CA"
run
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'extra-ca.crt' && ok "stops and names the file" || bad "rc=$RC $OUT"
[ ! -e "$WORK/vm.log" ] && ok "no VM is touched" || bad "a VM was touched: $(cat "$WORK/vm.log")"

echo "a VM the CA cannot be written to"
printf '%s\n' "$CERT" > "$CA"
run FAKE_TEE_FAILS=1
[ "$RC" -ne 0 ] && ok "exit $RC" || bad "exit 0 after a failed write: $OUT"
printf '%s' "$OUT" | grep -q 'already trusts' && bad "says it already trusts: $OUT" || ok "does not claim the VM trusts it"
rm -f "$WORK/vm.log"

echo "ArgoCD not installed yet (a new titan-k3s)"
run FAKE_NO_ARGOCD=1
[ "$RC" -eq 0 ] && ok "exit 0, so up.sh goes on" || bad "exit $RC: $OUT"
[ -s "$WORK/vm/titan-k3s/titan-extra-ca.crt" ] && ok "the VMs trust the CA anyway" || bad "the VM part did not run"
printf '%s' "$OUT" | grep -q 'ArgoCD is not installed yet, so only the VMs got the extra CA; run up.sh again' && ok "says ArgoCD did not get the CA" || bad "no word about ArgoCD: $OUT"
[ ! -e "$WORK/vm/extra-ca-cm.json" ] && ok "no ConfigMap for the runner yet (its namespace may not exist)" || bad "ConfigMap written before ArgoCD"
rm -rf "$WORK/vm.log" "$WORK/vm/titan-incus/"* "$WORK/vm/titan-k3s/"*

echo "the k3s API does not answer"
run FAKE_API_DOWN=1
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'connection to the server' && ok "stops and shows kubectl's error" || bad "rc=$RC $OUT"
rm -rf "$WORK/vm.log" "$WORK/vm/titan-incus/"* "$WORK/vm/titan-k3s/"*

echo "ArgoCD installed but titan-auth-dev not made yet (an up.sh stopped before bootstrap-secrets.sh)"
run FAKE_NO_NAMESPACE=1
[ "$RC" -eq 0 ] && ok "exit 0, so up.sh goes on to bootstrap-secrets.sh" || bad "exit $RC: $OUT"
[ ! -e "$WORK/vm/extra-ca-cm.json" ] && ok "no ConfigMap written" || bad "ConfigMap written into a missing namespace"
printf '%s' "$OUT" | grep -q 'titan-auth-dev is not there yet' && ok "says the runner did not get the CA" || bad "no word about the runner: $OUT"
rm -rf "$WORK/vm.log" "$WORK/vm/titan-incus/"* "$WORK/vm/titan-k3s/"* "$WORK/vm/argocd-tls.json"

echo "VMs without the CA"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
for vm in titan-incus titan-k3s; do
  cmp -s "$CA" "$WORK/vm/$vm/titan-extra-ca.crt" && ok "$vm has the CA, byte for byte" || bad "$vm's file differs or is missing"
  grep -q "^$vm tee /usr/local/share/ca-certificates/titan-extra-ca.crt$" "$WORK/vm.log" \
    && ok "$vm: into /usr/local/share/ca-certificates/" || bad "$vm: wrong path: $(cat "$WORK/vm.log")"
  grep -q "^$vm update-ca-certificates$" "$WORK/vm.log" && ok "$vm: the system store is rebuilt" || bad "$vm: no update-ca-certificates"
done
grep -q '^titan-incus systemctl restart incus$' "$WORK/vm.log" && ok "Incus restarts to read it" || bad "Incus not restarted"
grep -q '^titan-k3s systemctl restart k3s$' "$WORK/vm.log" && ok "k3s (and its containerd) restarts to read it" || bad "k3s not restarted"
[ "$(grep -n '^titan-k3s update-ca-certificates' "$WORK/vm.log" | cut -d: -f1)" -lt "$(grep -n '^titan-k3s systemctl restart k3s' "$WORK/vm.log" | cut -d: -f1)" ] \
  && ok "the store is rebuilt before the restart" || bad "restart came first"
TLS="$WORK/vm/argocd-tls.json"
grep -q 'kubectl .* patch configmap argocd-tls-certs-cm -n argocd --type merge --patch-file ' "$WORK/vm.log" \
  && ok "ArgoCD's argocd-tls-certs-cm is patched" || bad "not patched: $(cat "$WORK/vm.log")"
# The oracle: every https host an Application of gitops/apps/ reads, taken from the files here, not from the script.
hosts=$(grep -h 'repoURL:' "$REPO"/gitops/apps/*.yaml | sed -E 's#.*repoURL: *https://([^/]+).*#\1#' | sort -u)
[ "$(printf '%s\n' "$hosts" | wc -l)" -ge 2 ] && ok "the oracle reads several hosts" || bad "oracle read: $hosts"
for h in $hosts; do
  python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['data']; sys.exit(0 if d.get(sys.argv[2],'').strip()==open(sys.argv[3]).read().strip() else 1)" "$TLS" "$h" "$CA" \
    && ok "ArgoCD trusts the CA for $h" || bad "no entry for $h in $(cat "$TLS")"
done

CM="$WORK/vm/extra-ca-cm.json"
python3 -c "
import json, sys
cm = json.load(open(sys.argv[1]))
meta = cm['metadata']
ok = (cm['kind'] == 'ConfigMap' and meta['name'] == 'titan-extra-ca' and meta['namespace'] == 'titan-auth-dev'
      and cm['data'] == {'extra-ca.crt': open(sys.argv[2]).read()})
sys.exit(0 if ok else 1)
" "$CM" "$CA" && ok "ConfigMap titan-auth-dev/titan-extra-ca holds the CA byte for byte, under extra-ca.crt" || bad "ConfigMap: $(cat "$CM" 2>&1)"
python3 -c "
import json, sys
meta = json.load(open(sys.argv[1]))['metadata']
sys.exit(1 if meta.get('labels') or meta.get('annotations') else 0)
" "$CM" && ok "the ConfigMap carries no label or annotation, so no ArgoCD Application owns and prunes it" || bad "metadata: $(cat "$CM")"

[ "$(ls -A "$WORK/home/.config/titan-local-cluster")" = "extra-ca.crt" ] && ok "nothing else is written beside the CA" || bad "files beside the CA: $(ls -A "$WORK/home/.config/titan-local-cluster")"

echo "the same CA again"
rm "$WORK/vm.log"
run
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q -e ' tee ' -e 'update-ca-certificates' -e 'systemctl' -e 'kubectl.* patch ' -e 'kubectl.* apply ' "$WORK/vm.log" \
  && bad "it wrote or restarted anyway: $(cat "$WORK/vm.log")" || ok "nothing is written and nothing restarts"

echo "a new CA"
rm "$WORK/vm.log"
printf -- '-----BEGIN CERTIFICATE-----\nMIIsecond\n-----END CERTIFICATE-----\n' > "$CA"
run
cmp -s "$CA" "$WORK/vm/titan-k3s/titan-extra-ca.crt" && grep -q '^titan-k3s systemctl restart k3s$' "$WORK/vm.log" \
  && grep -q 'MIIsecond' "$WORK/vm/argocd-tls.json" && ! grep -q 'MIIfirst' "$WORK/vm/argocd-tls.json" \
  && grep -q 'MIIsecond' "$WORK/vm/extra-ca-cm.json" && ! grep -q 'MIIfirst' "$WORK/vm/extra-ca-cm.json" \
  && ok "the new CA replaces the old one everywhere" || bad "a VM, ArgoCD or the runner's ConfigMap kept the old CA"

echo "the runner's namespace cannot be read"
run FAKE_NS_GET_FAILS=1
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'namespaces "titan-auth-dev" is forbidden' && ok "stops and shows kubectl's error" || bad "rc=$RC $OUT"

echo "the runner's ConfigMap cannot be read"
run FAKE_CM_GET_FAILS=1
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'forbidden' && ok "stops and shows kubectl's error" || bad "rc=$RC $OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
