#!/bin/bash
# dev-resource.sh: makes or removes a VM and a volume of beta-user on the dev cluster without the portal, so a
# measurement on dev (a backup, a restore drill) has something live to work on. It calls /v1 as beta-user with the API
# token tf-acc-token.sh writes (no password, no sign-in); a token that /v1/tenant does not accept is replaced by one run
# of tf-acc-token.sh. Dev only: the API address is the dev cluster's.
#
#   dev-resource.sh create [--disk-gb N] [--volume-gb N] [--timeout SECONDS]
#   dev-resource.sh delete vm|volume <titan id> [--timeout SECONDS]
#
# create uses the tenant's network, or makes network tmp-net when it has none (the quota is one network), then VM tmp-vm-<epoch> with a
# root disk of --disk-gb (default 5: titan-incus has 4 GiB of RAM and hangs on a big export), waits until it runs, makes
# volume tmp-vol-<epoch> of --volume-gb (default 1) and attaches it. delete asks for the removal and waits until the VM
# or volume is gone; a volume that is attached is detached first. The token goes to curl on stdin and is never printed.
#
# Exits, and says why on the last line:
#   0  DEV_RESOURCE=Created vm=<id> volume=<id> network=<id> · DEV_RESOURCE=Deleted vm=<id> (or volume=<id>)
#   1  DEV_RESOURCE=Failed <what> reason=<the API's own reason, one line>
#   2  usage, or the token is still refused after tf-acc-token.sh (is beta-user's tenant on this cluster?)
#   3  HOST_MEMORY=LOW or ERROR from host-memory.sh, printed instead; nothing was asked of the API
#   4  DEV_RESOURCE=TIMEOUT <what> status=<s>: it did not finish in --timeout seconds (default 600)
# DEV_RESOURCE_ENV (the token file), DEV_RESOURCE_TOKEN_SCRIPT, DEV_RESOURCE_HOST_MEMORY and DEV_RESOURCE_POLL_SECONDS
# stand in for the defaults (lima/tests/dev-resource_test.sh runs it against a fake curl).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=${DEV_RESOURCE_ENV:-$HOME/.config/openvicloud/tf-acc.env}
TOKEN_SCRIPT=${DEV_RESOURCE_TOKEN_SCRIPT:-$here/tf-acc-token.sh}
HOST_MEMORY=${DEV_RESOURCE_HOST_MEMORY:-$here/host-memory.sh}
POLL_SECONDS=${DEV_RESOURCE_POLL_SECONDS:-5}
CLUSTER_ID=local
NETWORK_NAME=tmp-net
TEMPLATE_ID=0a5e0000-0000-4000-8000-000000000002
VM_OFFERING=s
VOLUME_OFFERING=standard
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

usage() {
  echo "usage: dev-resource.sh create [--disk-gb N] [--volume-gb N] [--timeout SECONDS]" >&2
  echo "       dev-resource.sh delete vm|volume <titan id> [--timeout SECONDS]" >&2
  exit 2
}

positive() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

[ $# -ge 1 ] || usage
action=$1
shift
disk_gb=5
volume_gb=1
timeout_seconds=600
kind=""
id=""
case "$action" in
  create) ;;
  delete)
    [ $# -ge 2 ] || usage
    kind=$1
    id=$2
    shift 2
    case "$kind" in vm | volume) ;; *) usage ;; esac
    [[ "$id" =~ $UUID_RE ]] || usage
    ;;
  *) usage ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --disk-gb)
      [ "$action" = create ] && [ $# -ge 2 ] && positive "$2" || usage
      disk_gb=$2
      shift 2
      ;;
    --volume-gb)
      [ "$action" = create ] && [ $# -ge 2 ] && positive "$2" || usage
      volume_gb=$2
      shift 2
      ;;
    --timeout)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
      timeout_seconds=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

# Host first: a dev write pass starts only when the host has the memory for it (titan-local-cluster docs/topology.md#host-memory).
if memory=$(bash "$HOST_MEMORY" 2>&1); then
  :
else
  echo "$memory"
  exit 3
fi
case "$memory" in *HOST_MEMORY=OK* | *HOST_MEMORY=SKIPPED*) ;; *) echo "$memory"; exit 3 ;; esac

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
API_URL=""
TOKEN=""
CODE=""

load_token() {
  API_URL=""
  TOKEN=""
  [ -f "$ENV_FILE" ] || return 1
  # Read the two names by hand: the file is not sourced, so nothing in it runs.
  API_URL=$(sed -n 's/^OPENVICLOUD_API_URL=//p' "$ENV_FILE" | head -1)
  TOKEN=$(sed -n 's/^OPENVICLOUD_TOKEN=//p' "$ENV_FILE" | head -1)
  [ -n "$API_URL" ] && [ -n "$TOKEN" ]
}

# call METHOD PATH [JSON]: CODE is the HTTP status, $body_file the body. A create carries an Idempotency-Key.
call() {
  local method=$1 path=$2 json=${3:-}
  local args=(-sS -X "$method" -H @- -o "$body_file" -w '%{http_code}')
  if [ -n "$json" ]; then
    args+=(-H 'Content-Type: application/json' -H "Idempotency-Key: $(python3 -I -c 'import uuid; print(uuid.uuid4())')" -d "$json")
  fi
  CODE=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | curl "${args[@]}" "$API_URL/v1$path" 2>/dev/null) || CODE=000
}

# field NAME: a top-level string or null field of the body as text ("" for null or absent).
field() {
  python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[2]))
except Exception:
    d = {}
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
print("" if v is None else v)' "$1" "$body_file"
}

# pick KEY VALUE FIELD: FIELD of the item of the list body whose KEY is VALUE ("" when there is none; "-" for null).
pick() {
  python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[4]))
except Exception:
    d = []
for item in d if isinstance(d, list) else []:
    if item.get(sys.argv[1]) == sys.argv[2]:
        v = item.get(sys.argv[3])
        print("-" if v is None else v)
        break' "$1" "$2" "$3" "$body_file"
}

# The token must be accepted by /v1/tenant; one run of the token script replaces one that is not.
ensure_token() {
  if load_token; then
    call GET /tenant
    [ "$CODE" = 200 ] && return 0
  fi
  bash "$TOKEN_SCRIPT" >/dev/null 2>&1 || true
  if load_token; then
    call GET /tenant
    [ "$CODE" = 200 ] && return 0
  fi
  echo "DEV_RESOURCE=Failed token reason=GET /v1/tenant answered $CODE: no token beta-user's tenant accepts (run lima/scripts/tf-acc-token.sh)"
  exit 2
}

deadline=$((SECONDS + timeout_seconds))
timed_out() { [ "$SECONDS" -ge "$deadline" ]; }
fail() { echo "DEV_RESOURCE=Failed $1 reason=$(printf '%s' "$2" | tr '\n' ' ')"; exit 1; }
timeout_out() { echo "DEV_RESOURCE=TIMEOUT $1 status=$2"; exit 4; }

# wait_vm ID WANT: until the VM's status is WANT; 404 or Deleted counts as WANT=gone. A reason on the VM is a failure.
wait_vm() {
  local vm=$1 want=$2 status reason
  while true; do
    call GET "/tenant/vms/$vm"
    if [ "$CODE" = 404 ]; then
      [ "$want" = gone ] && return 0
      fail "vm=$vm" "the VM is not there"
    fi
    status=$(field status)
    reason=$(field requestFailureReason)
    [ -n "$reason" ] && fail "vm=$vm" "$reason"
    [ "$status" = Failed ] && fail "vm=$vm" "status Failed"
    if [ "$want" = gone ]; then [ "$status" = Deleted ] && return 0; elif [ "$status" = "$want" ]; then return 0; fi
    timed_out && timeout_out "vm=$vm" "$status"
    sleep "$POLL_SECONDS"
  done
}

# wait_volume ID CONDITION [VM]: CONDITION is "available", "attached" (to VM), "detached" or "gone", read from the list of volumes.
wait_volume() {
  local vol=$1 condition=$2 vm=${3:-} status attached reason
  while true; do
    call GET /tenant/volumes
    status=$(pick id "$vol" status)
    attached=$(pick id "$vol" currentAttachedVmId)
    reason=$(pick id "$vol" requestFailureReason)
    [ -n "$reason" ] && [ "$reason" != "-" ] && fail "volume=$vol" "$reason"
    case "$condition" in
      available) [ "$status" = Available ] && return 0 ;;
      attached) [ "$status" = Available ] && [ "$attached" = "$vm" ] && return 0 ;;
      detached) [ "$status" = Available ] && [ "$attached" = "-" ] && return 0 ;;
      gone) { [ -z "$status" ] || [ "$status" = Deleted ]; } && return 0 ;;
    esac
    timed_out && timeout_out "volume=$vol" "${status:-gone}"
    sleep "$POLL_SECONDS"
  done
}

wait_network() {
  local net=$1 status reason
  while true; do
    call GET /tenant/networks
    status=$(pick id "$net" status)
    reason=$(pick id "$net" requestFailureReason)
    [ -n "$reason" ] && [ "$reason" != "-" ] && fail "network=$net" "$reason"
    [ "$status" = Created ] && return 0
    timed_out && timeout_out "network=$net" "$status"
    sleep "$POLL_SECONDS"
  done
}

ensure_token

if [ "$action" = delete ]; then
  if [ "$kind" = vm ]; then
    call DELETE "/tenant/vms/$id"
    [ "$CODE" = 202 ] || fail "vm=$id" "DELETE answered $CODE: $(cat "$body_file")"
    wait_vm "$id" gone
    echo "DEV_RESOURCE=Deleted vm=$id"
  else
    call GET /tenant/volumes
    attached=$(pick id "$id" currentAttachedVmId)
    if [ -n "$attached" ] && [ "$attached" != "-" ]; then
      call POST "/tenant/volumes/$id/detach" "{}"
      [ "$CODE" = 202 ] || fail "volume=$id" "detach answered $CODE: $(cat "$body_file")"
      wait_volume "$id" detached
    fi
    call DELETE "/tenant/volumes/$id"
    [ "$CODE" = 202 ] || fail "volume=$id" "DELETE answered $CODE: $(cat "$body_file")"
    wait_volume "$id" gone
    echo "DEV_RESOURCE=Deleted volume=$id"
  fi
  exit 0
fi

call GET /tenant/networks
# The tenant may have one network: whichever it has, under any name, is the one the VM goes on.
net=$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = []
for item in d if isinstance(d, list) else []:
    if item.get("status") == "Created":
        print(item["id"])
        break' "$body_file")
if [ -z "$net" ]; then
  call POST /tenant/networks "{\"name\":\"$NETWORK_NAME\",\"clusterId\":\"$CLUSTER_ID\"}"
  [ "$CODE" = 202 ] || fail "network" "create answered $CODE: $(cat "$body_file")"
  net=$(field networkId)
  [ -n "$net" ] || fail "network" "create answered no id"
  wait_network "$net"
fi

stamp=$(date +%s)
call POST /tenant/vms "{\"name\":\"tmp-vm-$stamp\",\"networkId\":\"$net\",\"vmOfferingId\":\"$VM_OFFERING\",\"templateId\":\"$TEMPLATE_ID\",\"clusterId\":\"$CLUSTER_ID\",\"diskSizeGb\":$disk_gb}"
[ "$CODE" = 202 ] || fail "vm" "create answered $CODE: $(cat "$body_file")"
vm=$(field vmId)
[ -n "$vm" ] || fail "vm" "create answered no id"
wait_vm "$vm" Running

call POST /tenant/volumes "{\"name\":\"tmp-vol-$stamp\",\"volumeOfferingId\":\"$VOLUME_OFFERING\",\"clusterId\":\"$CLUSTER_ID\",\"sizeGb\":$volume_gb}"
[ "$CODE" = 202 ] || fail "volume" "create answered $CODE: $(cat "$body_file")"
vol=$(field volumeId)
[ -n "$vol" ] || fail "volume" "create answered no id"

wait_volume "$vol" available
call POST "/tenant/volumes/$vol/attach" "{\"vmId\":\"$vm\"}"
[ "$CODE" = 202 ] || fail "volume=$vol" "attach answered $CODE: $(cat "$body_file")"
wait_volume "$vol" attached "$vm"
echo "DEV_RESOURCE=Created vm=$vm volume=$vol network=$net"
