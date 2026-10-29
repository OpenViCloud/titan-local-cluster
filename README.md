# titan-local-cluster — OpenViCloud's dev environment on a Mac or an Ubuntu machine

The dev environment of [OpenViCloud](https://github.com/OpenViCloud): two Lima VMs on one macOS or Ubuntu machine (k3s with
ArgoCD, and a one-node Incus 7.0 LTS that is cluster `local`), and the GitOps that ArgoCD on that k3s follows. Both
deployments share everything; what differs is the two VM files (`lima/macos/`, `lima/ubuntu/`) and the per-OS branches of
`lima/scripts/host-os.sh`.

`base/` holds the manifests every environment shares: the apps, the database with its backup and restore components, the
Keycloak realm import and values, and the values of NATS, CloudNativePG and the Barman Cloud plugin's manifest. Every overlay here
(`gitops/<app>/`) builds on `../../base/<app>` and adds only what the local cluster needs: hostnames, the cluster list, the token issuer and Keycloak's metadata
address, Keycloak's database host, the realm's portal origins (a ConfigMap the overlay generates), the
backup bucket and endpoint, smaller requests, dev's own image tags. `base/` names no environment (`tests/render_test.py`,
`BaseNamesNoEnvironment`). The regression runner (`gitops/regression-runner/`, Application `regression-runner-local`) generates its URLs the same way. Staging's overlays live in titan-ops and build on `base/` here at a pinned commit;
this repository never reaches staging. Nothing ArgoCD renders here reads titan-ops (`tests/render_test.py` checks it).

Design, rules and runbook of the dev cluster: [docs/topology.md](docs/topology.md) and [docs/network.md](docs/network.md).

## Layout

| Path | What |
|---|---|
| `lima/` | What both deployments share: `provision/` of the two VMs; `scripts/`: `up.sh` · `down.sh`, the secrets bootstrap, a Terraform acceptance token for dev; `tests/` of the provisioning; the regression runner overlay |
| `lima/macos/` · `lima/ubuntu/` | The two Lima VM files of each OS, and a link to `lima/provision` (Lima refuses `..` in a provision path); `up.sh` picks the folder by `uname -s` |
| `gitops/apps/` | ArgoCD app-of-apps: `root-local` and one Application per app |
| `base/` | The manifests every environment shares; staging builds on them from titan-ops |
| `gitops/<app>/` | Dev's overlay of each app, on `../../base/<app>` |
| `scripts/pull-images.py` | Moves dev to the images other repositories published from main |
| `tests/` | Render checks of the overlays, the pull script, the Keycloak theme check, and the guest-log sweeper compared with titan-ops's template |

## Run

Needs, on either OS: 16 GB, [Lima](https://lima-vm.io/) (measured with 2.2.1), `kubectl`, `openssl` and `python3`. No account and no token: the
repositories and the images (linux/arm64 and linux/amd64) are public. titan-incus runs KVM guests, so it needs nested virtualization:
- macOS: an Apple M3 or later.
- Ubuntu: x86_64 with KVM (`/dev/kvm` writable by your user) and nesting on (`cat /sys/module/kvm_intel/parameters/nested` says `Y`,
  or `kvm_amd`'s says `1`), and QEMU (`qemu-system-x86` and `qemu-utils`). The two VMs talk through the host's 127.0.0.1, not Lima's user-v2 network,
  which made QEMU 10.2.1 abort under load.

On Ubuntu, apt has no Lima package. This installs QEMU, then Lima 2.2.1 and kubectl into `~/.local` with their checksums checked
(root only for the two `sudo` lines; `~/.local/bin` is on Ubuntu's `PATH` after you log in again, or `export PATH="$HOME/.local/bin:$PATH"` now):

```sh
sudo apt-get install -y qemu-system-x86 qemu-utils curl openssl python3
sudo usermod -aG kvm "$USER"     # then log in again, so /dev/kvm is writable by you
mkdir -p ~/.local/bin && cd "$(mktemp -d)"
curl -fsSLO https://github.com/lima-vm/lima/releases/download/v2.2.1/lima-2.2.1-Linux-x86_64.tar.gz
curl -fsSLO https://github.com/lima-vm/lima/releases/download/v2.2.1/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS && tar -C ~/.local -xzf lima-2.2.1-Linux-x86_64.tar.gz
v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl" -O "https://dl.k8s.io/release/$v/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c && install -m 0755 kubectl ~/.local/bin/kubectl
limactl --version && kubectl version --client
```

The first `up.sh` downloads the two OS images (about 0.35 and 0.6 GB; how long depends on the link). titan-incus's first
provision then installs Incus and OVN: 689 s measured on an Ubuntu machine with the images already cached, more on a slow link. Lima stops waiting after about 10 minutes and leaves the VM
running; `up.sh` then waits up to 30 more minutes for the install to finish. If it still stops, run it again: it waits for the
install again and goes on from where it stopped. It stops before starting a VM whose host ports (`127.0.0.1` 6443 and 8080; on
Ubuntu also 8443 and 30833) another cluster or program already holds, and names the port.

The bootstrap keeps the values it generates in `~/.config/titan-local-cluster/` (`secrets.env`, the S3 CA and SeaweedFS's certificate; keys mode 600; and, on a host behind a TLS-inspecting proxy, its CA as `extra-ca.crt`, [docs/topology.md#extra-ca](docs/topology.md#extra-ca)), so a rebuilt cluster gets them again; keep that folder. Behind a TLS-inspecting proxy a new titan-k3s gets no ArgoCD: build or rebuild it off the proxy ([docs/topology.md#extra-ca](docs/topology.md#extra-ca)). Backups go to SeaweedFS in titan-k3s (`gitops/seaweedfs`), over TLS at `https://lima-titan-k3s.internal:30833`, with its data in `~/.local/share/titan-local-cluster/s3` on the host, which outlives the VM. Docker must not be running.

```sh
bash lima/scripts/up.sh      # creates the VMs on first run, then starts them, trusts an extra CA if present (the VMs first, ArgoCD once it is up), applies secrets, trusts the S3 CA, joins cluster local to titan-incus, applies root-local, drops the Applications of the old names
bash lima/scripts/down.sh    # stops both VMs; disks stay (guest VMs in titan-incus stop too, see below)
```

`memory` in `lima/<os>/titan-k3s.yaml` applies when the VM is created. To resize a running one: `limactl stop titan-k3s && limactl edit --memory 4 titan-k3s && limactl start titan-k3s` (about 15 seconds of downtime; the pods come back by themselves).

ArgoCD: http://argocd.localhost:8080 · portal: http://portal.localhost:8080.

After `up.sh`, ArgoCD keeps installing for a while; the cluster is ready when every application is `Synced` and `Healthy`
(`kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml get applications -n argocd`).
Sign in to the portal as `beta-user`, with the password `BETA_USER_PASSWORD` in `~/.config/titan-local-cluster/secrets.env`
(`grep BETA_USER_PASSWORD ~/.config/titan-local-cluster/secrets.env`), and to the admin console (http://admin.localhost:8080)
as `admin-test`, whose fixed test password is in `lima/scripts/bootstrap-secrets.sh`. These test accounts carry the realm
role `auto-approve` and are approved on their first sign-in; any other account waits until an admin approves it in the admin console.

On a cluster that was up before the rename of 2026-10-27 (cluster `local-mac`, Applications `*-local-mac`), run
`bash lima/scripts/drop-old-applications.sh` right after the merge reaches it (or `up.sh`, which runs it): the old root lists
itself and may not prune itself (on the Ubuntu cluster on 2026-10-27 it pruned every old Application, itself
included), and two roots would keep relabelling the same children. The database's rows move by
themselves, in a hook of the control plane's sync (`gitops/control-plane/rename-cluster-id-job.yaml`).

`up.sh` joins cluster `local` to titan-incus (`lima/scripts/join-cluster.sh`): it makes Titan's client identity once
(`~/.config/titan-local-cluster/titan-client.crt` and `.key`), reads titan-incus's server fingerprint and the Incus
endpoint for this host's OS (`lima/scripts/host-os.sh`), has titan-incus trust Titan's certificate, and puts all of them in
Secret `control-plane-cluster`. The portal offers an OS once an admin has synced the
templates (admin console, Catalog).

`down.sh` stops the guest VMs in titan-incus with it, and `up.sh` does not start them again: start them again through Titan (the VM's start).
Once, after `down.sh` with a guest VM running, Incus's LVM pool failed its check at boot ("Manual repair required!") and
no guest VM could start. The repair that brought it back, inside titan-incus:

```sh
limactl shell titan-incus -- sudo systemctl stop incus.service incus.socket
limactl shell titan-incus -- sudo lvconvert --repair -y default/IncusThinPool
limactl shell titan-incus -- sudo vgchange -ay default
limactl shell titan-incus -- sudo systemctl start incus.socket incus.service
```

The database starts empty and archives to SeaweedFS. To rebuild titan-k3s (off any TLS-inspecting proxy, [docs/topology.md#extra-ca](docs/topology.md#extra-ca)), delete `~/.local/share/titan-local-cluster/s3`
along with the VM, and the database starts empty again: a plain `up.sh` over a folder that still holds the archive gives a
database whose backups fail, because barman refuses to archive into a store that is not empty. Rebuilding from that archive
is a restore, which the maintainers do through titan-ops's runbook; its steps are not public yet.

## Move dev to main

```sh
git switch main && git pull --ff-only   # the pull reads and writes this checkout's main
python3 scripts/pull-images.py      # writes newTag; needs `gh` logged in
git commit -am "Pull published images into dev" && git push   # ArgoCD on dev follows main: the push is the deploy
kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml annotate applications.argoproj.io --all -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

The refresh is so ArgoCD need not wait for its next poll: a push took 162 s to about 6 minutes to show up (measured
2026-10-21, before refreshing was the rule); with the refresh, at most 12 s for all 8 apps that follow this repository
(measured once, 2026-10-22). Do the same after merging a pull request here. Code of other repositories reaches dev
only as the images their CI publishes from main.

An `images` entry other than the name `base/<app>` gives the image is an ERROR. One bad row writes nothing.

`--wait <repo>@<commit>`, right after merging a pull request of a repository in `IMAGES` (the `repo` value as the
table spells it, the merge commit in full 40 hex), only waits and writes nothing: until every workflow `IMAGES` lists
for that repository finished its push run on main for that commit, one stdout line per finished workflow. A run not
created yet is waited for. The last line is `WAIT_RESULT=OK`, or `WAIT_RESULT=ERROR` for a conclusion other than
success, a failed GitHub call (each call times out after 60 s), a run unfinished after 20 minutes, or bad arguments.
After OK, move dev to main as above: the pull reads main as it is then, since other sessions push here while a wait
runs.

## Tests

```sh
python3 tests/render_test.py          # kubectl and ruby
python3 tests/test_lima_files.py      # ruby
python3 tests/test_pull_images.py
python3 tests/test_keycloak_theme.py && python3 scripts/keycloak-theme.py --check
bash tests/sweeper_test.sh            # network and gh signed in (titan-ops's template on GitHub)
bash lima/tests/incus-log-sweeper_test.sh
bash lima/tests/incus-uplink_test.sh
bash lima/tests/bootstrap-secrets_test.sh   # macOS only (stat -f)
bash lima/tests/trust-s3-ca_test.sh
bash lima/tests/trust-extra-ca_test.sh
bash lima/tests/join-cluster_test.sh
bash lima/tests/drop-old-applications_test.sh
bash lima/tests/ports-free_test.sh
bash lima/tests/first-start_test.sh
```

CI runs all of these but `sweeper_test.sh` and `bootstrap-secrets_test.sh` on every push to `main` and every pull request into it.
`sweeper_test.sh` reads titan-ops (`OpenViCloud/titan-ops`), which is private, so it runs
before every push on a machine with `gh` signed in as an org member, not in CI.
`bootstrap-secrets_test.sh` uses macOS's `stat -f`, so it runs only on a Mac, before every push that changes `lima/`.

## License

MIT
