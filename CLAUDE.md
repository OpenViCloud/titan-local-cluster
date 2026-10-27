# CLAUDE.md

OpenViCloud's dev environment: Lima VMs on a Mac or an Ubuntu machine (`lima/macos/`, `lima/ubuntu/`) and the GitOps that ArgoCD on them follows. Rules and design live in
titan-ops (`../titan-ops`): https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md and
https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/platform-infra.md#gitops-flow. Change a rule there, not here.

- `base/` holds the manifests every environment shares; staging's overlays in titan-ops build on it by remote base, pinned
  to one commit of this repository. Overlays here (`gitops/<app>/`) build on `../../base/<app>` and patch only what the local
  cluster needs. A change that staging needs too belongs in `base/`. Nothing ArgoCD renders here reads titan-ops, which is private
  (`tests/render_test.py`, `NoTitanRead`); links to titan-ops's docs in comments and the sweeper check do.
- Application names are `*-local` (and `cnpg-operator`, `cert-manager`, `plugin-barman-cloud`, `seaweedfs`), cluster id `local`, the
  same on macOS and Ubuntu (`tests/render_test.py`). Renaming an Application: root prunes the old one, which has no finalizer, so its
  resources stay and the new Application adopts them. The cluster id was `local-mac` until 2026-10-27: `lima/scripts/rename-cluster-id.sh`
  (run by `up.sh`) moves a dev database's rows to `local`.
  An app renamed on purpose (as the customer portal's app when titan-ops renamed its folder to `cloud-console`): root
  prunes the old Application, which has no finalizer, so every object it rendered stays behind (for the customer
  portal: Deployment, Service, ConfigMap and Ingress) and is deleted by hand on dev right after the merge.
- Names, comments, README: English. A link to titan-ops's docs is a full `https://github.com/OpenViCloud/titan-ops/blob/main/…` URL.
- Commits and PRs name the human author only: no AI attribution lines.
- No `git worktree`: one checkout, isolate with branches.
- Image tags move with `python3 scripts/pull-images.py` (images main published; an `images` entry is the name `base/<app>` gives;
  `--wait <repo>@<merge commit>` right after a merge only waits for that repository's push runs), not by hand.
  Dev runs no image built from a branch. A tag set by hand on the cluster does not stay: ArgoCD syncs it back to git.
  After a push or a merge to main: hard-refresh ArgoCD's Applications (README, "Move dev to main").
- Before a push: `python3 tests/render_test.py`, `python3 tests/test_lima_files.py`, `python3 tests/test_pull_images.py`, `python3 tests/test_keycloak_theme.py`,
  `python3 scripts/keycloak-theme.py --check`, `bash tests/sweeper_test.sh`, and
  `for t in lima/tests/*.sh; do bash "$t" || break; done`. CI runs all of them but `lima/tests/bootstrap-secrets_test.sh` (macOS's `stat -f`)
  and the sweeper test (reads titan-ops, private): the sweeper test runs on any machine signed in to `gh` as an org member,
  `bootstrap-secrets_test.sh` only on a Mac.
