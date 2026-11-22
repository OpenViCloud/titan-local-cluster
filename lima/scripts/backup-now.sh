#!/bin/bash
# backup-now.sh: runs one vm.backup or volume.backup on the dev cluster now, without waiting for the hourly schedule pass
# and without a tenant login (titan-ops features/backup/design.md#incus-backup: one backup a day per VM and volume).
#
#   backup-now.sh vm|volume <titan id> [--timeout SECONDS]
#
# It drops today's row of that one resource from core.provider_commands when the row is Done (a Failed row the schedule
# reopens itself; a Pending or Leased row is left alone and waited for), runs the control plane's backup-schedule job from
# its CronJob, and reads the row until it ends. The pass asks every VM and volume that has no row today, not only this one
# (a resource Incus does not hold gets none: NOT_QUEUED, also when its row is a Failed one the pass did not reopen), and it
# reopens the Failed rows of today of every VM and volume Incus holds, so those rows lose their last_error and attempts. Dev only: it writes to the dev database and reads kubeconfig of titan-k3s.
#
# Exits, and says why on its last line:
#   0  BACKUP_NOW=Done key=<key> attempts=<n> seconds=<s>; seconds counts from the first read of the row, so it includes
#      the wait for the schedule job and the reading interval, not only the worker's run
#   1  BACKUP_NOW=Failed key=<key> attempts=<n> error=<last error, one line> · BACKUP_NOW=NOT_QUEUED key=<key>
#   2  usage (a BACKUP_NOW_DAY that is not yyyymmdd too), the cluster or the database could not be read, or the schedule
#      job did not complete in 600 s (the row of a Done command is gone by then; the hourly pass asks it again)
#   3  HOST_MEMORY=LOW or ERROR from host-memory.sh --strict, printed instead; nothing was asked of the cluster
#   4  BACKUP_NOW=TIMEOUT key=<key> status=<s> attempts=<n> error=<last error>: the row did not end in --timeout seconds
#      (counted like seconds=); the command is still queued or running
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

day=${BACKUP_NOW_DAY:-$(date -u +%Y%m%d)}
[[ "$day" =~ ^[0-9]{8}$ ]] || { echo "ERROR: BACKUP_NOW_DAY must be yyyymmdd" >&2; exit 2; }

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

key="$kind-backup-$id-$day"
row() { sql "select status || '|' || attempts || '|' || coalesce(last_error, '') from core.provider_commands where key = '$key'"; }

started=$SECONDS
state=$(row) || exit 2
before=$state
status=${state%%|*}
case "$status" in
  Pending | Leased)
    echo "the row of today is $status already: waiting for it"
    ;;
  *)
    if [ "$status" = "Done" ]; then
      sql "delete from core.provider_commands where key = '$key' and status = 'Done'" > /dev/null || exit 2
    fi
    job="backup-now-$(date -u +%s)"
    k create job -n "$APP_NAMESPACE" "$job" --from=cronjob/control-plane-job-backup-schedule > /dev/null || exit 2
    k wait -n "$APP_NAMESPACE" --for=condition=complete --timeout=600s "job/$job" > /dev/null || {
      echo "ERROR: the schedule job $job did not complete in 600 s (the CronJob's own deadline; the command may be queued anyway, read its row: kubectl -n $APP_NAMESPACE logs job/$job)" >&2
      exit 2
    }
    k delete job -n "$APP_NAMESPACE" "$job" > /dev/null || true
    state=$(row) || exit 2
    if [ -z "$state" ] || { [ "$status" = "Failed" ] && [ "$state" = "$before" ]; }; then
      echo "BACKUP_NOW=NOT_QUEUED key=$key (the schedule queued nothing new: does Incus hold this $kind?)"
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
      echo "BACKUP_NOW=Failed key=$key attempts=$attempts error=${error//$'\n'/ }"
      exit 1
      ;;
  esac
  if [ $((SECONDS - started)) -ge "$timeout_seconds" ]; then
    echo "BACKUP_NOW=TIMEOUT key=$key status=${status:-none} attempts=${attempts:-0} error=${error//$'\n'/ } (the command is still queued or running)"
    exit 4
  fi
  sleep "$POLL_SECONDS"
done
