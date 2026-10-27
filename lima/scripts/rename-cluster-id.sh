#!/bin/bash
# Moves dev's rows from cluster id local-mac to local, the id the local cluster has had since it runs on macOS or Ubuntu.
# The control plane keys resources, provider commands and template sync states by cluster id; rows still under local-mac
# belong to no configured cluster. One statement, so the rows move together or not at all; a sync state that a local one
# already replaced is dropped. Dev data only: staging's id singapore01 never changes here. Safe to run again: a second
# run moves nothing and restarts nothing.
set -euo pipefail

KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=30s "$@"
}

pod=$(k get pod -n titan-db-staging -l cnpg.io/cluster=titan-db,cnpg.io/instanceRole=primary -o name)
if [ -z "$pod" ]; then
  echo "no titan-db primary yet: nothing to rename"
  exit 0
fi

sql="WITH dropped AS (DELETE FROM core.vm_template_clusters o WHERE o.cluster_id = 'local-mac' AND EXISTS (SELECT 1 FROM core.vm_template_clusters n WHERE n.cluster_id = 'local' AND n.template_id = o.template_id) RETURNING 1),"
sql+=" t AS (UPDATE core.vm_template_clusters SET cluster_id = 'local' WHERE cluster_id = 'local-mac' AND NOT EXISTS (SELECT 1 FROM core.vm_template_clusters n WHERE n.cluster_id = 'local' AND n.template_id = vm_template_clusters.template_id) RETURNING 1),"
for table in vms volumes networks load_balancers provider_commands; do
  sql+=" ${table} AS (UPDATE core.${table} SET cluster_id = 'local' WHERE cluster_id = 'local-mac' RETURNING 1),"
done
sql+=" moved AS (SELECT 1 FROM dropped UNION ALL SELECT 1 FROM t UNION ALL SELECT 1 FROM vms UNION ALL SELECT 1 FROM volumes"
sql+=" UNION ALL SELECT 1 FROM networks UNION ALL SELECT 1 FROM load_balancers UNION ALL SELECT 1 FROM provider_commands)"
sql+=" SELECT count(*) FROM moved;"

moved=$(k exec -n titan-db-staging "$pod" -c postgres -- psql -d titan -v ON_ERROR_STOP=1 -At -c "$sql")
echo "rows moved from cluster local-mac to local: $moved"
if [ "$moved" != "0" ]; then
  k rollout restart deployment/control-plane -n titan-staging >/dev/null
  k rollout restart deployment/incus-worker -n titan-staging >/dev/null
  echo "control plane and worker restarted to read the moved rows"
fi
