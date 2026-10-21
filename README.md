# titan-local-cluster — OpenViCloud's dev environment on a Mac

The dev environment of [OpenViCloud](https://github.com/OpenViCloud/titan): two Lima VMs on one Mac (k3s with ArgoCD,
and a one-node Incus 7.0 LTS that is zone `local-mac`), and the GitOps that ArgoCD on that k3s follows.

The manifests are staging's: every overlay here builds on the matching staging overlay in titan
(`https://github.com/OpenViCloud/titan//gitops/<app>/overlays/staging?ref=<commit>`) and changes only what the Mac
needs — hostnames, the zone list, the token issuer, no Incus tunnel sidecar, smaller requests, dev's own image tags. Staging is deployed from titan;
this repository never reaches it.

Every reference to titan (remote bases, Helm values, the realm import) names the same full titan commit: ArgoCD caches
a render by the revision of this repository, so a change to a base on a moving branch is neither rendered nor applied without a hard refresh and a manual sync. Dev takes a newer
titan commit when that commit is written here; `tests/render_test.py` checks that every titan reference in the YAML names one full commit.

Design, rules and runbook live in titan:
[docs/infra/environments/local-cluster/](https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md).

## Layout

| Path | What |
|---|---|
| `mac/` | Lima VM definitions and their provisioning; `scripts/`: `up.sh` · `down.sh`, the secrets bootstrap, a Terraform acceptance token for dev; `tests/` of the provisioning; the regression runner overlay |
| `gitops/apps/` | ArgoCD app-of-apps: `root-local-mac` and one Application per app |
| `gitops/<app>/` | Dev's overlay of each app |
| `scripts/pull-images.py` | Moves dev to what main publishes: other repositories' images, titan's commit, and the image names staging gives |
| `scripts/build-local.py` | Builds a checkout's images in titan-incus (buildkit), imports them into titan-k3s, and points dev at them |
| `tests/` | Render checks of the overlays, the pull and build-local scripts, buildkit's provisioning, and the guest-log sweeper compared with titan's template |

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
python3 scripts/pull-images.py      # writes newTag, the titan commit and the image entry names; needs `gh` logged in
git commit -am "Pull published images into dev" && git push   # ArgoCD on dev follows main: the push is the deploy
```

`--titan <commit>` pins an older commit on titan's main instead of its head; a commit off main is an ERROR. One bad row writes nothing.

A tag `local-<12 hex>` (below) stays: `--replace <owner/repo>` moves that repository to main's images (after its PR
merged), `--all` moves every image (a release starts: promotion refuses a local tag).

## Run a branch on dev

```sh
python3 scripts/build-local.py ../control-plane      # the checkout's HEAD: committed, and on a branch of origin
git commit -am "Run control-plane <branch> on dev" && git push
```

The commit goes with `git archive` to buildkit in titan-incus (installed by `mac/provision/incus.sh`, build steps capped
in `buildkit.slice`), every image of that repository is built the way its CI workflow builds it at that commit, imported
into titan-k3s's containerd, and its overlay gets newTag `local-<12 hex>`. Uncommitted changes, a commit on no branch of
origin, a workflow building with options this script does not repeat, or a buildkit outside its slice are an ERROR
before anything is built. Building the same commit again writes nothing and imports again: after titan-k3s was rebuilt
it brings the image back; a pod already running that tag keeps what it started with until it restarts. The last line
is `BUILD_RESULT=WRITTEN|NO_CHANGE|ERROR`. Outside this repository it runs `git fetch --prune origin` in the checkout
and leaves the source and image tars under `/var/tmp/build-local/` on titan-incus, replaced at the next build.

## Tests

```sh
python3 tests/render_test.py          # kubectl, ruby, network (remote bases on GitHub)
python3 tests/test_pull_images.py
python3 tests/test_build_local.py
bash tests/sweeper_test.sh            # network (titan's template on GitHub)
bash mac/tests/incus-log-sweeper_test.sh
bash mac/tests/incus-uplink_test.sh
```

CI runs all six on every push to `main` and every pull request into it.

## License

MIT
