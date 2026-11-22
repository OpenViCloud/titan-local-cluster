#!/bin/bash
# backup-now.sh: runs one vm.backup or volume.backup on the dev cluster now, without waiting for the hourly schedule pass
# and without a tenant login (titan-ops features/backup/design.md#incus-backup: one backup a day per VM and volume).
#
#   backup-now.sh vm|volume <titan id> [--timeout SECONDS]
#
# It drops today's row of that one resource from core.provider_commands when the row is Done or Failed (a Pending or Leased
# row is left alone and waited for), runs the control plane's backup-schedule job from its CronJob, and reads the row
# until it ends. The pass asks every VM and volume that has no row today, not only this one; a resource Incus does not hold
# gets none, and the script says NOT_QUEUED. Dev only: it writes to the dev database and reads kubeconfig of titan-k3s.
#
# Prints one last line, BACKUP_NOW=<word> key=<key> ..., and exits:
#   0  Done        1  Failed (error= has the last error) or NOT_QUEUED
#   2  usage, or the cluster could not be read   3  host memory LOW (host-memory.sh --strict; nothing was asked of the cluster)
#   4  TIMEOUT: the row did not end in time; the command is still queued or running
# BACKUP_NOW_HOST_MEMORY, BACKUP_NOW_DAY (yyyymmdd, UTC) and BACKUP_NOW_POLL_SECONDS stand in for the host check, today and
# the reading interval (lima/tests/backup-now_test.sh runs it against a fake kubectl).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
KUBECONFIG_FILE="$HOME/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml"
APP_NAMESPACE=titan-dev
DB_NAMESPACE=titan-db-dev
HOST_MEMORY=${BACKUP_NOW_HOST_MEMORY:-$here/host-memory.sh}
POLL_SECONDS=${BACKUP_NOW_POLL_SECONDS:-5}
timeout_seconds=1800

usage() {
  echo "usage: backup-now.sh vm|volume <titan id> [--timeout SECONDS]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
kind=$1
id=$2
shift 2
case "$kind" in
  vm | volume) ;;
  *) usage ;;
esac
# The id goes into SQL: only a Guid in lower-case hex gets that far.
[[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || usage
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
      timeout_seconds=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

if ! memory=$("$HOST_MEMORY" --strict); then
  echo "$memory"
  exit 3
fi
echo "$memory"

k() {
  kubectl --kubeconfig "$KUBECONFIG_FILE" --request-timeout=60s "$@"
}

primary=$(k get pod -n "$DB_NAMESPACE" -l cnpg.io/cluster=titan-db,cnpg.io/instanceRole=primary -o name | head -n 1)
if [ -z "$primary" ]; then
  echo "ERROR: no primary pod of titan-db in $DB_NAMESPACE (is the dev cluster up?)" >&2
  exit 2
fi

sql() {
  k exec -n "$DB_NAMESPACE" "$primary" -c postgres -- psql -U postgres -d titan -At -v ON_ERROR_STOP=1 -c "$1"
}

day=${BACKUP_NOW_DAY:-$(date -u +%Y%m%d)}
key="$kind-backup-$id-$day"
row() { sql "select status || '|' || attempts || '|' || coalesce(last_error, '') from core.provider_commands where key = '$key'"; }

started=$SECONDS
state=$(row) || exit 2
status=${state%%|*}
case "$status" in
  Pending | Leased)
    echo "the row of today is $status already: waiting for it"
    ;;
  *)
    if [ -n "$status" ]; then
      sql "delete from core.provider_commands where key = '$key' and status in ('Done','Failed')" > /dev/null || exit 2
    fi
    job="backup-now-$(date -u +%s)"
    k create job -n "$APP_NAMESPACE" "$job" --from=cronjob/control-plane-job-backup-schedule > /dev/null || exit 2
    k wait -n "$APP_NAMESPACE" --for=condition=complete --timeout=180s "job/$job" > /dev/null || {
      echo "ERROR: the schedule job $job did not complete in 180 s (kubectl -n $APP_NAMESPACE logs job/$job)" >&2
      exit 2
    }
    k delete job -n "$APP_NAMESPACE" "$job" > /dev/null || true
    state=$(row) || exit 2
    if [ -z "$state" ]; then
      echo "BACKUP_NOW=NOT_QUEUED key=$key (the schedule queued nothing: does Incus hold this $kind?)"
      exit 1
    fi
    ;;
esac

while true; do
  state=$(row) || exit 2
  status=${state%%|*}
  rest=${state#*|}
  attempts=${rest%%|*}
  error=${rest#*|}
  case "$status" in
    Done)
      echo "BACKUP_NOW=Done key=$key attempts=$attempts seconds=$((SECONDS - started))"
      exit 0
      ;;
    Failed)
      echo "BACKUP_NOW=Failed key=$key attempts=$attempts error=$error"
      exit 1
      ;;
  esac
  if [ $((SECONDS - started)) -ge "$timeout_seconds" ]; then
    echo "BACKUP_NOW=TIMEOUT key=$key status=${status:-none} (the command is still queued or running)"
    exit 4
  fi
  sleep "$POLL_SECONDS"
done
