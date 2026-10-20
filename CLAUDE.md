# CLAUDE.md

OpenViCloud's dev environment: Lima VMs on a Mac and the GitOps that ArgoCD on them follows. Rules and design live in
titan (`../titan`, https://github.com/OpenViCloud/titan): `docs/infra/environments/local-cluster/` and
`docs/architecture/platform-infra.md#gitops-flow`. Change a rule there, not here.

- Overlays here build on titan's staging overlays by remote base; patch only what the Mac needs. A change that staging
  needs too belongs in titan.
- Every titan reference names one full commit, never a branch (ArgoCD would keep rendering the old base). Move them
  all together.
- Application names keep the `-local-mac` suffix: ArgoCD on the running cluster knows them by those names.
- Names, comments, README: English. A link to titan's docs is a full `https://github.com/OpenViCloud/titan/blob/main/…` URL.
- Commits and PRs name the human author only: no AI attribution lines.
- No `git worktree`: one checkout, isolate with branches.
- Before a push: `python3 tests/render_test.py`, `bash tests/sweeper_test.sh`, `bash mac/tests/*.sh` (one at a time).
