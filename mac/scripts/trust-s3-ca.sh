#!/bin/bash
# Puts the S3 CA that bootstrap-secrets.sh made into titan-incus's system store. Incus uploads VM and volume backups to
# SeaweedFS over https and trusts only that store, which Go reads once per process: Incus restarts when the CA changed, and
# only then.
# Needs: titan-incus running, bootstrap-secrets.sh run.
set -euo pipefail

CA_CERT="$HOME/.config/titan-local-cluster/s3-ca.crt"
TARGET=/usr/local/share/ca-certificates/titan-local-s3.crt

if [ ! -s "$CA_CERT" ]; then
  echo "ERROR: no $CA_CERT; run mac/scripts/bootstrap-secrets.sh first." >&2
  exit 1
fi

in_vm() {
  limactl shell titan-incus -- sudo "$@"
}

current=$(in_vm cat "$TARGET" 2>/dev/null || true)
if [ "$current" = "$(cat "$CA_CERT")" ]; then
  echo "titan-incus already trusts the S3 CA"
  exit 0
fi
in_vm tee "$TARGET" < "$CA_CERT" >/dev/null
in_vm update-ca-certificates >/dev/null
in_vm systemctl restart incus
echo "titan-incus trusts the S3 CA; Incus restarted"
