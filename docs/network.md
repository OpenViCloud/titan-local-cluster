# Local cluster: network

> The network of the local cluster (cluster `local`, [topology §naming](topology.md#naming)), **built** in the LOCAL-CLUSTER iteration. The cluster has two equal deployments, on macOS and on Ubuntu; they differ in the network between the two VMs ([§vm-to-vm](#vm-to-vm)). The machine files (`lima/provision/incus.sh`, written `provision/incus.sh` below; VM files in `lima/macos/` and `lima/ubuntu/`) are in this repository. Machines and RAM: [topology.md](topology.md).
> Source: meeting with Tôn Chủ, 2026-10-08. Scope: reachable from this machine only ([topology §decisions](topology.md#decisions), L-3).

<a id="picture"></a>
## The whole picture

```
 Browser on the host (Mac or Ubuntu machine)
   │  http://portal.localhost:8080 · api.localhost:8080 · auth.localhost:8080 · admin.localhost:8080
   ▼  (127.0.0.1 only)
 Lima port-forward 127.0.0.1:8080 ──► titan-k3s :80 ── k3s ingress ──► Service
                               │
                               │ incus-worker calls titan-incus:8443 (endpoint per OS, §vm-to-vm)
                               ▼  macOS: over the Lima network "user-v2" (VM ↔ VM)
                               ▼  Ubuntu: over the host's 127.0.0.1 (https://192.168.5.2:8443)
                          titan-incus
                               ├── ovnbr (Incus bridge with no address; the host holds the IPv6 gateway)
                               │     └── ovnup (physical uplink; only networks with public IPv6 attach to it)
                               └── OVN net-<networkId> ── customer VMs (private IPv4 only)

 Each Lima VM reaches the Internet through Lima's NAT (image pulls, packages).
```

<a id="host-access"></a>
## The host reaches the cluster

Measurements K-1 and B-1 below are from the Mac. On Ubuntu (2026-10-27) only the TCP sockets Lima opens are measured: `127.0.0.1` for `8080`, `6443`, `8443`, `30833`, unreachable from other machines on the LAN; other LoadBalancer ports and UDP are not measured.

**Rules**
- Turn on the ingress k3s ships (Traefik + ServiceLB). Staging turns both off because it has cloudflared; local has no cloudflared.
- Lima forwards the guest's port 80 to the host's `127.0.0.1:8080`. Not the Mac's port 80: measured K-1, for a port below 1024 Lima listens on **every** interface (`*:80`, public IPv6 included), not `127.0.0.1`. At 8080 only `127.0.0.1:8080` is left; LAN and public IPv6 are refused.
- Lima does **not** keep `ignore` rules on every forwarding path: it still opens every k3s LoadBalancer port and every UDP socket of the guest, and opens ports below 1024 on **every** interface. Measured B-1: Traefik `443` accepts TCP from the LAN and from public IPv6; UDP `67` (DHCP of `ovnup` while it was a bridge) opens `*:67`. So block at the **source**: k3s turns off Traefik's `websecure` port; `ovnup` is a `physical` uplink, so it has no dnsmasq ([§uplink](#uplink)). After that every port Lima opens on the Mac is `127.0.0.1`.
- Hostnames end in `.localhost`. Browsers point that suffix at `127.0.0.1` on their own; no `/etc/hosts` edit.
- Keycloak's issuer is `http://auth.localhost:8080`. The portal, the admin portal and the control plane use that issuer.

| Hostname | Goes to |
|---|---|
| `portal.localhost` | customer portal |
| `admin.localhost` | admin portal |
| `site.localhost` | site (public pages) |
| `api.localhost` | control plane |
| `auth.localhost` | Keycloak |
| `argocd.localhost` | ArgoCD UI |

**Why.** Each new origin needs its redirect URI and CORS declared once. Fixed names are declared once and do not move with a `port-forward` port.

<a id="vm-to-vm"></a>
## titan-k3s talks to titan-incus

**Common rules**
- Cluster `local` in the control plane's config (`Clusters__0__Endpoint`, `titan-ops features/cluster/design.md#cluster-from-config`) points at the Incus API endpoint of the host running the cluster and pins the server fingerprint. The endpoint must stay the same across restarts.
- The endpoint depends on the host OS. ConfigMap `control-plane-clusters` (`gitops/control-plane/kustomization.yaml`) holds the macOS endpoint. `lima/scripts/join-cluster.sh` writes this host's endpoint (by `uname -s`, function `incus_endpoint` of `lima/scripts/host-os.sh`) into Secret `titan-dev/control-plane-cluster`, with `Clusters__0__ServerFingerprint` and the client identity. The Secret comes after the ConfigMap in `envFrom` (`base/control-plane/patch-env.yaml`), so it wins; `tests/render_test.py` guards that order.

| Host | Endpoint |
|---|---|
| macOS | `https://<core.https_address of titan-incus>` — the `user-v2` address, `https://192.168.104.1:8443` |
| Ubuntu | `https://192.168.5.2:8443` — through the host |

- Dev's S3 uses the name `lima-titan-k3s.internal` as its endpoint ([topology §s3](topology.md#s3)). Who answers that name depends on the OS:
  - macOS: the `user-v2` network resolves `lima-<VM name>.internal` to that VM's IP, from both VMs and from pods of `titan-k3s` (measured 2026-10-26: `lima-titan-k3s.internal` ⇒ `192.168.104.3`, `lima-titan-incus.internal` ⇒ `192.168.104.1`), so it does not depend on the DHCP address.
  - Ubuntu: Lima's `hostResolver.hosts` answers. Inside `titan-k3s` ⇒ `192.168.5.15` (itself); inside `titan-incus` ⇒ `192.168.5.2` (the host).
- To debug with the `incus` client from the host: `limactl shell titan-incus`, then run `incus` inside the VM.

**On macOS** (Lima `vz`, `lima/macos/`)
- Both Lima VMs use the network `lima: user-v2`. It lets the VMs see each other without root on the Mac. Measured S-0: with `user-v2` declared it is the VM's **only** NIC (`eth0`) and carries the default route to the Internet; `titan-incus` gets `192.168.104.1`.
- `incusd` listens only on the `user-v2` address of `titan-incus`, port 8443. That port is not forwarded to the Mac. The API is not open to anything outside.

**On Ubuntu** (Lima `qemu`, `lima/ubuntu/`; Tôn Chủ decided 2026-10-27)
- No `user-v2`. QEMU 10.2.1 aborts under load on the `-netdev socket` NIC that `user-v2` uses: `net_socket_send` passes `-1` into `net_fill_rstate` when `recv()` returns `EWOULDBLOCK` ⇒ `assert(size == 0)`. Control run (measured 2026-10-27): the same VM with `user-v2` aborts on its first download; without `user-v2` it downloads 3×625 MB with no error.
- The two VMs talk over the host's `127.0.0.1`. Lima forwards the Incus API `192.168.5.15:8443` of `titan-incus` ⇒ the host's `127.0.0.1:8443`, and the SeaweedFS NodePort `30833` of `titan-k3s` ⇒ the host's `127.0.0.1:30833`. Besides those two ports the VM files only declare ingress `80` ⇒ `127.0.0.1:8080` and the Kubernetes API `6443` of `titan-k3s` as on macOS, the rest `ignore` (`lima/ubuntu/titan-{incus,k3s}.yaml`); `ignore` rules do not block every forwarding path ([§host-access](#host-access)), and UDP on Ubuntu is not measured.
- Guests and pods reach the host at `192.168.5.2` (`host.lima.internal`): `titan-k3s` reaches the Incus API at `https://192.168.5.2:8443`, `titan-incus` reaches the SeaweedFS NodePort through the host.
- Other machines on the LAN cannot get in: forwards bind only the host's `127.0.0.1` (measured 2026-10-27: curl to the host's LAN IP exits 7).
- Programs on the host can reach port 8443. The Incus API is still guarded by TLS + trust of the client certificate.

**Why.** The Incus API is root over every customer VM. On macOS, keeping it inside the network between the two VMs means no program on the Mac or on the LAN can reach it. On Ubuntu, `user-v2` makes QEMU abort, so the path between the two VMs goes through the host; forwards only bind `127.0.0.1`, so the LAN cannot reach it, and on the host only a holder of a trusted client certificate can call the API.

<a id="uplink"></a>
## OVN uplink and customer networks

**Rules**
- OVN runs standalone on one machine (package `ovn-central`), as in the INCUS-1 lab.
- `ovnup` is a `physical` uplink shaped like `singapore01`'s, with parent `ovnbr` — a bridge Incus creates with `ipv4.address=none`, `ipv6.address=none`. The name `ovnup` is in the provider config of cluster `local`.
- `ovnup` declares `ipv4.routes` = `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` with `ipv4.routes.anycast=true`, no IPv4 gateway, no NAT: Incus refuses a network on an uplink whose IPv4 CIDR the uplink does not route (measured 2026-10-16: while `ovnup` was a bridge without `ipv4.routes`, a network asking for IPv6 gave up with `Uplink network doesn't contain … in its routes`).
- A customer network without IPv6 keeps the production rule: private IPv4 only, **no uplink** (`network=none`), `ipv4.nat=false`, `ipv6.address=none` (`OpenViCloud/titan-incus-worker:resource/network/create.go`). See `titan-ops architecture/vm-network.md#no-ipv4-egress`. Two tenants may use the same CIDR.
- Picking a subnet for `ipv4.address=auto`, Incus skips every `10.x.x.0/24` in the host's route table (`network_utils.go:601-621`), so a `10.0.0.0/8` route on the host leaves it no subnet (`network_utils.go:645-716`). A `physical` uplink does not install routes of `ipv4.routes` on the host (measured 2026-10-16: after creating a `physical` uplink with `10.0.0.0/8`, the host's IPv4 route table did not change, and a `network=none` network with `auto` still found a subnet).
- Incus also skips a subnet whose `.1` or `.254` answers ping or TCP 22 (`pingSubnet`, `network_utils.go:741-790`), and every `10.x` address tried had ping answered through `eth0`. `provision/incus.sh` builds the nft table `inet titan-auto-subnet` at every boot: it drops ping and TCP 22 leaving towards `10.0.0.0/8` through `eth0` (TCP 22 after `pingSubnet`, not measured on its own). With that table ping is silent and `auto` finds a subnet; a network with no CIDR reaches `Active` through the worker. The table also drops ping and TCP 22 from `titan-incus` to real `10.x` hosts behind the Mac.
- Result: customer VMs on local have **no Internet**, and the Mac cannot reach them directly either. To get in, run `incus console` or `incus exec` inside `titan-incus`.
- Storage pool: thin `lvm` on a 40 GiB loop file, like the labs where volumes and snapshots were measured.

**Why.** Opening the Internet to customer VMs on local would measure a production rule that does not exist.

<a id="ipv6"></a>
## Public IPv6 on the documentation range

**Rules**
- `ovnup` carries IPv6 shaped like `singapore01`'s (`titan-ops infra/incus/design.md#ipv6-address-plan`) on the documentation block `2001:db8:0:d400::/56`: `ipv6.gateway` = `::1/64` of the first `/64`, `ipv6.ovn.ranges` = `::100`–`::1ff` (OVN routers), `ipv6.routes` = every other `/64`, `ovn.ingress_mode=routed`.
- The `titan-incus` host is the `::1` gateway (on `singapore01` it is OVH's router): at every boot `provision/incus.sh` turns IPv6 on for `ovnbr` (`disable_ipv6=0` — Incus creates the bridge `ipv6.address=none` with IPv6 off, measured 2026-10-16) and puts `2001:db8:0:d400::1/64` on it.
- At every boot `provision/incus.sh` sets 255 routes `d4nn::/64 via d400::1nn dev ovnbr` on `titan-incus`. Those are the static routes OVH holds for `singapore01`; here the host holds them.
- Cluster `local` has `Clusters__0__Ipv6Block=2001:db8:0:d400::/56` in the control plane's config (`gitops/control-plane/kustomization.yaml`, `titan-ops features/cluster/design.md#cluster-provider-settings`), beside `Clusters__0__OvnUplinkNetwork=ovnup`; without either, creating a network that asks for public IPv6 returns `422 IPV6_NOT_AVAILABLE`, so no load balancer can be created (a load balancer needs a network with public IPv6). The block must be the block `provision/incus.sh` routes on `ovnup` (`IPV6_BLOCK_PREFIX`); `tests/render_test.py` guards that the two match. Measured 2026-10-28 on Ubuntu: before that line, the provider's load balancer acceptance test failed at network creation with `422 IPV6_NOT_AVAILABLE`; after it (`65ab278`), all 8 acceptance tests of the provider PASS, `TestAccLoadBalancer_CreateImportUpdateInPlaceDestroy` included.
- The documentation range does not reach the Internet: VMs are only reachable from `titan-incus`.
- No dnsmasq, no `dns.nameservers` (unlike `singapore01`): the documentation range does not reach the Internet. After the change, `titan-incus` has no Incus UDP DNS socket left and Lima opens no new port on the Mac (measured 2026-10-16).

**Why.** Without `ipv6Block` dev cannot create an IPv6 network, so no load balancer can be measured before a release.

<a id="ports"></a>
## Port matrix

| From → To | Port | Purpose |
|---|---|---|
| Host (127.0.0.1:8080) → titan-k3s | TCP 80 | Ingress: portal, admin, API, Keycloak, ArgoCD |
| Host → titan-k3s | TCP 6443 (Lima forward, 127.0.0.1) | `kubectl` |
| titan-k3s (pods incus-worker, control-plane) → titan-incus | macOS: TCP 8443 on `user-v2` · Ubuntu: TCP 8443 through `192.168.5.2` (forwarded to the host's `127.0.0.1:8443`) | Incus API, mutual TLS |
| titan-incus → SeaweedFS in titan-k3s (Ubuntu) | TCP 30833 through `192.168.5.2` (forwarded to the host's `127.0.0.1:30833`) | Incus uploads backups to dev's S3 (macOS: directly over `user-v2`) |
| titan-k3s, titan-incus → Internet | Lima's NAT | ghcr images, VM images, OS packages |
| Mac (127.0.0.1) → titan-k3s | TCP 10250, 10255 · UDP 8472, 5353 | Opened by Lima on its own (kubelet, flannel, mDNS); unused, localhost only. Measured on the Mac; not on Ubuntu |
| Customer VM → anywhere outside its network | none | The production rule |

<a id="open-questions"></a>
## Settled questions

| # | Question | Tôn Chủ decided (2026-10-08) |
|---|---|---|
| N-1 | Hostnames `*.localhost`, or another name (e.g. `*.titan.test`)? | `*.localhost` ([topology §decisions](topology.md#decisions), L-9) |
| N-2 | Do customer VMs on local need the Internet? | No (L-10) |

<a id="unmeasured"></a>
## Unmeasured assumptions

| Assumption | Owner |
|---|---|
| macOS: `user-v2` lets the two Lima VMs see each other, and the IP stays across restarts | Eos |
| Ubuntu: the address `192.168.5.15` of Lima's default network stays across restarts (measured on two fresh VMs, not across a restart) | Eos |
| Browsers point `*.localhost` at `127.0.0.1` and Keycloak accepts an `http` issuer | Hestia |
| OVN on `ovnup` works inside Lima `vz` (MTU, checksum offload) | Hestia |
