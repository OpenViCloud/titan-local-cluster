# What differs between the two deployments of the local cluster, by the host's `uname -s`.

# vm_dir <uname -s>: the folder of the Lima VM files for this host's OS; nothing and status 1 for any other OS.
vm_dir() {
  local lima
  lima=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  case "$1" in
    Darwin) echo "$lima/macos" ;;
    Linux) echo "$lima/ubuntu" ;;
    *) return 1 ;;
  esac
}

# incus_endpoint <uname -s> <core.https_address of titan-incus>: the URL titan-k3s dials for the Incus API. macOS
# reaches titan-incus's own address over user-v2; Ubuntu goes through the host, Lima's 192.168.5.2, to the forward
# of lima/ubuntu/titan-incus.yaml.
incus_endpoint() {
  local port=${2##*:}
  [ -n "$2" ] || return 1
  case "$1" in
    Darwin) echo "https://$2" ;;
    Linux) echo "https://192.168.5.2:$port" ;;
    *) return 1 ;;
  esac
}
