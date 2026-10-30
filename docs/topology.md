# Local cluster: k3s and Incus on one Mac or Ubuntu machine

> Design of the one-machine dev/lab environment, **built** in the LOCAL-CLUSTER iteration on a Mac. Since 2026-10-20 the machine files (`mac/`, `lima/` since 2026-10-27) and dev's GitOps (`gitops/`) are in this repository (L-19); since 2026-10-29 this design is here too (it was in titan-ops, which is private). Network: [network.md](network.md). Since 2026-10-27 local has an Ubuntu deployment equal to the macOS one (L-24): names in [§naming](#naming), machines in [§layout](#layout).
> Source: meeting with Tôn Chủ, 2026-10-08.
> Oracle (OCI) **is still staging**. The local cluster does not replace it.

A titan-ops doc is named by its path under titan-ops's `docs/`, as `titan-ops architecture/platform-infra.md#gitops-flow`: titan-ops is private, so this repository carries no link into it.

<a id="decisions"></a>
## Tôn Chủ's decisions

| # | Decision (2026-10-08) |
|---|---|
| L-1 | The local cluster is a **parallel dev/lab** environment. Staging stays on Oracle (question 1a) |
| L-2 | Incus runs **one node**, no multi-node cluster (question 2a) |
| L-3 | The cluster is reachable **from this machine only** (`localhost`, port-forward). No tunnel, nothing public (question 4a) |
| L-4 | Incus cannot be installed on macOS itself ([§incus-on-macos](#incus-on-macos)). Customer VMs are **nested KVM** inside a Linux VM, option (a). Turned on once spikes S-1/S-2 PASS |
| L-5 | k3s runs on its **own Lima VM** `titan-k3s`. Not k3d on Docker Desktop ([§k3s-on-macos](#k3s-on-macos)) |
| L-6 | Each time the local cluster runs, **Docker Desktop is off**. Not enough RAM for both. Since L-18: the machine runs no Docker |
| L-7 | Images are **built by CI and pushed to ghcr, like staging**. ~~The Mac builds no image~~ changed 2026-10-21: dev may run an image built in `titan-incus` from a pushed commit of a branch, before merge (L-20); staging still takes only CI images. Changed back 2026-10-21 (L-20 removed): the Mac builds no image |
| L-8 | Deploy by **ArgoCD**, ~~following `main` only~~ changed 2026-10-20: following `main` of `OpenViCloud/titan-local-cluster`, ~~titan pins one commit (L-19)~~ changed 2026-10-26: titan-ops is not read (L-21). ~~Local runs merged code only~~ changed 2026-10-21: a code repository's PR reaches dev before merge (L-20). Changed back 2026-10-21 (L-20 removed): local runs merged code only. Since L-17: staging comes **after** local |
| L-9 | Names are `*.localhost` ([network §host-access](network.md#host-access)) |
| L-10 | Customer VMs on local do **not** reach the Internet, as the production rule says |
| L-11 | `MaxVms = 3`. Size `l` templates do not run on local. No offering of its own for local |
| L-12 | Spikes run **after** Tôn Chủ has reviewed this design |
| L-13 | Cut RAM with R-1 (stop the cluster when unused) + R-2 (trim the k3s workload) ([§ram-budget](#ram-budget)) |
| L-14 | `titan-incus` **replaces `incus-lab`**: one Incus machine carries both cluster ~~`local-mac`~~ `local` (changed 2026-10-27, L-25) and the lab that records REST responses ([§replaces-incus-lab](#replaces-incus-lab)) |
| L-15 | Switch **after INCUS-3 finishes** its lab work. `incus-lab` **was deleted** 2026-10-09 13:20 (+07), by the INCUS-3 session on Tôn Chủ's order |
| L-16 | (2026-10-09) ~~This cluster is the **Mac's** local cluster: cluster `local-mac`~~ changed 2026-10-27: one local cluster, two deployments macOS and Ubuntu, cluster `local` (L-24, L-25); files in ~~`local-cluster/mac/`~~ changed 2026-10-20: ~~`mac/` of this repository (L-19)~~ changed 2026-10-27: `lima/` of this repository, VM files in `lima/macos/` (L-24). ~~Other members may build a Linux local cluster later ([§naming](#naming))~~ changed 2026-10-27: local has two equal deployments, macOS and Ubuntu (L-24) |
| L-17 | (2026-10-09) The local cluster is the **dev** env; both envs deploy from `main`. ~~Merge ⇒ dev gets the image at once~~ changed 2026-10-20: dev gets images when this repository pulls them, the shared base when it merges here (L-21); staging only gets **images** that PASSed on dev, PR by PR, through `scripts/promote-staging.py` (`titan-ops architecture/platform-infra.md#gitops-flow`). Skipping dev only on an explicit waiver by Tôn Chủ. ~~PR by PR~~ changed 2026-10-12: promote runs in `release:run-release`, which Tôn Chủ calls outside iterations. ~~staging~~ changed 2026-10-28: promote goes to prd, `scripts/promote-prd.py` |
| L-18 | (2026-10-09) The dev machine **runs no Docker**. The control plane's Integration tests run on the dev cluster's Postgres ([§runbook](#runbook)) |
| L-19 | (2026-10-20) The dev cluster's definition and dev's GitOps leave titan for the public MIT repository [`OpenViCloud/titan-local-cluster`](https://github.com/OpenViCloud/titan-local-cluster); the docs stay in titan (until 2026-10-29). ~~The dev overlay builds on titan's staging overlay (remote base); every titan reference pins **one** full commit~~ changed 2026-10-26 (L-21). The reason for pinning still holds for staging, which now pins this repository: ArgoCD (v2.11.2, measured 2026-10-20 on dev) caches renders by revision of the source repository, so a base changed on a branch is not re-rendered, and not applied without a hard refresh + a manual sync (`titan-ops architecture/platform-infra.md#gitops-flow`). ~~Application names stay (`*-local-mac`, `root-local-mac`).~~ Changed 2026-10-27 (L-25). Cutting the running cluster over to the new repository: 10/10 apps `Synced/Healthy` within 20 s, no pod restarted |
| L-20 | ~~(2026-10-21) Dev runs images **built on the Mac** from HEAD of a code repository checkout: this repository's `scripts/build-local.py` builds with buildkit in `titan-incus`, imports into `titan-k3s`'s containerd, writes `newTag` `local-<12 hex>`; a push to `main` here is a deploy. A PR changing behaviour in a code repository reaches dev before merge; after merge dev goes back to that repository's CI image. Promote refuses local tags~~ removed 2026-10-21: code of a code repository reaches dev only as a CI image, after merge ([§local-build](#local-build)) |
| L-21 | (2026-10-26, Tôn Chủ decided) The manifests every env shares are in `base/` here; dev's overlay builds on `../../base/<app>` and reads nothing of titan-ops (private), so an outsider can build the dev cluster (`titan-ops architecture/platform-infra.md#gitops-flow`). Staging's overlay in titan builds on that base, pinning one commit of this repository; promote moves the pin. Measured at the switch: dev's render before and after has the same content (only the env order of `control-plane`, `incus-worker` differs; `titan-db` gets an explicit namespace) |
| L-22 | (2026-10-26, Tôn Chủ decided) The dev cluster needs no service with an account or a credential: public GitHub, apt, `get.k3s.io`, Helm repositories, public images and VM templates are allowed. Dev's secrets are generated on the Mac and kept in `~/.config/titan-local-cluster/secrets.env`, not in Infisical; GHCR images are pulled anonymously ([§secrets](#secrets)). One cluster for everyone: Tôn Chủ's dev takes the stranger's path (a host behind a TLS-inspecting proxy adds its CA, and builds `titan-k3s` off the proxy, [§extra-ca](#extra-ca)) |
| L-23 | (2026-10-26, Tôn Chủ decided) Dev's S3 is SeaweedFS in `titan-k3s`, data in a Mac directory, over TLS with a CA generated on the Mac ([§s3](#s3)); dev leaves R2 and moves over with an empty DB, the R2 store is not copied. Rebuilding `titan-k3s` when the store has data restores the DB from it ([§runbook](#runbook)) |
| L-24 | (2026-10-26/27, Tôn Chủ decided) Local is **one** dev environment with two equal deployments, macOS and Ubuntu, on the same GitOps. This repository: `lima/` is shared (provision, scripts, tests, runner), VM files in `lima/macos/` (Lima `vz`, `user-v2`) and `lima/ubuntu/` (Lima `qemu`); `up.sh` picks by `uname -s`. Ubuntu uses Lima QEMU **without** `user-v2`: QEMU 10.2.1 aborts under load on `user-v2`'s socket NIC ([§layout](#layout)). ~~Cluster id and Application names stay `local-mac`; renaming is a later story~~ changed 2026-10-27 (L-25) |
| L-25 | (2026-10-27, Tôn Chủ decided) Local's names carry no OS, because both deployments share GitOps: cluster `local` (`Local`), Titan's Applications `*-local` (the four infrastructure apps `cert-manager`, `cnpg-operator`, `plugin-barman-cloud`, `seaweedfs` have no suffix), root `root-local`, trust name on Incus `titan-local` ([§naming](#naming)). The running cluster cut over to the new names with no manual DB step: this repository's PreSync and PostSync hook `control-plane-rename-cluster-id` changes `cluster_id` `local-mac` ⇒ `local` in six `core` tables with one SQL statement (a `vm_template_clusters` row that already has a `local` copy loses its `local-mac` copy), and `lima/scripts/drop-old-applications.sh` deletes any `*-local-mac` Application left. Measured 2026-10-27 on Ubuntu (`e14e949`): PreSync changed 24 rows, PostSync 0, no `local-mac` row left; the old root pruned every old Application, itself included (ArgoCD log), the script had nothing left to delete; 13/13 apps `Synced/Healthy`, Z-1 PASS. macOS not measured |

<a id="naming"></a>
## Names (L-16, L-25)

Local has two equal deployments (L-24): macOS and Ubuntu, from the same repository `OpenViCloud/titan-local-cluster`. Only the VM files differ by OS.

| Thing | macOS | Ubuntu |
|---|---|---|
| Machine files + scripts | shared `lima/`; VM files `lima/macos/` | shared `lima/`; VM files `lima/ubuntu/` |
| Cluster id · name | `local` · `Local` | as macOS |
| Overlay · app-of-apps · root · Keycloak | `gitops/<app>/` · `gitops/apps/` · `root-local` · `gitops/keycloak/values.yaml` + `realm-import/` + `ingress/` | as macOS: same GitOps |

Since L-19 the GitOps directories here carry no machine type; since L-25 neither do Application, cluster and root names. The only per-OS directories are `lima/macos/` and `lima/ubuntu/`: `lima/scripts/up.sh` picks by `uname -s` (`lima/scripts/host-os.sh`, function `vm_dir`). Each OS directory has a symlink `provision -> ../provision`, because Lima 2.2.1 refuses `..` in a provision path.

Shared, not per machine type: this design ([`docs/`](.)), the Keycloak realm (one realm, redirect `*.localhost:8080`), the `*.localhost` names (L-9).

**Why.** ~~The same Titan may run on several machine types. With the machine type in the cluster id and the app names, two clusters never collide in logs, in the DB, and in gitops.~~ Changed 2026-10-27 (L-25): macOS and Ubuntu are two deployments of **one** environment on the same GitOps, not two clusters, so the names carry no OS; each dev machine runs a cluster of its own, no two clusters share a DB or a log.
What is per OS is how the VMs are built: macOS uses Lima `vz`, nested KVM, network `user-v2`; Ubuntu uses Lima `qemu`, nested KVM, no `user-v2` ([§layout](#layout)). ~~Linux runs Incus on the machine itself, without that VM layer.~~ Changed 2026-10-27: Ubuntu runs the same two Lima VMs as macOS (L-24).

<a id="incus-on-macos"></a>
## Incus on macOS itself: **not possible**

**Facts**
- The Incus daemon (`incusd`) runs on Linux only. It needs the Linux kernel's namespaces, cgroups and KVM.
- `brew install incus` is the **client** only. The formula's description reads "CLI client for interacting with Incus" (measured `brew info incus`, 2026-10-08, version 7.5.1).
- macOS has no KVM. The macOS hypervisor (`Virtualization.framework`) serves macOS programs only. Incus cannot drive it.
- The worker always creates instances of type **VM**: `api.InstanceTypeVM` at `OpenViCloud/titan-incus-worker:resource/vm/create.go:173`. Template images are type VM too: pulled at `OpenViCloud/titan-incus-worker:resource/template/sync.go:143`, imported at `OpenViCloud/titan-incus-worker:incus/provider/incus.go:231`.

**Consequence.** Incus must run in a **Linux VM** on the Mac. Customer VMs are therefore on the **second level**: nested.
The only way not to nest is for customers to run Incus **containers** instead of VMs.

| | (a) Nested KVM in a Linux VM | (b) Incus containers, no nesting |
|---|---|---|
| The customer gets | A real VM, as in production | A container: same kernel as the Incus node |
| Code change | No | Yes: the worker must create `container`, templates must pull container images. Production stays VM ⇒ local differs from production |
| Requirement | M3 chip or later, macOS 15 or later, Lima `vz` with `nestedVirtualization: true` (like `incus-lab`). This machine: Apple M3, macOS 27.0.1 | None |
| RAM | Each customer VM holds all of its offering's RAM | Only what the container really uses |
| Measured | **Measured** on `incus-lab` 2026-10-08 (lab INCUS-COMPUTE): `/dev/kvm` present, a 1 GiB arm64 VM `Running` ([§spike](#spike)) | Lab INCUS-1 ran 3 containers |

Tôn Chủ chose **(a)** (L-4). Reason: (b) makes local measure something production does not run.

<a id="k3s-on-macos"></a>
## k3s on macOS itself: **not possible** either

- k3s is a Linux-only binary. It needs the Linux kernel's cgroups, namespaces and iptables.
- Every way to run Kubernetes on a Mac (Docker Desktop, OrbStack, Rancher Desktop, k3d) has a Linux VM underneath.
- This machine runs Docker Desktop. Measured 2026-10-08: kernel `6.10.14-linuxkit`, 4 CPU, 3.8 GiB RAM.
- Tôn Chủ chose a separate Lima VM (L-5): k3s on Ubuntu, like staging. The price is turning Docker Desktop off (L-6).

<a id="layout"></a>
## Machine layout

```
macOS (Apple M3 · 8 cores · 16 GB RAM · 133 GB free disk)
│
├── Lima VM "titan-k3s"    (vz · Ubuntu 24.04 arm64 · 2 CPU · 4 GiB · 30 GiB)
│     k3s single-node
│     ├── ArgoCD
│     ├── control-plane · customer portal · admin-portal · incus-worker
│     ├── Keycloak · CNPG PostgreSQL · NATS
│     ├── regression runner (two suspended CronJobs)
│     └── (dropped) cloudflared · cloudbeaver
│
└── Lima VM "titan-incus"  (vz · nestedVirtualization · Debian 13 arm64 · 4 CPU · 7 GiB · 60 GiB)
      Incus 7.0 LTS, 1 node (L-2) · OVN standalone · storage pool
      ├── project t-*   : customer VMs created by Titan (KVM, level 2)
      └── project lab-* : test objects of the lab scripts (L-14)
```

**Ubuntu deployment** (L-24; measured 2026-10-27 on Ubuntu 26.04 x86_64, i5-9400F, 15 GB, Lima 2.2.1, QEMU 10.2.1). Same two VMs, same workload, files in `lima/ubuntu/`:

```
Ubuntu x86_64 (host)
│
├── Lima VM "titan-k3s"    (qemu · Ubuntu 24.04 amd64 · 2 CPU · 4 GiB · 30 GiB)
└── Lima VM "titan-incus"  (qemu · Debian 13 amd64 · 4 CPU · 7 GiB · 60 GiB · customer VMs are nested KVM)
```

- No `user-v2`: QEMU 10.2.1 aborts under load on its `-netdev socket` NIC (`net_socket_send` passes `-1` into `net_fill_rstate` when `recv()` returns `EWOULDBLOCK` ⇒ `assert(size == 0)`). Control run: the same VM with `user-v2` aborts on its first download; without `user-v2` it downloads 3×625 MB with no error.
- The two VMs talk over the host's `127.0.0.1`: the Incus API `192.168.5.15:8443` is forwarded to the host's `127.0.0.1:8443`; the SeaweedFS NodePort `30833` to the host's `127.0.0.1:30833`. Guests and pods reach the host at `192.168.5.2` (`host.lima.internal`). Other machines on the LAN cannot get in (measured: curl to the host's LAN IP exits 7). The Incus API is still guarded by TLS + trust of the client certificate. Network details: [network §vm-to-vm](network.md#vm-to-vm).
- `base: template:_images/<os>`, not `template:debian-13`/`ubuntu-24.04`: those two templates bring `template:_default/mounts`, which mounts the user's home (read-only) into the VM.
- The host needs: KVM (`/dev/kvm` writable), nesting (`kvm_intel` `Y` / `kvm_amd` `1`), `qemu-system-x86` + `qemu-utils`, Lima, kubectl, openssl, python3.

**Rules**
- Use **two** Lima VMs with new names. `titan-incus` replaces `incus-lab` after INCUS-3 finishes (L-14, L-15). Until then `incus-lab` is not touched.
- Every service image is built `linux/arm64` by CI, plus `linux/amd64` since 2026-10-27 (5 code repositories); staging still pulls arm64. The host runs them as they are, no rebuild.
- `titan-incus` runs Debian 13, the same OS as the staging machine `singapore01` (`titan-ops infra/incus/user-stories.md#us-incus-singapore01-01`); `titan-k3s` keeps Ubuntu 24.04.
- The Lima files (`*.yaml`) and cloud-init are in this repository (`lima/`). Nothing is installed by hand in the VMs.
- Must rebuild from scratch with one command, at the **infrastructure + config** layers (off a TLS-inspecting proxy, [§extra-ca](#extra-ca)). The **data** layer (DB, tenants, customer VMs) is disposable. Lost means rebuilt; dev's `titan-db` overlay creates an empty DB (`initdb`, so a stranger with an empty bucket can run it), and rebuilding when the bucket has a store restores through a temporary PR ([§runbook](#runbook) "Rebuild `titan-k3s` from scratch"): dev's Postgres backup (row `titan-db` of [§titan-integration](#titan-integration)) is there to measure the backup path and rehearse restore before staging.

**Why two VMs.** k3s and Incus/OVN both manage nftables, bridges and routes on one kernel. Apart, a fault on one side does not bring the other down, and resetting Incus does not touch Titan's DB.
**The one-VM option** (R-5) saves about 1 GiB and drops the network between the two VMs. The price is a risk of nftables and bridge conflicts, not measured. Tôn Chủ keeps two VMs (L-5). R-5 is only a fallback.

<a id="replaces-incus-lab"></a>
## `titan-incus` replaces `incus-lab`

| | `incus-lab` (then) | `titan-incus` |
|---|---|---|
| Config source | `lab-incus-lab.yaml` in the INCUS-1 evidence, plus steps installed iteration by iteration | Lima file + cloud-init in this repository (`lima/`) |
| Role | Lab only: records REST responses of a real Incus | Titan's cluster `local` **and** the lab |
| RAM | 8 GiB | 7 GiB |

**Rules**
- Incus is installed from **the same 7.0 LTS line** as `incus-lab` (server 7.0.1). The lab recordings (`OpenViCloud/titan-incus-worker:incus/provider/testdata/`) still compare.
- Lab scripts only create objects in projects named `lab-*`. The worker only manages projects `t-*` (`titan-ops architecture/tenancy-and-admin.md#project-name`). The INCUS-3 session takes this rule to Tôn Chủ at its retro.
- The lab and Titan run on the same `incusd`. Lab scripts do not change the server config, the uplink network or the storage pool of cluster `local`.
- `incus-lab` is deleted (L-15). Its old config is in the INCUS-1 evidence (`lab-incus-lab.yaml`).

**Why.** A machine built from a repository can be rebuilt when lost. A lab machine installed by hand over 4 iterations is a snowflake. One Incus machine instead of two also ends the RAM conflict between a lab session and the local cluster.

<a id="ram-budget"></a>
## RAM budget

Measured 2026-10-08 on Oracle staging (`kubectl top`):

| Measured | RAM |
|---|---|
| The whole staging k3s node (OS + k3s) | 4903 Mi |
| All pods | 2264 Mi |
| cloudbeaver (dropped on local) | 644 Mi |
| Keycloak | 593 Mi |
| PostgreSQL (CNPG) | 302 Mi |
| ArgoCD (7 pods) | ≈ 377 Mi |
| control-plane | 136 Mi |
| OVN + Open vSwitch, 1 node (`titan-ops infra/incus/design.md#ovn-cost`, lab INCUS-1) | ≈ 119 MiB |

| Block | Allowance |
|---|---|
| macOS + Tôn Chủ's applications | ≈ 5 GB |
| Docker Desktop (holding 3.8 GiB) | 0: off while the cluster runs (L-6) |
| `titan-k3s` (after R-2; 3 GiB until 2026-10-25, 1 GiB more for cert-manager, the Barman plugin and Postgres running beside tests) | 4 GiB |
| `titan-incus` (OS + Incus + OVN ≈ 1 GiB, the rest for customers) | 7 GiB |
| **Total** | ≈ 16 GB, all of the Mac's RAM: macOS swaps more when both VMs run at their ceilings (this table is measured on the Mac; Ubuntu below) |

Lima's `memory` is a **ceiling**. Measured S-0 on `titan-incus` (phys_footprint of the Virtualization process):
- After 3 image pulls and one idle 2 GiB VM: 5368 MB of a 7 GiB ceiling.
- Guest writes 1.5 GiB: 6908 MB. Guest gives it back, page cache of 3.9 GB dropped too: still 6909 MB.
- No balloon device is attached to the VM. RAM returns to macOS only when the VM **stops**.

So after a while each VM holds nearly **all of its ceiling**. The budget below counts ceilings.

Measured A-1 (2026-10-09), after rebuilding `titan-k3s` from scratch:

| When | `titan-incus` on macOS | `titan-k3s` on macOS | macOS free RAM |
|---|---|---|---|
| No customer VM | 2243 MB | 3087 MB | 40% |
| 3 VMs `s` `Running`, idle | 3632 MB | 3087 MB | 37% |

- Each idle `s` VM uses about 185 MiB of its 2 GiB. The ceiling is only reached when the guest really uses RAM, as S-0 measured.
- `titan-k3s` is already near its 3 GiB ceiling. With the regression runner in the cluster, about 270–600 MiB is left available. No pod was OOM-killed.

Ubuntu (measured 2026-10-27, 15 GB host, same ceilings 4 GiB + 7 GiB, [§layout](#layout)): QEMU of `titan-incus` holds its full 7 GiB ceiling while provisioning; the host has 1.2–5 GB available depending on the moment. Not measured: RAM of each VM after provisioning, RAM with customer VMs running, the share of the host OS and applications.

**Cutting RAM (L-13)**
- **R-1:** when unused, `limactl stop` both VMs. RAM goes to 0. Starting again takes about 1–2 minutes.
- **R-2:** trim the workload, patched in dev's overlay, staging unchanged:
  - Cap Keycloak's JVM heap.
  - ArgoCD drops dex, notifications, applicationset. The UI is reached with the admin account.
  - Turn off k3s's metrics-server.
  - k3s runs with `GOMEMLIMIT=512MiB` (systemd drop-in, `lima/provision/k3s.sh`). Measured 10 minutes after restart both ways: k3s 723 ⇒ 645 MiB, equal CPU time (1:03 / 1:02); guest RAM used 2137 ⇒ 2046 MiB. With no limit, k3s grows by the hour: 883 MiB after 1 hour 46 minutes.
  - PostgreSQL requests 256 MiB (overlay `gitops/titan-db/`); it uses about 100 MiB. The limit stays 1 GiB. A request only reserves room for scheduling, it takes no RAM.
- **Cannot be turned off:** the `kubectl` run by Lima's guest agent (≈ 115 MiB) forwards Traefik's LoadBalancer port 80 to `127.0.0.1:8080`. Removing it ⇒ no way into the cluster. Dropping it needs Traefik to open a real socket in the guest (hostNetwork), not tried.
- Fallbacks, not applied: KSM and zram in the VM (R-3, R-4). One VM (R-5).

Customer VMs by offering (`OpenViCloud/titan-control-plane:Titan.Infrastructure/Persistence/VmOfferingConfiguration.cs` `HasData`): `s` 2 GiB · `m` 4 GiB · `l` 8 GiB · `xl` 16 GiB.

**Rules**
- About 6 GiB is left for customers: **3 VMs `s`** at once, or **1 `m` + 1 `s`**.
- Templates that need `l` (`Alma-9-DB`, `Rocky-9-App`) **cannot run** on local.
- Tenant quota on local is `MaxVms = 3`.

**Why.** When RAM runs out, macOS swaps. Then everything slows down, Tôn Chủ's own work session included.

<a id="spike"></a>
## Spike: measure first, build after

Under the rule "a machine not yet measured is measured first, coded after": no overlay or script was written before the spikes PASSed. The spikes ran after Tôn Chủ reviewed the design (L-12).

| # | Measure | PASS when | Result on `titan-incus` (2026-10-09) |
|---|---|---|---|
| S-1 | Lima `vz` + `nestedVirtualization: true` on this machine | The guest has `/dev/kvm`, and `incus info` reports `virtual-machine` support | **PASS**: `/dev/kvm`, Incus 7.0.1 driver `lxc \| qemu` |
| S-2 | A VM `s` (2 GiB, arm64) boots under Incus | `incus exec` gets in, the guest sees 2 GiB | **PASS**: `Running`, agent after ~20 s, guest sees 1963 MiB, `aarch64` |
| S-3 | arm64 VM images of 3 templates (Ubuntu 22.04, Alma 9, Rocky 9) on the image server the worker uses | Pulled over simplestreams, type VM, arm64 | **Partial FAIL**: Ubuntu 22.04 arm64 exists. Alma 9 and Rocky 9 have **no** arm64 VM image on the image server; Incus silently pulls the x86_64 one, and creating the VM is refused |
| S-4 | A pod in `titan-k3s` reaches the Incus API of `titan-incus` | `curl` to port 8443 from a pod returns `/1.0` | **PASS** at K-1: `/1.0` returns `auth: untrusted` |

Raw output: §Evidence of titan-ops's `release:regression` skill.

<a id="titan-integration"></a>
## Wiring Titan to the local Incus

Missing any row below breaks the first build.

| Item | Why | Notes |
|---|---|---|
| A dev overlay per app, `gitops/<app>/`: `resources` = `../../base/<app>` plus patches and an image tag of its own | Manifests shared with staging (L-21). The tag is written by `scripts/pull-images.py` (images CI published on `main`, L-7), run on the dev machine; titan builds no image ⇒ dev is ahead of staging until promote (L-17) | Patches: hostname, cluster, issuer and `MetadataAddress`, Keycloak's DB host, the realm's origins, backup bucket, smaller requests. An `images` entry is the name `base/<app>` gives the image; another name and `pull-images.py` stops (an unmatched one would leave dev silently running base's placeholder image) |
| App-of-apps `gitops/apps/` pointing at `gitops/<app>/` | Local ArgoCD follows `main` of this repository (L-8, L-19). Root `root-local` **syncs itself** (`automated`, `prune` + `selfHeal`), unlike staging's root (manual sync): nobody syncs the local cluster by hand, except a manual sync of `keycloak-local` after bootstrap changes a password ([§secrets](#secrets)) | Apps cloudflared, cloudbeaver dropped. The regression runner is app `regression-runner-local` (`gitops/regression-runner/`, namespace `titan-auth-dev`): two suspended CronJobs, a run copies one into a Job ([§runbook](#runbook)). Third-party charts (`cnpg-operator`, `nats`) take values from `base/`; `keycloak` takes `base/keycloak/values.yaml`, `realm-import-beta-user-2` (second test user, its own hook) in `base/keycloak/`, `realm-import` through `gitops/keycloak/realm-import/` (base plus ConfigMap `keycloak-realm-origins`: the two portals' origins), plus `gitops/keycloak/values.yaml` + `ingress/` |
| `titan-db` backup to bucket `titan-backup-dev` of SeaweedFS ([§s3](#s3)): overlay `gitops/titan-db/` adds component `backup` of `base/titan-db/components/` and patches `destinationPath`, `endpointURL`, `endpointCA` of the `ObjectStore`; `gitops/apps/` has `cert-manager`, `plugin-barman-cloud` (plugin in `base/barman-cloud-plugin`) and `seaweedfs` | Dev runs the backup path staging will run, through git; things applied by hand are lost on a rebuild | `tests/render_test.py` (`DevBackup`, `DevS3`) fails when the `ObjectStore`'s bucket or endpoint differs from dev's control plane `BackupTarget__*`, or lacks `endpointCA` |
| Dev's `titan-db`: a new cluster `initdb`, archiving under `titan-db-dev`, the name dev writes since the namespace move of 2026-10-28; no `restore` component on `main` (the move of 2026-10-28 added it in one PR and removed it in the next) | A stranger has an empty bucket: restore on `main` finds no backup and the DB does not come up (measured 2026-10-27, stranger run: `no target backup found`). An empty bucket takes any name, and dev writes exactly that name, so barman does not refuse. Rebuilding when the bucket has a store is a restore through a temporary PR ([§runbook](#runbook)) | `tests/render_test.py` (`DevStartsEmpty`): `initdb` only, no `externalClusters`, writes `titan-db-dev` |
| Cluster `local` | Base has no cluster list; each overlay sets its env's cluster (staging: `singapore01`) | |
| Cluster `local` in the control plane's config (`gitops/control-plane/kustomization.yaml`) + Incus trusting Titan's client certificate | No cluster in the config ⇒ `404 CLUSTER_NOT_FOUND`; a cluster with no identity (Secret `control-plane-cluster` missing) ⇒ the control plane does not start; a cluster with an identity the cluster does not trust ⇒ the catalog returns `503 CLUSTER_UNTRUSTED` (`titan-ops features/cluster/design.md#cluster-from-config`, `titan-ops features/cluster/design.md#provider-client-identity`) | Endpoint: ConfigMap `control-plane-clusters` holds the macOS endpoint `https://192.168.104.1:8443`; `join-cluster.sh` writes this host's endpoint into Secret `control-plane-cluster` (`Clusters__0__Endpoint`; macOS `https://<core.https_address of titan-incus>`, Ubuntu `https://192.168.5.2:8443`, by `lima/scripts/host-os.sh`). The Secret comes after the ConfigMap in `envFrom` (`base/control-plane/patch-env.yaml`), so it wins; `tests/render_test.py` guards that order. Identity and trust are done by `lima/scripts/join-cluster.sh` (run by each `up.sh`): after building `titan-k3s` with an empty DB, after losing `~/.config/titan-local-cluster/`, or after rebuilding `titan-incus`; rebuilding `titan-k3s` by restore keeps the identity ([§runbook](#runbook)) |
| Pull secret `ghcr-credentials` | Base's `imagePullSecrets` (`base/control-plane/deployment.yaml` and the other apps) asks for it | Dev: empty `auths`, images pulled anonymously ([§secrets](#secrets)) |
| ~~Repository credential for ArgoCD~~ | Since L-21 dev does not read titan-ops; this repository is public | Bootstrap does not create `github-creds`. A cluster built before still has the old Secret; ArgoCD still reads the public repository |
| Keycloak redirect URI + CORS for the `localhost` origin | A new origin must be declared again | |
| The image list in two repositories: `IMAGES` of titan's `scripts/promote-prd.py` (promote) and of this repository's `scripts/pull-images.py` (pull) | Each repository needs it; no test compares the two | Accepted risk. Drift: a row in titan that dev does not run ⇒ promote refuses; a row only here ⇒ promote skips it, prd keeps the old tag silently; a row dropped here ⇒ dev keeps the old tag, promote ships that tag |

<a id="local-build"></a>
## Building on the Mac (L-20): removed

Dev once ran images built on the Mac from a PR branch (L-20): this repository's `scripts/build-local.py`, buildkit in `titan-incus`, tag `local-<12 hex>`. Tôn Chủ removed that path 2026-10-21: code of a code repository reaches dev only as a CI image, after merge (`titan-ops architecture/platform-infra.md#gitops-flow`). This repository keeps nothing of it: no script, no test, no buildkit block in `lima/provision/incus.sh`, `pull-images.py` keeps no `local-*` tag; the buildkit installed on `titan-incus` was cleaned once.

<a id="dev-sync"></a>
## Dev's ArgoCD follows `main` of this repository

- Push to `main` here → new REV of the dev apps: 162 s – ~6 minutes (measured 2026-10-21, before the refresh rule below; `timeout.reconciliation` 180s of `argocd-cm`; once the first reconcile after a push still read the old commit).
- So as not to wait for the reconcile cycle, each push here comes with a `hard` refresh of every Application: `kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml annotate applications.argoproj.io --all -n argocd argocd.argoproj.io/refresh=hard --overwrite` (`iteration:deploy`, step 0 of `release:plan`). Push → REV with a refresh: ≤ 12 s for all 8 apps following this repository (measured 2026-10-22, once: refresh 2 s after the merge, REV read every 5 s).
- **Changes by hand on the cluster do not stay.** `kubectl set image` to another tag (measured 2026-10-21 with a tag built on the Mac) is synced back by ArgoCD to the tag in git after ~1–10 s (`initiatedBy.automated`), although the app declares only `automated.prune` without `selfHeal` — the opposite of the measurement of 2026-10-20 (base changed on a branch, hard refresh ⇒ app `OutOfSync` and auto-sync did not run because the source revision was already synced and there is no `selfHeal`); cause not measured. A tag only lives when it is in git here.

<a id="secrets"></a>
## Secrets of the local cluster

The local cluster needs no service with an account (L-22): this repository is public, images on `ghcr.io/openvicloud` pull anonymously, ArgoCD reads this repository with no credential. `lima/scripts/bootstrap-secrets.sh` (run by `up.sh`) makes every secret on the host, no vault, no token.

| Secret | Used for | Dev takes it from | Staging takes it from |
|---|---|---|---|
| `ghcr-credentials` | Base's `imagePullSecrets` | Empty `auths`: base asks for the name, GHCR serves images anonymously | `GHCR_PAT` (`2-secret`) |
| `titan-db-credentials`, `control-plane-db`, `control-plane-secrets`, `worker-secrets`, `keycloak-admin-secret`, `beta-user-credentials`, `beta-user-2-credentials` | DB passwords, `Internal__Token`, Keycloak admin, test users | `secrets.env` | `2-secret` |
| `control-plane-cluster` | On dev: endpoint (`Clusters__0__Endpoint`) + fingerprint (`Clusters__0__ServerFingerprint`) + Titan's client identity (`ProviderClientIdentity__CertificatePem`/`__KeyPem`, `titan-ops features/cluster/design.md#provider-client-identity`) in one Secret, because `titan-incus` changes fingerprint and identity on each rebuild, and the endpoint depends on the host OS; this endpoint wins over the macOS one in the ConfigMap ([§titan-integration](#titan-integration)). Staging keeps only the identity in the Secret; `singapore01`'s fingerprint is in ConfigMap `control-plane-zones` beside the cluster (changes less often) | `lima/scripts/join-cluster.sh` (endpoint from `core.https_address` of `titan-incus` through `lima/scripts/host-os.sh`, fingerprint from `incus info`, identity from `~/.config/titan-local-cluster/titan-client.{crt,key}`) | Identity: exported once to Infisical + Secret at release L-2 (`titan-ops features/cluster/design.md#cluster-from-config`) |
| `titan-db-backup-credentials` (in `titan-db-dev`), `control-plane-backup-credentials`, `incus-worker-backup-credentials` (in `titan-dev`) | CNPG writes backups and WAL; the control plane reads the bucket (`titan-ops features/backup/design.md#backup-target`); the worker hands the key pair to Incus to upload VM and volume backups (`titan-ops features/backup/design.md#incus-backup`). Three Secrets, one key pair, because a Secret cannot be shared across two namespaces and each side reads its own key names | `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` in `secrets.env`, generated once like the other values | `BACKUP_STAGING_*` (`2-secret`, `backup-credentials.tf`) |
| `seaweedfs-s3-config`, `seaweedfs-tls` (in `seaweedfs`), `s3-ca` (in `titan-db-dev` and `titan-dev`) | SeaweedFS's S3 identity (same key pair); its server certificate; the CA for barman, the control plane and the worker ([§s3](#s3)) | `secrets.env`; `s3.crt`, `s3.key`, `s3-ca.crt` beside it | None: staging uses R2 |
| `admin-test-credentials`, `titan-it-credentials` | User `admin-test` of the dev realm, role `titan_it` of the Integration tests | Fixed test values in the script | `2-secret` (admin-test); no `titan_it` |

**Rules**
- `~/.config/titan-local-cluster/secrets.env` (file mode 600, directory mode 700) holds every value generated once: `TITAN_DB_PASSWORD`, `INTERNAL_TOKEN`, `KEYCLOAK_ADMIN_PASSWORD`, `BETA_USER_PASSWORD`, `BETA_USER_2_PASSWORD`, `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY`. Beside it are the S3 CA and certificates ([§s3](#s3)), an optional `extra-ca.crt` ([§extra-ca](#extra-ca)), and Titan's client identity `titan-client.crt`/`titan-client.key`, generated once by `lima/scripts/join-cluster.sh` (`titan-ops features/cluster/design.md#provider-client-identity`). The first run generates with `openssl rand`; later runs read them back, only add keys a newer script needs, never change an existing value. If `openssl` fails the script stops; it never writes an empty value. The script reads the file line by line by exact key name, no `source`.
- Secrets generated once are applied only when the cluster has no `control-plane-secrets` yet (read with `get`, only `NotFound` counts as absent); `beta-user-2-credentials` alone is applied when it is itself absent, before the early exit, so a cluster built before this tenant gets it too: a running cluster keeps its values, the script reads back no Secret's content. A cluster built before this file keeps its own secrets until its next rebuild.
- Values go through pipes and files: never in argv, never printed.
- User `admin-test` (platform-admin) of the dev realm has a **fixed** test password `admin-test-local-only`, written again on every bootstrap, so an agent signs in to dev's admin console without reading a Secret; not a secret, because dev's hosts are `*.localhost` (like role `titan_it`). Keycloak takes the new value on the next run of `keycloak-config-cli` (PostSync hook, `base/keycloak/realm-import/config-cli-job.yaml`, run on every sync, substituting `$(env:ADMIN_TEST_PASSWORD)`); a changed Secret makes no manifest diff, so after bootstrap sync `keycloak-local` by hand once, like staging's `rotate-admin-test-post-apply.sh`: `kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml -n argocd patch application keycloak-local --type merge -p '{"operation":{"sync":{"revision":"HEAD","syncStrategy":{"hook":{}}}}}'` (not measured on dev).
- Staging's values are not reused.

**Why.**
- A stranger with no Infisical or Cloudflare account must be able to build the cluster (L-22). Measured 2026-10-26: `up.sh` finished with `infisical` and `gh` not on PATH and no GitHub token in the environment; a second run kept `secrets.env` byte for byte. Measured again 2026-10-27 on a simulated empty machine: `env -i HOME=<empty directory> PATH=<directory with only limactl, kubectl symlinks>:/usr/bin:/bin:/usr/sbin:/sbin GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0`, anonymous clone of `main` here, `up.sh` ⇒ exit 0 after 3 minutes 29 seconds, 13 Applications `Synced/Healthy` 11 minutes 40 seconds later, `beta-user` signed in on the second try (known-state `titan-ops status/known-state.md#first-login-tenant-race`); cluster not joined (`titan-ops status/known-state.md#stranger-cluster-not-joined`). The dev cluster was stopped during the run (16 GiB RAM); the run's VMs were deleted with `limactl delete` under the same `HOME`, then the directory (Lima keeps the VM disks in it).
- The file lives outside the VMs, so `limactl delete` and a rebuild give the same values the DB restored from backup holds (owner password of `titan`). The client identity (`titan-client.crt`/`.key`) need not survive `limactl delete`: lose it and `join-cluster.sh` (run by every `up.sh`) generates a new one, trusts it on `titan-incus` and rewrites Secret `control-plane-cluster` in the same run, so there is no `503` window.
- The old rule "no secret in a file" was there to stop a file outside git from being a Terraform input: a missing file makes the plan resolve empty variables and the apply write empty credentials. `secrets.env` is no Terraform input; the script writes no empty value, and a missing file makes it generate new values, not apply empty ones. The cost that is left: lose the file and rebuild the cluster, and the restored DB does not match, as before. Keep that file.
- Anonymous pull (measured 2026-10-26): a pod whose `imagePullSecrets` names a Secret that does not exist, `imagePullPolicy: Always`, still pulls `ghcr.io/openvicloud/titan-landing:48450ad` and runs to completion, with Warning `FailedToRetrieveImagePullSecret`; with `ghcr-credentials` of empty `auths` it pulls `titan-admin-console:cfea591` with no Warning.

<a id="extra-ca"></a>
## A host behind a TLS-inspecting proxy

A host whose traffic goes through a TLS-inspecting proxy (Cloudflare WARP with Gateway TLS decryption) sees every https site signed by the proxy's CA, inside the VMs too: the VMs do not trust it, so ArgoCD cannot fetch this repository or its Helm charts (`x509: certificate signed by unknown authority`, every Application `Unknown`), containerd cannot pull from `ghcr.io`, and Incus cannot pull images. Measured 2026-10-29 on the Mac: from both VMs `github.com`, `api.github.com`, `ghcr.io`, `pkg-containers.githubusercontent.com`, `objects.githubusercontent.com`, `images.linuxcontainers.org`, `get.k3s.io` and `deb.debian.org` all came signed by `Gateway CA - Cloudflare Managed G1 …`, `curl` exit 60.

**Rules**
- Put the proxy's CA (PEM) in `~/.config/titan-local-cluster/extra-ca.crt`. On macOS it is in the keychain: `security find-certificate -a -c "<CA name>" -p > ~/.config/titan-local-cluster/extra-ca.crt` (the name is the issuer `openssl s_client -connect github.com:443` shows). The certificate is public; it stays out of this repository because it belongs to one machine's proxy.
- `lima/scripts/trust-extra-ca.sh` (`up.sh` runs it right after the VMs are up, and again once ArgoCD's CRD is there) puts it in the system store of both VMs, restarts Incus and k3s (with its containerd) when it changed and only then, and patches ArgoCD's `argocd-tls-certs-cm` with one entry per https host an Application of `gitops/apps/` reads. ArgoCD not installed yet (a new `titan-k3s`) ⇒ only the VMs change, and `up.sh` runs the script again once ArgoCD's CRD is there. Behind the proxy a new `titan-k3s` gets no ArgoCD at all (its install job, below; not measured): build or rebuild `titan-k3s` on a network without the proxy, and the CA keeps an existing cluster working behind it. A write into a VM that fails stops the script. No file ⇒ nothing changes (`lima/tests/trust-extra-ca_test.sh`).
- Measured 2026-10-29 on the Mac: before, `curl` from both VMs exit 60 and every Application `Unknown`; after, `curl` 200 from both VMs, and 14/14 Applications `Synced/Healthy` at the commit of `main` after a hard refresh.
- The ConfigMap belongs to ArgoCD's chart. A helm upgrade keeps keys only the live object has (three-way merge), not measured: behind such a proxy no helm upgrade of ArgoCD runs. The chart's install job (`helm-install-argocd` in `kube-system`) cannot fetch the chart: its image keeps its own store, and with the HelmChart's `repoCA` Helm still fails, because it sends the repository's host (`argoproj.github.io`) as the TLS server name when it downloads from `github.com`, and the proxy answers that with a certificate for another name. So the job fails and retries until the chart changes on a machine without the proxy; the ArgoCD already installed keeps running.
- Not measured: a VM provisioned for the first time behind such a proxy (its provision runs before the script); pods that call an https site themselves, which trust only their image's store (Keycloak's GitHub login on dev).

**Why.** The proxy cannot be turned off on that machine (Tôn Chủ, 2026-10-29). Trusting its CA on the host's own VMs changes nothing for a machine without it.

<a id="s3"></a>
## Dev's S3 (SeaweedFS)

**Rules**
- SeaweedFS 4.51 (Apache-2.0) runs one Deployment in `titan-k3s`: Application `seaweedfs`, `gitops/seaweedfs/`, wave `-1` (before `titan-db`). One `weed server` process carries master, volume server, filer and S3. Only dev has this app; staging uses R2 (`titan-ops infra/oci/architecture.md#backup-bucket`).
- S3 speaks TLS only, port 8333, NodePort 30833. One endpoint for everyone: `https://lima-titan-k3s.internal:30833`. On macOS, Lima's `user-v2` network resolves that name to the IP of `titan-k3s`, from `titan-incus`, from the node and from pods (CoreDNS forwards to the node), so the endpoint does not depend on the DHCP address. On Ubuntu, Lima's `hostResolver.hosts` answers that name: inside `titan-k3s` ⇒ `192.168.5.15` (itself), inside `titan-incus` ⇒ `192.168.5.2` (the host, forwarded to the NodePort; [§layout](#layout)). `tests/render_test.py` keeps the endpoints of the control plane, the worker and the `ObjectStore` equal.
- Data at `hostPath` `/mnt/titan-s3`, the `mountPoint` of the host directory `~/.local/share/titan-local-cluster/s3` (writable; `up.sh` creates it): virtiofs on macOS (`lima/macos/titan-k3s.yaml`), `9p` on Ubuntu (Lima QEMU's default, the VM file sets no `mountType`; `lima/ubuntu/titan-k3s.yaml`; `chown` on the mount reports `Operation not permitted`, files survive `limactl delete`). `hostPath` of type `Directory`: a missing mount keeps the pod from starting, instead of writing to the VM disk.
- Bucket `titan-backup-dev` is created by PostSync Job `seaweedfs-bucket` when absent (creating an existing bucket exits 1, measured on 4.51).
- Memory has a ceiling: `GOMEMLIMIT=350MiB`, concurrent upload capped at 64 MB in S3, filer and volume server, limit 640 MiB. Measured 2026-10-26, limit 512 MiB, no cap: Titan's `vm.backup` of a 670 MB VM failed 3 times out of 4 (pod OOM, Incus got `connection refused` during upload), the fourth went through. Only the three upload caps: a backup straight through Incus still OOMs. With `GOMEMLIMIT`: the backup straight through Incus passes, still at limit 512 MiB (`memory.max` 536,870,912 bytes), `memory.peak` 540,696,576 bytes. At 640 MiB (after merge) the same backup passes, 0 restarts, `memory.peak` 673,714,176 bytes against `memory.max` 671,088,640: page cache always fills up to the ceiling, so the peak cannot say how much is needed; the heap is held by `GOMEMLIMIT`. 640 MiB is room for a 350 MiB heap plus uploads in flight and the process's buffers; 512 MiB with `GOMEMLIMIT` also passed once, not measured further. Readiness reads the master's `/cluster/status` over HTTP, opening no abandoned TLS connection.
- A self-signed CA and a server certificate (SAN `DNS:lima-titan-k3s.internal`, EC P-256, 10 years) are generated once with `openssl` on the host, beside `secrets.env`: `s3-ca.crt`, `s3-ca.key`, `s3.crt`, `s3.key` (keys mode 600). The CA key never enters the cluster. A lost certificate is re-signed from the same CA by bootstrap; a lost CA means a new CA and a re-signed certificate. Bootstrap works with OpenSSL and with macOS's LibreSSL (`lima/tests/bootstrap-secrets_test.sh`, case `real` runs both `openssl` of the machine).
- Four parties trust the CA. Barman: `endpointCA` of the `ObjectStore`, Secret `s3-ca` in `titan-db-dev`. The control plane (.NET) and the worker (Go): Secret `s3-ca` in `titan-dev`, mounted as one more file `/etc/ssl/certs/titan-local-s3.crt` with `subPath`, so the image's CAs stay; both read every file in that directory (measured 2026-10-26 on the rebuilt cluster: the control plane's Test `Connected`, the worker HEADs an object over TLS; the reverse run without the CA not measured). Incus: the system store of `titan-incus`, which `lima/scripts/trust-s3-ca.sh` (run by `up.sh`) copies to `/usr/local/share/ca-certificates/titan-local-s3.crt`, runs `update-ca-certificates`, and restarts Incus only when the CA changed (Go reads the system store once per process; whether instances survive a daemon restart: not measured).
- The S3 key pair is SeaweedFS's only identity (`seaweedfs-s3-config`; rights `Read`, `Write`, `List`, `Tagging`, no `Admin`: the bucket is created by the Job through master and filer), the same pair as the three backup Secrets ([§secrets](#secrets)).
- Dev's `titan-db` is created empty and archives to SeaweedFS; rebuilding `titan-k3s` when the store has data is a restore through a temporary PR, writing under a new name ([§runbook](#runbook)); the name holding the latest copy is in known-state `titan-ops status/known-state.md#titan-db-server-names`.

**Why.**
- The local cluster needs no account (L-22); R2 needs a Cloudflare account. MinIO is out: its repository is archived.
- Data on the host survives `limactl delete`, so a rebuilt cluster still has its backups.
- The control plane's `https` rule stays (`titan-ops features/backup/design.md#backup-target`). The option of the control plane accepting `http` is out: data would travel unencrypted, and staging could be misconfigured to `http`.
- The CA is generated on the host, not in cert-manager: Incus trusts the CA through the system store, so the CA has to leave the cluster; generated in the cluster it would have to be read out of a Secret, and it would change on every rebuild.

**Measured 2026-10-26** (on the dev cluster before the rebuild, `/mnt/titan-s3` made temporarily on the VM disk): the bucket Job is green both when the bucket is absent and when it exists; from `titan-incus`, `curl` to the endpoint through the system store ⇒ TLSv1.3, `verify=0`, HTTP 403; Incus uploads a volume backup through the endpoint ⇒ the object is in the bucket; the same request by IP (outside the SAN) ⇒ no object.

<a id="open-questions"></a>
## Settled questions

Every question of the design was answered by Tôn Chủ on 2026-10-08 (L-1…L-15). Question Q-3 (source of secrets) Tôn Chủ left to the team; the team decided as in [§secrets](#secrets).

~~Accepted consequence of L-8: local runs merged code only. It catches no error before merge. That stays CI's job.~~ Changed 2026-10-21 (L-20): a PR changing behaviour in a code repository runs on dev before merge. Changed back 2026-10-21 (L-20 removed): the accepted consequence of L-8 applies again — local runs merged code only, errors before merge belong to Stage 1 and CI.

<a id="unmeasured"></a>
## Unmeasured assumptions

| Assumption | Owner |
|---|---|
| macOS + everyday applications ≈ 5 GB. Only the whole machine's free RAM could be measured (37–40% with the cluster running), not the applications on their own | Eos |
| ~~CIDR clashes between tenants on uplink `ovnup` (D-2)~~ — closed in INCUS-4: tenant networks have no uplink ([network §uplink](network.md#uplink)) | — |
| Why the first reconcile after a push **without** a refresh sometimes reads the old commit ([§dev-sync](#dev-sync)): no control run yet; with a refresh it was not seen (one measurement, 2026-10-22) | Eos |
| `GOMEMLIMIT=512MiB` keeps k3s around 640 MiB over **many hours** (measured up to 12 minutes only) | Eos |
| **Accepted risk:** `titan-k3s` has about 270–600 MiB available while the runner runs ([§ram-budget](#ram-budget)). Raised to 4 GiB (2026-10-25). Next trigger: a pod OOM-killed, or heavy Mac swapping with both VMs at their ceilings ⇒ revisit the budget in [§ram-budget](#ram-budget) | Eos |

Measured in the LOCAL-CLUSTER iteration:
- `titan-k3s` (3 GiB then; 4 GiB now) runs every app with no pod OOM-killed ([§ram-budget](#ram-budget)).
- RAM with 3 VMs `s` running ([§ram-budget](#ram-budget)).
- Instances in projects `lab-*` are not reported by the reconciler: 0 log lines in the worker and the control plane.
- Staging images run on local unchanged except for the overlay's patches.
- Two read-only GitHub tokens.

<a id="runbook"></a>
## Runbook

Every command runs at the root of a checkout of this repository on the host, macOS or Ubuntu (beside titan-ops: `../titan-local-cluster`). `KUBECONFIG=~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml`.

**Start.** Docker must be off on both OSes (`up.sh` stops when `docker info` works; macOS: Docker Desktop) (L-6, L-18). A host behind a TLS-inspecting proxy needs its CA in place first, and cannot build a new `titan-k3s` ([§extra-ca](#extra-ca)). Run:

```
bash lima/scripts/up.sh
```

- On Ubuntu the same command: `up.sh` picks `lima/ubuntu/` by `uname -s` (`lima/scripts/host-os.sh`); the host needs nested KVM and QEMU ([§layout](#layout)). Measured 2026-10-27 on an empty machine: `up.sh` 348 s, then 13/13 Applications `Synced/Healthy` after 789 s; `titan-db` `ContinuousArchiving=True`; Z-1 PASS; module `vm` of titan-regression 24 passed.
- On an empty Ubuntu (measured 2026-10-28): the first provision of `titan-incus` (apt installs Incus and OVN) took 689 s, longer than Lima's wait ceiling of about 10 minutes; `up.sh` keeps waiting for `cloud-init` in the VM up to 30 minutes; on an even slower network run `up.sh` again, it waits one more round for the install and goes on. Before starting a VM that is not running, `up.sh` stops if a host port of the VM (`127.0.0.1` 6443, 8080; Ubuntu adds 8443, 30833) is already held by another cluster or program (`lima/scripts/ports-free.py`).
- The first time, the script creates both VMs, waits for ArgoCD to install its CRDs, gives ArgoCD the extra CA if the host has one ([§extra-ca](#extra-ca)), then applies `root-local`. ArgoCD syncs the rest by itself from `main` here. Measured rebuild from empty 2026-10-21 (`dd13c9a`, both VMs `limactl delete`, Lima's OS image cache kept): `up.sh` 4 minutes, the last app synced about 15 minutes after the start, read at about 24 minutes 10/10 apps `Synced/Healthy` (exact Healthy time not measured).
- With the VMs already there, the script only starts them. Internal secrets stay ([§secrets](#secrets)).
- No account or token is needed. Keep `~/.config/titan-local-cluster/secrets.env`: rebuilding the cluster needs that very file.

**Stop (R-1).** `bash lima/scripts/down.sh`. The two VMs' RAM returns to the host; disks and data stay. Customer VMs in `titan-incus` stop too and do not start again after `up.sh`: Titan reports `Stopped` with "requested: Running" (drift, `titan-ops features/vm/design.md`), started again with Titan's start command (measured 2026-10-27 with `lc3-vm`, through the API). That time the Incus LVM thin pool broke after `down.sh` and had to be repaired by hand first (known-state `titan-ops status/known-state.md#incus-thinpool-after-down`).

**Move dev to `main`.** On branch `main` here (`git switch main && git pull --ff-only`): `python3 scripts/pull-images.py` (needs `gh` signed in) writes `newTag`; then `python3 tests/render_test.py` + `bash tests/sweeper_test.sh` (CI here does not run `sweeper_test.sh`, because it reads titan-ops, which is private), commit + push `main` — the push is the deploy (`titan-ops architecture/platform-infra.md#gitops-flow`) — then refresh ArgoCD ([§dev-sync](#dev-sync)). Right after merging a code repository's PR, run `pull-images.py --wait <repo>@<merge commit>` first: it only waits for every workflow `IMAGES` lists for that repository to finish on `main`, writes nothing, last line `WAIT_RESULT=OK`, or `ERROR` when a workflow concludes other than `success`, a GitHub call fails, 20 minutes pass or an argument is wrong; pull only on `OK`.

**The Incus thin pool is broken** (at boot `lvm` reports `Check of pool default/IncusThinPool failed … Manual repair required!`, 0 LVs active, `vm.start` fails with `Failed to activate LVM logical volume`; known-state `titan-ops status/known-state.md#incus-thinpool-after-down`). Inside `titan-incus`: `sudo systemctl stop incus.service incus.socket`, `sudo lvconvert --repair -y default/IncusThinPool`, `sudo vgchange -ay default`, `sudo systemctl start incus.socket incus.service`, then start the customer VMs through Titan (measured 2026-10-27). LV `IncusThinPool_meta0` holds the metadata from before the repair. An agent asks Tôn Chủ each time before running it: these are OS commands inside the VM, not the `incus` commands that the row "Writes on the dev cluster" of the command approval table lets it run without asking.

**Rebuild `titan-k3s` from scratch.** Not behind a TLS-inspecting proxy: the rebuilt VM gets no ArgoCD there ([§extra-ca](#extra-ca)). Run `limactl stop titan-k3s` (`down.sh` stops `titan-incus` too, not needed), then `limactl delete titan-k3s`, then `up.sh`. Secrets, CA and certificates come back from `~/.config/titan-local-cluster/` ([§secrets](#secrets)); SeaweedFS data is still on the host ([§s3](#s3)). The `titan-db` store in the bucket is not empty, so a `Cluster` created empty cannot archive: barman refuses a non-empty store, archiving fails and WAL piles up on the PVC (`titan-ops infra/oci/runbook.md#disaster-recovery` step 3). So a rebuild is a restore, in two PRs here. The first PR adds `base/`'s `restore` component to the `titan-db` overlay and changes **both** names by a patch of the dev overlay (not by editing the component in `base/`, which staging uses too): read the name being written from known-state (`/spec/externalClusters/0/plugin/parameters/serverName`), write a new name (`/spec/plugins/0/parameters/serverName`); merge after `limactl delete` and **before** `up.sh` (root's sync creates the `Cluster` from `main` here). Once the `Cluster` is up, the second PR removes `restore` and changes the written name in the overlay's patch to the new name, so `main` creates an empty DB for strangers again; between the two PRs, anyone building a new cluster from `main` meets `no target backup found`. `bootstrap` is read only when the `Cluster` is created; CNPG's webhook accepts changing `recovery` to `initdb` on an existing `Cluster` (measured 2026-10-27 with a server dry-run). Read an older name by mistake and it silently restores from the old store, losing everything written since; write the current name again and barman refuses a non-empty store. Write the name holding the latest copy into known-state `titan-ops status/known-state.md#titan-db-server-names`. On a running cluster (VMs not deleted), follow the drill's order (`titan-ops infra/oci/runbook.md#restore-drill-dev`): drop `automated` of `root-local` first (it has `selfHeal` and manages `titan-db-local`: dropping it on the child first makes root set it back), then of `titan-db-local`, delete the `Cluster`, merge the patch, sync by hand, then `kubectl --kubeconfig <kc> apply -f gitops/apps/root.yaml` sets root's `automated` back, and root re-applies the child apps. Merge the patch before deleting and the live cluster writes into the new name, so the restored cluster meets a non-empty store; delete while `automated` is still on and the app (last sync older than HEAD of `main`) syncs again at once and recreates the cluster with the old name ([§keycloak-db-rename](#keycloak-db-rename)). Moving the namespace (`titan-db-staging` ⇒ `titan-db-dev`, 2026-10-28) deletes no `Cluster` by hand: changing the app's destination makes ArgoCD prune the old cluster and create the restored cluster in the new namespace in the same sync; but before the merge the new namespace must have its Secrets (`bootstrap-secrets.sh`, `join-cluster.sh` of the branch), self-sync off as in step 0 of [§keycloak-db-rename](#keycloak-db-rename), then the old writer stopped, WAL archived (`select pg_switch_wal()`, then wait for `last_archived_wal` of `pg_stat_archiver` to change), and the old namespace deleted only after the old cluster is gone. Secrets are the same as when the store was written, so the restored DB's passwords match (measured 2026-10-27: `ContinuousArchiving=True` under `titan-db-restored`, `beta-user`'s rows still there, `beta-user` signs in, no `503`). Lose `~/.config/titan-local-cluster/` and `join-cluster.sh` generates a new client identity (`titan-client.crt`/`.key`) and trusts it on `titan-incus` in the same `up.sh` run (`titan-ops features/cluster/design.md#provider-client-identity`); also lost: the password of `titan-db-credentials` (owner `titan` of the restored DB), `keycloak-admin-secret` (admin in the restored Keycloak DB: `keycloak`, `keycloak_staging` before 2026-10-28), and the passwords of `beta-user-credentials`, `beta-user-2-credentials` (the PostSync realm import job writes new passwords into the restored Keycloak, so they may match again); a new CA also needs `trust-s3-ca.sh` again (`up.sh` does it). All of it: not measured. A VM stopped in the middle of an image pull leaves the pod stuck in `PodInitializing` (sandbox `NotReady`, the image not in `k3s crictl images`), and the kubelet does not pull again once the VM is up: delete the pod, and its Job or controller makes a new one that pulls again (measured 2026-10-29: `titan-db-1-initdb` stuck 11 hours; 4 minutes after deleting it `titan-db` was healthy). After a rebuild, `up.sh` reruns `join-cluster.sh` when needed; it reads the new fingerprint of `titan-incus` and trusts only when not trusted yet — nothing to do by hand. (History: before ZC-1 the Incus client identity was encrypted in the DB, so a restore had to keep the old `Encryption__ClusterKey`, measured 2026-10-27: the worker reconciled cluster `local-mac` without trusting again; the identity is no longer in the DB.)
- On `titan-incus`, remove the old trust first (`incus config trust list`, then `incus config trust remove <fingerprint>`).

**Join cluster `local` to `titan-incus`: trust is automatic; template sync is automatic on an empty DB, needs an admin after rebuilding `titan-incus`** (DB kept). Since ZONE-TO-CLUSTER ZC-1 (`titan-local-cluster#33`, 2026-10-27), `lima/scripts/join-cluster.sh` (run by `up.sh`) does the cluster sign-in itself: generates the client identity once, reads the server fingerprint at run time with `incus info`, trusts Titan's certificate on `titan-incus` when not trusted yet, and writes Secret `control-plane-cluster` — no manual step, no Z-1 spec needed for this any more; closes the trust/join part of known-state `titan-ops status/known-state.md#stranger-cluster-not-joined`. Template sync: the control plane syncs by itself every cluster a template was never asked into (`titan-ops features/catalog/design.md#template-sync-never-asked`), so `titan-k3s` built with an empty DB is asked to sync within 5 minutes of the control plane running and has templates once the worker has copied the images, no step needed (not measured on an empty DB). Rebuilding `titan-incus` with the DB kept leaves every template with a row in `local` (the alias is gone on Incus), and the control plane does not sync again by itself; that still takes an admin session (browser), so it runs through the runner in the cluster:
1. The runner's two CronJobs are on the cluster (app `regression-runner-local`): `titan-regression` for lane a and `titan-regression-b` for lane b; the Z-1 step below uses lane a only.
2. Load spec Z-1 (`lima/regression-runner/z1/`, spec `z1-cluster.spec.ts`) into the job's own ConfigMap (`titan-regression-specs-<job>`), then create a job from `cronjob/titan-regression` (`run-module.sh` of the regression repository does both). How: §Runner of titan-ops's `release:regression` skill.
3. The spec reads the cluster's endpoint and fingerprint through `GET /v1/admin/clusters` (registers nothing), then syncs templates. Right result on macOS (admin badge `/catalog`): Ubuntu `Available`, Alma 9 and Rocky 9 `Failed` — the sync gives up, existence `NotCreated` with a reason (arm64 has no VM image of those two OSes, `titan-ops features/catalog/design.md#template-architecture`). On Ubuntu (amd64) all three templates Ubuntu/Alma/Rocky `Exists` (measured 2026-10-27, endpoint `https://192.168.5.2:8443`).

**History: spec Z-1 broke after rebuilding `titan-incus` (measured 2026-10-24, fixed in `titan-local-cluster#33`, 2026-10-27).** Before ZC-1, Z-1 registered the cluster itself and hit two errors when `titan-incus` was rebuilt: the server fingerprint hard-coded in spec Z-1 (now `lima/regression-runner/z1/z1-cluster.spec.ts`) differed from `certificate_fingerprint` of `sudo incus info` (measured twice, 2026-10-24 and 2026-10-26, a new fingerprint each time); and `z1/local-proxy.ts` had the same file name as `lib/local-proxy.ts` of `titan-regression`, so loading the ConfigMap was refused, forcing the spec to import `startLocalProxyIfNeeded` from `lib/`. ZC-1 removed both causes: `join-cluster.sh` reads the fingerprint at run time (no constant in the spec any more) and spec Z-1 has no `z1/local-proxy.ts` of its own — only the import of `startLocalProxyIfNeeded` from `titan-regression`'s `lib/`, no name clash.

<a id="keycloak-db-rename"></a>**Renaming Keycloak's DB** (once per cluster whose DB has the old name: base names the DB `keycloak` since 2026-10-28, `keycloak_<env>` before). A `Database` object with the new name that meets no such DB creates an empty DB and Keycloak runs on it: Keycloak users get new ids, Titan's existing tenants (matched by `sub`) are orphaned. So rename the old DB before the new base reaches the cluster, with Keycloak stopped. Apps `keycloak-local` and `titan-db-local` are `automated` (no `selfHeal`) and sync again by themselves when a scale or a delete makes them drift from git, if the app's last sync is older than HEAD of `main` here (measured on dev 2026-10-28, both apps' last sync older than HEAD: the scale ran 02:34:42 UTC, `keycloak-local` started syncing 02:34:44; `titan-db-local` synced 02:35:00 at the HEAD of then (the revision before the merge), right after the `Database` was deleted): Keycloak came back on a DB with the old name that CNPG recreated, empty. So step 0 turns self-sync off: drop `syncPolicy.automated` of `root-local` first (it manages itself and the two child apps and has `selfHeal`: dropping it on a child first makes root set it back), then of `keycloak-local` and `titan-db-local`; check all three have no `automated` before step 1 (not measured); from step 0 until the merge no other push lands on `main` here (other sessions wait).
  1. `kubectl --kubeconfig <kc> scale statefulset keycloak -n <auth ns> --replicas=0`.
  2. Snapshot with Keycloak stopped: the ids of `admin-test`, `beta-user`, `beta-user-2` in `user_entity` of realm `titan`, and the row count of each table (`scripts/db-row-counts.sql` of titan-ops) of the old DB (psql `postgres` on the primary pod).
  3. Delete the old `Database` object (`databaseReclaimPolicy: retain`, so the DB stays; with the object left, CNPG recreates an empty DB with the old name).
  4. `ALTER DATABASE <old name> RENAME TO keycloak`, then count the rows of each table of `keycloak`: equal to the snapshot of step 2.
  5. Merge the new base's PR, then set self-sync back by hand: `kubectl --kubeconfig <kc> apply -f gitops/apps/root.yaml` (this repository, new `main`) then refresh ArgoCD; root gets `automated` + `selfHeal` back and re-applies the two child apps from git. Check `root-local` has `automated` and `selfHeal` before ending the run (no `automated` ⇒ dev stops following `main` without a word). `Database` `keycloak` takes the existing DB, Keycloak comes back. Check the three users' ids against the snapshot (not the row counts: a Keycloak back up writes sessions and the hook's sign-ins), and that no DB with the old name is left (`pg_database`); if one is, it is a new one created by the automatic sync (realm and users declared with new ids, no old data), and may be dropped.

  Dev did it 2026-10-28 without step 0: the three users' ids and the row counts of 90 tables equal to the snapshot after the rename; the old Keycloak ran on `keycloak_staging`, recreated by the automatic sync (the DB existed from 02:35:24, the new Keycloak was up at 02:37:45; no tenant was born in between); that DB was dropped with `DROP DATABASE keycloak_staging` before dev moved its namespace (the same day).

**Tenant quota.** A new tenant has the default quota. Set `MaxVms = 3` (L-11) with the admin's `PATCH /v1/tenants/{id}/quota`. Spec A-1 does it at its first step.

**Control plane Integration tests (L-18).** `./test-all.sh` in a checkout of `OpenViCloud/titan-control-plane`. The script `port-forward`s `svc/titan-db-rw` (namespace `titan-db-dev`) to `127.0.0.1:15432` and runs the Integration suite as role `titan_it` (`createdb`, only in dev's `titan-db` overlay; the test password is in `lima/scripts/bootstrap-secrets.sh`, copied into `test-all.sh`). The temporary database `titan_it_<guid>` is dropped when its test is done. Cluster stopped and no Docker ⇒ `RESULT: INCOMPLETE`, exit 2. A port-forward that dies mid-run (checked before and after the full-host and integration steps) ⇒ that step's failures do not count, the next steps are skipped, also `RESULT: INCOMPLETE`, exit 2; failures measured before then are still `FAILED`.
- Accepted risk: `titan_it` can connect to dev's `titan` DB. The cluster listens on `127.0.0.1` only (L-3), dev's data is disposable.
- Flake `TEST-ALL-TUNNEL` (Eos), **closed** 2026-10-30, cause measured and fixed: `test-all.sh`'s `port-forward` died mid Integration step (2026-10-10/11) and mid full-host step (2/2 runs 2026-10-27, 3/5 runs 2026-10-30).
  - Cause: `TestPostgres.cs` sent each pooled connection's Terminate (`ClearPool`), then at once `DROP DATABASE … WITH (FORCE)` on an admin connection already open in its own pool, so both reached the pod within about 0.05 ms. A backend killed with its Terminate unread exits with bytes in its socket and the kernel sends a reset. containerd logs `read: connection reset by peer`, and `kubectl port-forward` prints `error: lost connection to pod` and exits: one reset ends the tunnel for every test. `FATAL 57P01` is on green runs too, because most of the kills close cleanly.
  - Measured before the fix (full-host, 8 runs, kubectl output kept, `tcpdump` on the pod's loopback): 3 tunnel deaths, 3 resets, one each. Of 23 `57P01` kills, Terminate at least 0.2 ms ahead of the `FATAL` ⇒ clean close, 20/20; 0.01 ms ahead or later ⇒ reset, 3/3. Controlled, on a private tunnel: kill with nothing unread ⇒ tunnel lives 10/10; with unread bytes ⇒ tunnel dies 10/10.
  - Fix: plain `DROP DATABASE`, which waits up to 5 s for backends to leave. After the fix: 12 full-host runs, then 5 `./test-all.sh` runs (unit 2268, full-host 115, integration 106, `RESULT: all steps passed`): 0 tunnel deaths, 0 kills of a client backend, 0 resets in the 12 captured runs. A test that keeps a connection open past 5 s now fails its class cleanup with `55006`; none did in these runs.
  - The script's `while` loop stays as the detector: a reopen during the full-host or integration step ⇒ `INCOMPLETE`. Trigger to reopen: the next such `INCOMPLETE`. Look first in `/var/lib/rancher/k3s/agent/containerd/containerd.log` in the k3s VM (`error forwarding port`), then the Postgres log at the same second.
  - Same line, same fix: `42501 permission denied to terminate process` (2 of the 8 runs before the fix, each a class cleanup failure and a `titan_it_*` database left behind) did not recur. Not measured directly: FORCE most likely hit an autovacuum worker, since `terminating autovacuum process` now shows once in 12 full-host runs and once in the 5 `./test-all.sh` runs, the plain `DROP` stopping it without an error. Tôn Chủ chose to leave the databases left behind, no cleanup.

**API token for the Terraform provider's acceptance tests.** `bash lima/scripts/tf-acc-token.sh`: replaces token `tf-acc` of tenant `beta-user` with a new 30-day token, writes `OPENVICLOUD_API_URL` + `OPENVICLOUD_TOKEN` into `~/.config/openvicloud/tf-acc.env` (`0600`, moved with `OPENVICLOUD_TF_ACC_ENV`), prints no secret (`titan-ops features/terraform-provider/design.md#acceptance-on-dev`). After a DB rebuild, `beta-user` must sign in to the portal once (the tenant is born at first sign-in) before the script has a tenant to write.

**Into a customer VM.** VMs have no Internet and the Mac cannot reach them directly (L-10). Use `limactl shell titan-incus -- sudo incus console --project t-<tenant> <instance>`.
