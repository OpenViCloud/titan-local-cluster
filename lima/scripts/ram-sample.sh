#!/bin/bash
# ram-sample.sh LOG STOP_FILE [SECONDS]: reads the RAM of the Ubuntu host and of titan-k3s every SECONDS (default 30)
# until STOP_FILE exists, appending to LOG (docs/topology.md#host-memory). It only reads; a STOP_FILE left from an earlier
# run is removed at start. A new LOG starts with one `# <command> · <where> · <UTC>` line; every sample starts with
# `== <UTC>`, and the loop ends with `== stop <UTC>`. The guest read has a timeout, so a stalled guest leaves a line
# saying so instead of stopping the loop; the stop file is read before each sample, so stopping takes up to one
# interval plus one sample (at most about a minute at the defaults).
# RAM_SAMPLE_LIMACTL and RAM_SAMPLE_TIMEOUT stand in for limactl and the 20 s timeout (lima/tests/ram-sample_test.sh).
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: ram-sample.sh LOG STOP_FILE [SECONDS]" >&2
  exit 2
fi
log=$1
stop=$2
every=${3:-30}
limactl=${RAM_SAMPLE_LIMACTL:-limactl}
guest_timeout=${RAM_SAMPLE_TIMEOUT:-20}
case "$every" in
  "" | *[!0-9]* | 0) echo "ram-sample.sh: SECONDS must be a whole number above 0, not '$every'" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)

if [ "$(uname -s)" != "Linux" ]; then
  echo "ram-sample.sh: Ubuntu only (ps -C, timeout); nothing sampled" >&2
  exit 0
fi

rm -f "$stop"
mkdir -p "$(dirname "$log")"
if [ ! -s "$log" ]; then
  echo "# bash lima/scripts/ram-sample.sh $log $stop $every · host $(hostname) and VM titan-k3s · $(date -u +%FT%TZ)" >> "$log"
fi
while [ ! -e "$stop" ]; do
  {
    echo "== $(date -u +%FT%TZ)"
    bash "$here/host-memory.sh"
    ps -o rss=,args= -C qemu-system-x86_64 | cut -c1-60
    timeout -k 5 "$guest_timeout" "$limactl" shell titan-k3s -- sh -c 'free -m; cat /proc/pressure/memory'
    code=$?
    if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
      echo "titan-k3s: no answer within ${guest_timeout} s"
    elif [ "$code" -ne 0 ]; then
      echo "titan-k3s: limactl exited $code"
    fi
  } >> "$log" 2>&1
  sleep "$every"
done
echo "== stop $(date -u +%FT%TZ)" >> "$log"
