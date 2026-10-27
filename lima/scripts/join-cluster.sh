#!/bin/bash
# Joins cluster local-mac to titan-incus (https://github.com/OpenViCloud/titan-ops/blob/main/docs/features/cluster/design.md#cluster-from-config):
# - Titan's client identity (ECDSA P-384, client auth) is made once on the host next to secrets.env and kept, so a rebuilt
#   VM trusts the same certificate again.
# - The server fingerprint is read from `incus info` each run: a rebuilt titan-incus has a new server certificate, so it
#   cannot live in git. The endpoint is where titan-k3s reaches the Incus API, which differs by host OS
#   (lima/scripts/host-os.sh): git holds macOS's (gitops/control-plane), and this host's in the Secret overrides it.
# - titan-incus trusts Titan's certificate under the name titan-local-mac, added only when it does not yet.
# - Secret titan-staging/control-plane-cluster holds the endpoint, the fingerprint and the identity; the control plane restarts only
#   when the Secret changed, since it reads them once at start.
# Values go through files and the Secret only: nothing printed.
# Needs: titan-incus and titan-k3s running.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/host-os.sh"

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
SECRETS_DIR="$HOME/.config/titan-local-cluster"
CLIENT_CERT="$SECRETS_DIR/titan-client.crt"
CLIENT_KEY="$SECRETS_DIR/titan-client.key"
TRUST_NAME=titan-local-mac
VM_COPY=/tmp/titan-client.crt

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

in_vm() {
  limactl shell titan-incus -- sudo "$@"
}

# ── Titan's client identity ───────────────────────────────────────────────────
umask 077
mkdir -p "$SECRETS_DIR"
if [ ! -s "$CLIENT_CERT" ] || [ ! -s "$CLIENT_KEY" ]; then
  extensions=$(mktemp)
  trap 'rm -f "$extensions"' EXIT
  printf 'keyUsage = critical, digitalSignature\nextendedKeyUsage = clientAuth\n' > "$extensions"
  # PKCS#8, the form the control plane reads.
  openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$CLIENT_KEY"
  openssl req -new -key "$CLIENT_KEY" -subj "/CN=titan" -out "$CLIENT_CERT.csr"
  openssl x509 -req -in "$CLIENT_CERT.csr" -signkey "$CLIENT_KEY" -days 3650 -sha384 \
    -extfile "$extensions" -out "$CLIENT_CERT"
  rm -f "$CLIENT_CERT.csr"
  echo "Titan's client identity made at $CLIENT_CERT"
fi
chmod 600 "$CLIENT_KEY"

# ── The server fingerprint ────────────────────────────────────────────────────
server_fingerprint=$(in_vm incus info | sed -n 's/^ *certificate_fingerprint: *//p' | head -n 1)
if ! [[ "$server_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: could not read titan-incus's certificate_fingerprint from 'incus info'; nothing changed." >&2
  exit 1
fi

# ── The endpoint ──────────────────────────────────────────────────────────────
api_address=$(in_vm incus config get core.https_address)
if [ -z "$api_address" ]; then
  echo "ERROR: titan-incus reports no core.https_address; nothing changed." >&2
  exit 1
fi
if ! endpoint=$(incus_endpoint "$(uname -s)" "$api_address"); then
  echo "ERROR: no Incus endpoint for $(uname -s); lima/ has macos/ and ubuntu/. Nothing changed." >&2
  exit 1
fi

# ── Trust ─────────────────────────────────────────────────────────────────────
client_fingerprint=$(openssl x509 -in "$CLIENT_CERT" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
if in_vm incus config trust show "$client_fingerprint" >/dev/null 2>&1; then
  echo "titan-incus already trusts Titan's certificate"
else
  in_vm tee "$VM_COPY" < "$CLIENT_CERT" >/dev/null
  in_vm incus config trust add-certificate "$VM_COPY" --name "$TRUST_NAME"
  in_vm rm -f "$VM_COPY"
  echo "titan-incus trusts Titan's certificate as $TRUST_NAME"
fi

# ── Secret ────────────────────────────────────────────────────────────────────
applied=$(k create secret generic control-plane-cluster -n titan-staging \
    --from-literal="Clusters__0__Endpoint=$endpoint" \
    --from-literal="Clusters__0__ServerFingerprint=$server_fingerprint" \
    --from-file="ProviderClientIdentity__CertificatePem=$CLIENT_CERT" \
    --from-file="ProviderClientIdentity__KeyPem=$CLIENT_KEY" \
    --dry-run=client -o yaml | k apply -f -)
echo "$applied"
case "$applied" in
  *configured*)
    if k get deployment control-plane -n titan-staging >/dev/null 2>&1; then
      k rollout restart deployment/control-plane -n titan-staging >/dev/null
      echo "control plane restarted to read the new values"
    fi ;;
esac
