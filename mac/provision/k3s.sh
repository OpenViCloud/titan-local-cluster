#!/bin/bash
# Provision of titan-k3s (mac/titan-k3s.yaml): k3s at staging's version, with its own Traefik ingress
# (staging uses cloudflared instead), and ArgoCD at staging's chart version, trimmed for RAM
# (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#ram-budget). Lima runs it as root on every boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Same as https://github.com/OpenViCloud/titan-ops/blob/main/terraform/oci-titan/1-infra/scripts/k3s-server.sh.tpl.
K3S_VERSION="v1.32.3+k3s1"
ARGOCD_CHART_VERSION="7.0.0"

# A soft memory limit makes the Go GC give memory back instead of letting k3s grow over the day
# (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#ram-budget). Written before the install so a new VM starts with it.
memory_dropin=/etc/systemd/system/k3s.service.d/memory.conf
memory_wanted=$'[Service]\nEnvironment=GOMEMLIMIT=512MiB'
memory_current=""
if [ -f "$memory_dropin" ]; then
  memory_current=$(cat "$memory_dropin")
fi
if [ "$memory_current" != "$memory_wanted" ]; then
  install -d /etc/systemd/system/k3s.service.d
  printf '%s\n' "$memory_wanted" > "$memory_dropin"
  systemctl daemon-reload
  if systemctl is-active --quiet k3s; then
    systemctl restart k3s
  fi
fi

if [ ! -x /usr/local/bin/k3s ]; then
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    sh -s - server \
      --write-kubeconfig-mode 644 \
      --disable metrics-server
fi

for attempt in $(seq 1 60); do
  if k3s kubectl get --raw /readyz >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
if ! k3s kubectl get --raw /readyz >/dev/null 2>&1; then
  echo "ERROR: k3s API not ready after 5 minutes." >&2
  exit 1
fi

# k3s's helm controller installs every HelmChart under this directory and keeps it in sync with the file.
# dex, notifications and the ApplicationSet controller are off: nothing here uses them.
# The directory can still be missing when the API first answers.
install -d -m 700 /var/lib/rancher/k3s/server/manifests
cat > /var/lib/rancher/k3s/server/manifests/argocd.yaml <<YAML
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: argocd
  namespace: kube-system
spec:
  repo: https://argoproj.github.io/argo-helm
  chart: argo-cd
  version: "$ARGOCD_CHART_VERSION"
  targetNamespace: argocd
  createNamespace: true
  valuesContent: |-
    configs:
      params:
        server.insecure: true
      cm:
        # ArgoCD gives an Application no health of its own, so root's sync waves would only order the creation of the
        # Applications, not wait for each to be Healthy: titan-db would be applied before cnpg-operator's webhook answers.
        # This is the check ArgoCD's docs give for app-of-apps.
        resource.customizations.health.argoproj.io_Application: |
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
          return hs
        # ArgoCD has no health for CNPG's Database either: without it titan-db is Healthy before keycloak_staging exists,
        # and keycloak's wave starts on a missing database. Not applied yet is Progressing, not Degraded: CNPG retries
        # while the cluster comes up.
        resource.customizations.health.postgresql.cnpg.io_Database: |
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.applied == true then
              hs.status = "Healthy"
            end
            if obj.status.message ~= nil then
              hs.message = obj.status.message
            end
          end
          return hs
    dex:
      enabled: false
    notifications:
      enabled: false
    applicationSet:
      replicas: 0
    server:
      ingress:
        enabled: true
        ingressClassName: traefik
        hostname: argocd.localhost
YAML

# Lima publishes every LoadBalancer port on the Mac, and a port below 1024 on every interface: drop Traefik's 443
# so only the ingress on 80 (published as 127.0.0.1:8080) is left (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/network.md#host-access).
cat > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      websecure:
        expose:
          default: false
YAML

echo "titan-k3s: k3s $K3S_VERSION ready; ArgoCD chart $ARGOCD_CHART_VERSION handed to the helm controller"
