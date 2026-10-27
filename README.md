# titan-local-cluster — OpenViCloud's dev environment on a Mac

The dev environment of [OpenViCloud](https://github.com/OpenViCloud): two Lima VMs on one Mac (k3s with ArgoCD,
and a one-node Incus 7.0 LTS that is zone `local-mac`), and the GitOps that ArgoCD on that k3s follows.

`base/` holds the manifests every environment shares: the apps, the database with its backup and restore components, the
Keycloak realm import and values, and the values of NATS, CloudNativePG and the Barman Cloud plugin's manifest. Every overlay here
(`gitops/<app>/`) builds on `../../base/<app>` and adds only what the Mac needs: hostnames, the zone list, the token issuer,
the backup bucket and endpoint, smaller requests, dev's own image tags. Staging's overlays live in titan-ops and build on `base/` here at a pinned commit;
this repository never reaches staging. Nothing ArgoCD renders here reads titan-ops (`tests/render_test.py` checks it).

Design, rules and runbook live in titan-ops:
[docs/infra/environments/local-cluster/](https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md).

## Layout

| Path | What |
|---|---|
| `mac/` | Lima VM definitions and their provisioning; `scripts/`: `up.sh` · `down.sh`, the secrets bootstrap, a Terraform acceptance token for dev; `tests/` of the provisioning; the regression runner overlay |
| `gitops/apps/` | ArgoCD app-of-apps: `root-local-mac` and one Application per app |
| `base/` | The manifests every environment shares; staging builds on them from titan-ops |
| `gitops/<app>/` | Dev's overlay of each app, on `../../base/<app>` |
| `scripts/pull-images.py` | Moves dev to the images other repositories published from main |
| `tests/` | Render checks of the overlays, the pull script, the Keycloak theme check, and the guest-log sweeper compared with titan-ops's template |

## Run

Needs: an Apple M3 or later (titan-incus runs KVM guests, so it needs nested virtualization) with 16 GB, [Lima](https://lima-vm.io/), `kubectl` and `openssl`. No account and no token: the repositories and the images are public.
The bootstrap keeps the values it generates in `~/.config/titan-local-cluster/` (`secrets.env`, the S3 CA and SeaweedFS's certificate; keys mode 600), so a rebuilt cluster gets them again; keep that folder. Backups go to SeaweedFS in titan-k3s (`gitops/seaweedfs`), over TLS at `https://lima-titan-k3s.internal:30833`, with its data in `~/.local/share/titan-local-cluster/s3` on the Mac, which outlives the VM. Docker Desktop must be quit.

```sh
bash mac/scripts/up.sh      # creates the VMs on first run, then starts them, applies secrets and root-local-mac
bash mac/scripts/down.sh    # stops both VMs; disks and data stay
```

`memory` in `mac/titan-k3s.yaml` applies when the VM is created. To resize a running one: `limactl stop titan-k3s && limactl edit --memory 4 titan-k3s && limactl start titan-k3s` (about 15 seconds of downtime; the pods come back by themselves).

ArgoCD: http://argocd.localhost:8080 · portal: http://portal.localhost:8080.

After `up.sh`, ArgoCD keeps installing for a while; the cluster is ready when every application is `Synced` and `Healthy`
(`kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml get applications -n argocd`).
Sign in to the portal as `beta-user`, with the password `BETA_USER_PASSWORD` in `~/.config/titan-local-cluster/secrets.env`
(`grep BETA_USER_PASSWORD ~/.config/titan-local-cluster/secrets.env`), and to the admin console (http://admin.localhost:8080)
as `admin-test`, whose fixed test password is in `mac/scripts/bootstrap-secrets.sh`.

Zone `local-mac` is not yet connected to titan-incus after `up.sh`: that step is not automated, so the portal cannot
create a VM until it is.

The database starts empty and archives to SeaweedFS. To rebuild titan-k3s, delete `~/.local/share/titan-local-cluster/s3`
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
python3 tests/test_pull_images.py
python3 tests/test_keycloak_theme.py && python3 scripts/keycloak-theme.py --check
bash tests/sweeper_test.sh            # network and gh signed in (titan-ops's template on GitHub)
bash mac/tests/incus-log-sweeper_test.sh
bash mac/tests/incus-uplink_test.sh
bash mac/tests/bootstrap-secrets_test.sh   # macOS only (stat -f, sed -i '')
bash mac/tests/trust-s3-ca_test.sh
```

CI runs all of these but `sweeper_test.sh` and `bootstrap-secrets_test.sh` on every push to `main` and every pull request into it.
`sweeper_test.sh` reads [OpenViCloud/titan-ops](https://github.com/OpenViCloud/titan-ops), which is private, so it runs
only on the Mac before every push, with `gh` signed in as an org member.
`bootstrap-secrets_test.sh` uses macOS's `stat` and `sed`, so it runs on the Mac too, before every push that changes `mac/`.

## License

MIT
