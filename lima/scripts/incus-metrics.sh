#!/bin/bash
# Gives VictoriaMetrics (namespace monitoring) a certificate that reads titan-incus's /1.0/metrics and nothing else:
# - an identity of its own (ECDSA P-384, client auth) is made once on the host next to secrets.env and kept, so a
#   rebuilt VM trusts the same certificate again; Titan's own identity (join-cluster.sh) can delete every tenant's VMs
#   and never goes to the scraper.
# - titan-incus trusts it as type "metrics" under the name titan-local-metrics, added only when it does not yet.
# - Secret monitoring/incus-metrics holds the address titan-k3s dials (lima/scripts/host-os.sh), the DNS name on
#   Incus's server certificate, the cluster id, that certificate and the identity. VictoriaMetrics reads the address
#   at start, so it restarts only when the Secret changed.
# Values go through files and the Secret only: nothing printed.
# Needs: titan-incus and titan-k3s running.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/host-os.sh"

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
SECRETS_DIR="$HOME/.config/titan-local-cluster"
METRICS_CERT="$SECRETS_DIR/incus-metrics.crt"
METRICS_KEY="$SECRETS_DIR/incus-metrics.key"
TRUST_NAME=titan-local-metrics
VM_COPY=/tmp/incus-metrics.crt
CLUSTER_ID=local

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

in_vm() {
  limactl shell titan-incus -- sudo "$@"
}

# ── The metrics identity ──────────────────────────────────────────────────────
umask 077
mkdir -p "$SECRETS_DIR"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ ! -s "$METRICS_CERT" ] || [ ! -s "$METRICS_KEY" ]; then
  printf 'keyUsage = critical, digitalSignature\nextendedKeyUsage = clientAuth\n' > "$work/extensions"
  openssl ecparam -name secp384r1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$METRICS_KEY"
  openssl req -new -key "$METRICS_KEY" -subj "/CN=titan-metrics" -out "$work/request.csr"
  openssl x509 -req -in "$work/request.csr" -signkey "$METRICS_KEY" -days 3650 -sha384 \
    -extfile "$work/extensions" -out "$METRICS_CERT" 2>/dev/null
  echo "Metrics identity made at $METRICS_CERT"
fi
chmod 600 "$METRICS_KEY"

# ── Where titan-k3s reaches Incus, and the name on its certificate ────────────
api_address=$(in_vm incus config get core.https_address)
if [ -z "$api_address" ]; then
  echo "ERROR: titan-incus reports no core.https_address; nothing changed." >&2
  exit 1
fi
if ! endpoint=$(incus_endpoint "$(uname -s)" "$api_address"); then
  echo "ERROR: no Incus endpoint for $(uname -s); lima/ has macos/ and ubuntu/. Nothing changed." >&2
  exit 1
fi
address=${endpoint#https://}
in_vm cat /var/lib/incus/server.crt > "$work/server.crt"
server_name=$(openssl x509 -in "$work/server.crt" -noout -ext subjectAltName | grep -o 'DNS:[^,]*' | head -n 1 | sed 's/^DNS://')
if [ -z "$server_name" ]; then
  echo "ERROR: Incus's server certificate carries no DNS name; nothing changed." >&2
  exit 1
fi

# ── Trust ─────────────────────────────────────────────────────────────────────
fingerprint=$(openssl x509 -in "$METRICS_CERT" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
if in_vm incus config trust show "$fingerprint" >/dev/null 2>&1; then
  echo "titan-incus already trusts the metrics certificate"
else
  in_vm tee "$VM_COPY" < "$METRICS_CERT" >/dev/null
  in_vm incus config trust add-certificate "$VM_COPY" --type=metrics --name "$TRUST_NAME"
  in_vm rm -f "$VM_COPY"
  echo "titan-incus trusts the metrics certificate as $TRUST_NAME"
fi

# ── Secret ────────────────────────────────────────────────────────────────────
k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
applied=$(k create secret generic incus-metrics -n monitoring \
    --from-literal="address=$address" \
    --from-literal="serverName=$server_name" \
    --from-literal="cluster=$CLUSTER_ID" \
    --from-file="server.crt=$work/server.crt" \
    --from-file="client.crt=$METRICS_CERT" \
    --from-file="client.key=$METRICS_KEY" \
    --dry-run=client -o yaml | k apply -f -)
echo "$applied"
case "$applied" in
  *configured*)
    if k get statefulset victoria-metrics -n monitoring >/dev/null 2>&1; then
      k rollout restart statefulset/victoria-metrics -n monitoring >/dev/null
      echo "VictoriaMetrics restarted to read the new values"
    fi ;;
esac
