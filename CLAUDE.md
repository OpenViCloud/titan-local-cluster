# CLAUDE.md

OpenViCloud's dev environment: Lima VMs on a Mac and the GitOps that ArgoCD on them follows. Rules and design live in
titan (`../titan`): https://github.com/OpenViCloud/titan/blob/main/docs/infra/environments/local-cluster/topology.md and
https://github.com/OpenViCloud/titan/blob/main/docs/architecture/platform-infra.md#gitops-flow. Change a rule there, not here.

- Overlays here build on titan's staging overlays by remote base; patch only what the Mac needs. A change that staging
  needs too belongs in titan.
- Every titan reference ArgoCD renders (remote bases, Helm values, sources) names one full commit, never a branch:
  ArgoCD would keep rendering the old base. Move them all together. Links to titan's docs and the sweeper check read
  `main`.
- Application names stay as they are (`*-local-mac`, `cnpg-operator`): ArgoCD on the running cluster knows them by those names.
- Names, comments, README: English. A link to titan's docs is a full `https://github.com/OpenViCloud/titan/blob/main/…` URL.
- Commits and PRs name the human author only: no AI attribution lines.
- No `git worktree`: one checkout, isolate with branches.
- Before a push: `python3 tests/render_test.py`, `bash tests/sweeper_test.sh`, and
  `for t in mac/tests/*.sh; do bash "$t" || break; done`.
