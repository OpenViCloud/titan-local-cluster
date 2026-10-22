# titan-local-cluster — OpenViCloud's dev environment on a Mac

The dev environment of [OpenViCloud](https://github.com/OpenViCloud): two Lima VMs on one Mac (k3s with ArgoCD,
and a one-node Incus 7.0 LTS that is zone `local-mac`), and the GitOps that ArgoCD on that k3s follows.

The manifests are staging's: every overlay here builds on the matching staging overlay in titan-ops
(`https://github.com/OpenViCloud/titan-ops//gitops/<app>/overlays/staging?ref=<commit>`) and changes only what the Mac
needs — hostnames, the zone list, the token issuer, no Incus tunnel sidecar, smaller requests, dev's own image tags. Staging is deployed from titan-ops;
this repository never reaches it.

Every reference to titan-ops (remote bases, Helm values, the realm import) names the same full titan-ops commit: ArgoCD caches
a render by the revision of this repository, so a change to a base on a moving branch is neither rendered nor applied without a hard refresh and a manual sync. Dev takes a newer
titan-ops commit when that commit is written here; `tests/render_test.py` checks that every titan-ops reference in the YAML names one full commit.

Design, rules and runbook live in titan-ops:
[docs/infra/environments/local-cluster/](https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md).

## Layout

| Path | What |
|---|---|
| `mac/` | Lima VM definitions and their provisioning; `scripts/`: `up.sh` · `down.sh`, the secrets bootstrap, a Terraform acceptance token for dev; `tests/` of the provisioning; the regression runner overlay |
| `gitops/apps/` | ArgoCD app-of-apps: `root-local-mac` and one Application per app |
| `gitops/<app>/` | Dev's overlay of each app |
| `scripts/pull-images.py` | Moves dev to what main publishes: other repositories' images, titan-ops's commit, and the image names staging gives |
| `tests/` | Render checks of the overlays, the pull script, and the guest-log sweeper compared with titan-ops's template |

## Run

Needs: an Apple M3 or later (titan-incus runs KVM guests, so it needs nested virtualization) with 16 GB, [Lima](https://lima-vm.io/), `kubectl`, and `infisical login` done (the bootstrap
reads two read-only tokens from Infisical environment `local`). Docker Desktop must be quit.

```sh
bash mac/scripts/up.sh      # creates the VMs on first run, then starts them, applies secrets and root-local-mac
bash mac/scripts/down.sh    # stops both VMs; disks and data stay
```

ArgoCD: http://argocd.localhost:8080 · portal: http://portal.localhost:8080.

## Move dev to main

```sh
python3 scripts/pull-images.py      # writes newTag, the titan-ops commit and the image entry names; needs `gh` logged in
git commit -am "Pull published images into dev" && git push   # ArgoCD on dev follows main: the push is the deploy
kubectl --kubeconfig ~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml annotate applications.argoproj.io --all -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

The refresh is so ArgoCD need not wait for its next poll: a push took 162 s to about 6 minutes to show up (measured
2026-10-21, before refreshing was the rule); with the refresh, at most 12 s for all 8 apps that follow this repository
(measured once, 2026-10-22). Do the same after merging a pull request here. Code of other repositories reaches dev
only as the images their CI publishes from main.

`--titan <commit>` pins an older commit on titan-ops's main instead of its head; a commit off main is an ERROR. One bad row writes nothing.

## Tests

```sh
python3 tests/render_test.py          # kubectl, ruby, network (remote bases on GitHub)
python3 tests/test_pull_images.py
bash tests/sweeper_test.sh            # network and gh signed in (titan-ops's template on GitHub)
bash mac/tests/incus-log-sweeper_test.sh
bash mac/tests/incus-uplink_test.sh
```

CI runs all five on every push to `main` and every pull request into it.

## License

MIT
