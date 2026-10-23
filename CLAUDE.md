# CLAUDE.md

OpenViCloud's dev environment: Lima VMs on a Mac and the GitOps that ArgoCD on them follows. Rules and design live in
titan-ops (`../titan-ops`): https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md and
https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/platform-infra.md#gitops-flow. Change a rule there, not here.

- Overlays here build on titan-ops's staging overlays by remote base; patch only what the Mac needs. A change that staging
  needs too belongs in titan-ops.
- Every titan-ops reference ArgoCD renders (remote bases, Helm values, sources) names one full commit, never a branch:
  ArgoCD would keep rendering the old base. Move them all together. Links to titan-ops's docs and the sweeper check read
  `main`.
- Application names stay as they are (`*-local-mac`, `cnpg-operator`): ArgoCD on the running cluster knows them by those names.
  An app renamed on purpose (as the customer portal's app when titan-ops renamed its folder to `cloud-console`): root
  prunes the old Application, which has no finalizer, so every object it rendered stays behind (for the customer
  portal: Deployment, Service, ConfigMap and Ingress) and is deleted by hand on dev right after the merge.
- Names, comments, README: English. A link to titan-ops's docs is a full `https://github.com/OpenViCloud/titan-ops/blob/main/…` URL.
- Commits and PRs name the human author only: no AI attribution lines.
- No `git worktree`: one checkout, isolate with branches.
- Image tags, the titan-ops commit and image entry names move with `python3 scripts/pull-images.py` (images main published;
  `--wait <repo>@<merge commit>` right after a merge only waits for that repository's push runs), not by hand.
  Dev runs no image built from a branch. A tag set by hand on the cluster does not stay: ArgoCD syncs it back to git.
  After a push or a merge to main: hard-refresh ArgoCD's Applications (README, "Move dev to main").
- Before a push: `python3 tests/render_test.py`, `python3 tests/test_pull_images.py`, `bash tests/sweeper_test.sh`, and
  `for t in mac/tests/*.sh; do bash "$t" || break; done`. CI does not run the render or the sweeper test: both read
  titan-ops, which is private, so this machine is the only place they run.
