# titan-local-cluster — OpenViCloud's dev environment on a Mac

The dev environment of [OpenViCloud](https://github.com/OpenViCloud/titan): two Lima VMs on one Mac (k3s with ArgoCD,
and a one-node Incus 7.0 LTS that is zone `local-mac`), and the GitOps that ArgoCD on that k3s follows.

The manifests are staging's: every overlay here builds on the matching staging overlay in titan
(`https://github.com/OpenViCloud/titan//gitops/<app>/overlays/staging?ref=main`) and changes only what the Mac needs —
hostnames, the zone list, smaller requests, dev's own image tags. Staging and production are deployed from titan; this
repository never reaches them.

Design, rules and runbook live in titan:
[docs/infra/environments/local-cluster/](https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md).

## Layout

| Path | What |
|---|---|
| `mac/` | Lima VM definitions, their provisioning, `scripts/up.sh` · `down.sh`, the secrets bootstrap, the regression runner overlay |
| `gitops/apps/` | ArgoCD app-of-apps: `root-local-mac` and one Application per app |
| `gitops/<app>/` | Dev's overlay of each app |
| `tests/` | Render checks of the overlays, and the guest-log sweeper compared with titan's template |

## Run

Needs: an Apple silicon Mac with 16 GB, [Lima](https://lima-vm.io/), `kubectl`, and `infisical login` done (the bootstrap
reads two read-only tokens from Infisical environment `local`). Docker Desktop must be quit.

```sh
bash mac/scripts/up.sh      # creates the VMs on first run, then starts them, applies secrets and root-local-mac
bash mac/scripts/down.sh    # stops both VMs; disks and data stay
```

ArgoCD: http://argocd.localhost:8080 · portal: http://portal.localhost:8080.

## Tests

```sh
python3 tests/render_test.py          # kubectl, ruby, network (remote bases on GitHub)
bash tests/sweeper_test.sh            # network (titan's template on GitHub)
bash mac/tests/incus-log-sweeper_test.sh
bash mac/tests/incus-uplink_test.sh
```

CI runs all four on every push and pull request.

## License

MIT
