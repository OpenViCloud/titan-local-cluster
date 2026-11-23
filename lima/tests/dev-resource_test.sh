#!/usr/bin/env bash
# dev-resource_test.sh — lima/scripts/dev-resource.sh makes and removes a VM and a volume of beta-user on dev, no UI.
#
# WHY this file exists: a measurement on dev (a backup, a restore drill) needs a live VM or volume, and the only way to
# make one was to sign in to the portal by hand (titan-ops iterations BACKUP-OLD-COPY-CLEANUP and BACKUP-DEBT could not
# measure end to end for that). The script calls /v1 with the API token tf-acc-token.sh writes. It runs here against a
# fake `curl` that keeps its answers in files, one line per read.
#
# Run:  bash lima/tests/dev-resource_test.sh     (from the repo root)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/dev-resource.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

TOKEN=ovc_SECRETSECRETSECRET
VM=0b8d3c2e-5a1f-4c3a-9d7e-1f2a3b4c5d6e
VOL=7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d
NET=a0331ba7-9723-4ae4-b0df-6c1a43272584
POSTS_OF_CREATE=""

mkdir -p "$WORK/bin" "$WORK/home/.config/openvicloud" "$WORK/api"
# The fake curl. A GET answers from "$FAKE_API/get<path, / as _>": one body per read, the last line stays; a line "404"
# is the status 404 with no body; a path with no file is 404. A POST answers from "$FAKE_API/post<path>" (body) with 202.
# A DELETE answers 202. Every call is logged with its arguments and the stdin it got (the header carrying the token).
cat > "$WORK/bin/curl" <<'FAKE'
#!/bin/bash
method=GET out="" url="" body="" stdin=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -X) method=${args[$((i + 1))]} ;;
    -o) out=${args[$((i + 1))]} ;;
    -d) body=${args[$((i + 1))]} ;;
    -H) [ "${args[$((i + 1))]}" = "@-" ] && stdin=$(cat) ;;
    http*) url=${args[$i]} ;;
  esac
done
path=${url#*/v1}
printf '%s %s %s | %s\n' "$method" "$path" "$body" "$*" >> "$FAKE_LOG"
printf '%s\n' "$stdin" >> "$FAKE_STDIN"
key=$(printf '%s' "$path" | tr '/' '_')
code=404 text=""
case "$method" in
  GET)
    if [ "$path" = "/tenant" ]; then
      code=$(cat "$FAKE_API/tenant.code" 2>/dev/null || echo 200); text='{"name":"beta-user"}'
    elif [ -f "$FAKE_API/get$key" ]; then
      n=$(cat "$FAKE_API/get$key.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_API/get$key.n"
      total=$(wc -l < "$FAKE_API/get$key"); [ "$n" -gt "$total" ] && n=$total
      text=$(sed -n "${n}p" "$FAKE_API/get$key")
      if [ "$text" = "404" ]; then code=404 text=""; else code=200; fi
    fi ;;
  POST) if [ -f "$FAKE_API/post$key" ]; then code=202 text=$(cat "$FAKE_API/post$key"); fi ;;
  DELETE) code=202 ;;
esac
if [ -n "$out" ]; then printf '%s' "$text" > "$out"; else printf '%s' "$text"; fi
printf '%s' "$code"
FAKE
chmod +x "$WORK/bin/curl"

# The token script of tf-acc-token.sh: counts runs and, when FAKE_TOKEN_FIXES is set, makes the token valid.
cat > "$WORK/token.sh" <<'FAKE'
#!/bin/bash
echo run >> "$FAKE_TOKEN_RUNS"
[ -n "${FAKE_TOKEN_FIXES:-}" ] && echo 200 > "$FAKE_API/tenant.code"
exit 0
FAKE
chmod +x "$WORK/token.sh"

cat > "$WORK/host-memory.sh" <<'FAKE'
#!/bin/bash
echo "$*" > "$FAKE_MEMORY_ARGS"
echo "${FAKE_MEMORY:-HOST_MEMORY=OK available=9000MiB swap_used=0%}"
case "${FAKE_MEMORY:-OK}" in *LOW*) exit 1 ;; *ERROR*) exit 2 ;; *) exit 0 ;; esac
FAKE
chmod +x "$WORK/host-memory.sh"

printf 'OPENVICLOUD_API_URL=http://api.localhost:8080\nOPENVICLOUD_TOKEN=%s\n' "$TOKEN" > "$WORK/home/.config/openvicloud/tf-acc.env"

run() {
  : > "$WORK/curl.log"; : > "$WORK/stdin.log"; : > "$WORK/token.runs"; rm -f "$WORK/memory-args" "$WORK"/api/*.n
  OUT=$(env HOME="$WORK/home" PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/curl.log" FAKE_STDIN="$WORK/stdin.log" FAKE_API="$WORK/api" \
    FAKE_TOKEN_RUNS="$WORK/token.runs" FAKE_MEMORY_ARGS="$WORK/memory-args" \
    DEV_RESOURCE_TOKEN_SCRIPT="$WORK/token.sh" DEV_RESOURCE_HOST_MEMORY="$WORK/host-memory.sh" DEV_RESOURCE_POLL_SECONDS=0 \
    timeout 30 bash "$SCRIPT" "$@" 2>&1 </dev/null)
  RC=$?
}
reset() { rm -f "$WORK"/api/*; unset FAKE_MEMORY FAKE_TOKEN_FIXES; }
reads() { printf '%s\n' "$2" > "$WORK/api/get$1"; }   # reads PATH-WITH-UNDERSCORES 'line1\nline2'
post()  { printf '%s' "$2" > "$WORK/api/post$1"; }
line_of() { grep -n -m1 -- "$1" "$WORK/curl.log" | cut -d: -f1; }

network_up() {
  reads "_tenant_networks" "[{\"id\":\"$NET\",\"name\":\"tmp-net\",\"status\":\"Created\"}]"
}
vm_and_volume_up() {
  post "_tenant_vms" "{\"vmId\":\"$VM\"}"
  reads "_tenant_vms_$VM" $'{"status":"Creating","requestFailureReason":null}\n{"status":"Running","requestFailureReason":null}'
  post "_tenant_volumes" "{\"volumeId\":\"$VOL\"}"
  reads "_tenant_volumes" "[{\"id\":\"$VOL\",\"status\":\"Available\",\"currentAttachedVmId\":\"$VM\",\"requestFailureReason\":null}]"
  post "_tenant_volumes_${VOL}_attach" "{}"
}

reset
echo "create: the network is there, a VM and a volume are made and the volume is attached"
network_up; vm_and_volume_up
run create
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
[[ "$OUT" == *"DEV_RESOURCE=Created vm=$VM volume=$VOL network=$NET"* ]] && ok "last line names the three ids" || bad "output: $OUT"
grep -q "^POST /tenant/networks" "$WORK/curl.log" && bad "made a second network" || ok "does not make a network that is there"
grep -q '^POST /tenant/vms {"name":"tmp-vm-[0-9]*"' "$WORK/curl.log" && ok "VM named tmp-vm-<epoch>" || bad "vm post: $(grep 'POST /tenant/vms' "$WORK/curl.log")"
grep -q "\"networkId\":\"$NET\"" "$WORK/curl.log" && grep -q '"diskSizeGb":5' "$WORK/curl.log" && grep -q '"clusterId":"local"' "$WORK/curl.log" \
  && ok "VM on that network, 5 GiB root, cluster local" || bad "vm body: $(grep 'POST /tenant/vms' "$WORK/curl.log")"
grep -q '^POST /tenant/volumes {"name":"tmp-vol-[0-9]*"[^}]*"sizeGb":1' "$WORK/curl.log" && ok "volume of 1 GB named tmp-vol-<epoch>" || bad "volume post: $(grep 'POST /tenant/volumes ' "$WORK/curl.log")"
grep -q "^POST /tenant/volumes/$VOL/attach {\"vmId\":\"$VM\"}" "$WORK/curl.log" && ok "attaches the volume to the VM" || bad "attach: $(cat "$WORK/curl.log")"
v=$(line_of "GET /tenant/vms/$VM"); a=$(line_of "attach")
[ -n "$v" ] && [ -n "$a" ] && [ "$v" -lt "$a" ] && ok "waits for the VM to run before it attaches" || bad "order: vm read at $v, attach at $a"
grep -q -- "Idempotency-Key: " "$WORK/curl.log" && ok "every create carries an Idempotency-Key" || bad "no Idempotency-Key"
[ -f "$WORK/memory-args" ] && [ -z "$(tr -d '\n' < "$WORK/memory-args")" ] && ok "checks the host first (the plain check of a dev write pass)" || bad "host-memory args: $(cat "$WORK/memory-args" 2>/dev/null)"

echo "create: the one network the tenant has is used, whatever its name"
reset; vm_and_volume_up
reads "_tenant_networks" "[{\"id\":\"$NET\",\"name\":\"drill-net\",\"status\":\"Created\"}]"
run create
grep -q "^POST /tenant/networks" "$WORK/curl.log" && bad "made a network beside drill-net" || ok "no second network"
grep -q "\"networkId\":\"$NET\"" "$WORK/curl.log" && ok "the VM goes on drill-net" || bad "vm body: $(grep 'POST /tenant/vms' "$WORK/curl.log")"
network_up

echo "create: options set the sizes"
run create --disk-gb 7 --volume-gb 2
grep -q '"diskSizeGb":7' "$WORK/curl.log" && grep -q '"sizeGb":2' "$WORK/curl.log" && ok "--disk-gb and --volume-gb" || bad "bodies: $(cat "$WORK/curl.log")"

echo "create: the tenant has no network yet"
reset; vm_and_volume_up
reads "_tenant_networks" "$(printf '%s\n%s\n%s' '[]' "[{\"id\":\"$NET\",\"name\":\"tmp-net\",\"status\":\"Creating\"}]" "[{\"id\":\"$NET\",\"name\":\"tmp-net\",\"status\":\"Created\"}]")"
post "_tenant_networks" "{\"networkId\":\"$NET\"}"
run create
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
grep -q '^POST /tenant/networks {"name":"tmp-net","clusterId":"local"}' "$WORK/curl.log" && ok "makes network tmp-net" || bad "network post: $(cat "$WORK/curl.log")"
n=$(line_of "POST /tenant/networks"); v=$(line_of "POST /tenant/vms")
[ -n "$n" ] && [ -n "$v" ] && [ "$n" -lt "$v" ] && ok "waits for the network before the VM" || bad "order: network $n, vm $v"
grep -q "\"networkId\":\"$NET\"" "$WORK/curl.log" && ok "the VM uses the new network" || bad "no networkId of the new network"

echo "create: the VM fails"
reset; network_up; vm_and_volume_up
reads "_tenant_vms_$VM" '{"status":"Failed","requestFailureReason":"no room on the host"}'
run create
[ "$RC" -eq 1 ] && [[ "$OUT" == *"DEV_RESOURCE=Failed"*"no room on the host"* ]] && ok "exit 1, says why" || bad "exit $RC: $OUT"
grep -q "POST /tenant/volumes" "$WORK/curl.log" && bad "went on to the volume" || ok "stops: no volume"

echo "create: the VM never runs"
reset; network_up; vm_and_volume_up
reads "_tenant_vms_$VM" '{"status":"Creating","requestFailureReason":null}'
run create --timeout 0
[ "$RC" -eq 4 ] && [[ "$OUT" == *"DEV_RESOURCE=TIMEOUT"*"status=Creating"* ]] && ok "exit 4, TIMEOUT with the status" || bad "exit $RC: $OUT"

echo "the token is not good: the token script runs once, then it goes on"
reset; network_up; vm_and_volume_up
echo 401 > "$WORK/api/tenant.code"
FAKE_TOKEN_FIXES=1 run create
[ "$RC" -eq 0 ] && [ "$(wc -l < "$WORK/token.runs")" -eq 1 ] && ok "one run of tf-acc-token.sh, exit 0" || bad "exit $RC, runs $(wc -l < "$WORK/token.runs"): $OUT"
reset; echo 401 > "$WORK/api/tenant.code"
run create
[ "$RC" -eq 2 ] && [ "$(wc -l < "$WORK/token.runs")" -eq 1 ] && [[ "$OUT" == *"token"* ]] && ok "still 401: exit 2, tried the token script once" || bad "exit $RC: $OUT"
grep -q "POST" "$WORK/curl.log" && bad "wrote with a bad token" || ok "no write"

echo "the token never shows in output or argv"
reset; network_up; vm_and_volume_up
run create
if [[ "$OUT" == *"$TOKEN"* ]] || grep -q "$TOKEN" "$WORK/curl.log"; then bad "token leaked"; else ok "not in the output, not in the arguments"; fi
grep -q "Authorization: Bearer $TOKEN" "$WORK/stdin.log" && ok "goes in on stdin as the header" || bad "no header on stdin"

echo "delete vm: asks, then waits until it is gone"
reset
reads "_tenant_vms_$VM" $'{"status":"Deleting"}\n404'
run delete vm "$VM"
[ "$RC" -eq 0 ] && [[ "$OUT" == *"DEV_RESOURCE=Deleted vm=$VM"* ]] && ok "exit 0, Deleted" || bad "exit $RC: $OUT"
grep -q "^DELETE /tenant/vms/$VM" "$WORK/curl.log" && ok "DELETE of that VM" || bad "log: $(cat "$WORK/curl.log")"

echo "delete volume: detaches first when it is attached"
reset
vol_row() { printf '[{"id":"%s","status":"Available","currentAttachedVmId":%s,"requestFailureReason":null}]' "$VOL" "$1"; }
reads "_tenant_volumes" "$(printf '%s\n%s\n%s' "$(vol_row "\"$VM\"")" "$(vol_row null)" '[]')"
post "_tenant_volumes_${VOL}_detach" "{}"
run delete volume "$VOL"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC: $OUT"
d=$(line_of "POST /tenant/volumes/$VOL/detach"); x=$(line_of "DELETE /tenant/volumes/$VOL")
[ -n "$d" ] && [ -n "$x" ] && [ "$d" -lt "$x" ] && ok "detach, then delete" || bad "order: detach $d, delete $x"

echo "the host is short of memory"
reset
FAKE_MEMORY="HOST_MEMORY=LOW available=3163MiB swap_used=54%" run create
[ "$RC" -eq 3 ] && [[ "$OUT" == *"HOST_MEMORY=LOW"* ]] && [ ! -s "$WORK/curl.log" ] && ok "exit 3, asks the API nothing" || bad "exit $RC: $OUT"
FAKE_MEMORY="HOST_MEMORY=ERROR cannot read MemAvailable" run delete vm "$VM"
[ "$RC" -eq 3 ] && ok "an ERROR reading is not OK either" || bad "exit $RC: $OUT"

echo "bad arguments reach nothing"
reset
for args in "" "make" "create --disk-gb" "create --disk-gb abc" "create --disk-gb 0" "create --unknown" "delete" "delete disk $VM" "delete vm not-an-id" "delete vm $VM/../x"; do
  # shellcheck disable=SC2086
  run $args
  if [ "$RC" -eq 2 ] && [ ! -s "$WORK/curl.log" ]; then ok "exit 2, nothing called: '$args'"; else bad "'$args' exit $RC, log: $(cat "$WORK/curl.log") out: $OUT"; fi
done

echo
echo "dev-resource_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
