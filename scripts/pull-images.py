#!/usr/bin/env python3
"""Move dev to what main publishes: the images other repositories last published from their main, and titan-ops's main.

    python3 scripts/pull-images.py [--titan <40 hex>] [--wait <repo>@<40 hex>]
                                                            (from the repo root, on the Mac; needs `gh` logged in)

--wait <repo>@<commit> (right after merging a PR of an IMAGES repository, its merge commit) first waits until every
workflow of that repository finished its push run on main for that commit, printing one line per finished workflow.
A run not created yet is waited for; any conclusion but success, or a run still unfinished after WAIT_LIMIT_SECONDS,
is an error and nothing is written.

It writes, and only writes; committing and pushing to main is the deploy (ArgoCD on dev follows main here):
- newTag of each dev overlay in IMAGES: the newest commit every workflow of that repository published from main
  (images of one repository move together). Every tag moves: dev runs only images CI published;
- every titan-ops reference ArgoCD renders (remote bases, Helm values, sources): titan-ops's main, or --titan, a commit
  titan-ops's main contains (anything else is an error);
- each overlay's `images` entry: the name staging's overlay gives the image at that titan-ops commit. The entry matches
  the image by that name; when a promotion renames it in titan-ops and the entry keeps the old name, the entry matches
  nothing and dev silently runs staging's tag.
Everything is read and checked before anything is written: one bad row writes nothing.

Exit 0 written / nothing to do · 2 error, nothing written. The last stdout line is PULL_RESULT=WRITTEN|NO_CHANGE|ERROR;
the error itself goes to stderr.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

TITAN = "OpenViCloud/titan-ops"
# A push run on main takes at most ~4 minutes (measured in titan's iteration:deploy); the rest is room for a queue.
# It stays under the 25 minutes the Monitor that runs --wait is given, so the result line always gets out.
WAIT_LIMIT_SECONDS = 20 * 60
WAIT_POLL_SECONDS = 30
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
TAG = re.compile(r'^(\s*newTag:\s*)"([^"]+)"', re.MULTILINE)
NEW_NAME = re.compile(r"^(\s*newName:\s*)(\S+)\n", re.MULTILINE)
ENTRY_NAME = re.compile(r"^(\s*-\s*name:\s*)(\S+)\n", re.MULTILINE)
REMOTE_BASE = re.compile(r"(https://github\.com/OpenViCloud/titan-ops//\S+\?ref=)(\S+)")
SOURCE = re.compile(r"(repoURL: https://github\.com/OpenViCloud/titan-ops\n\s+targetRevision: )(\S+)")

# One row per image another repository publishes. tag_length: how many characters of the commit that repository
# tags its image with. app: gitops/<app>/ here, gitops/<app>/overlays/staging in titan-ops.
IMAGES = [
    {"repo": "OpenViCloud/titan-control-plane", "workflow": "ci.yml", "image": "ghcr.io/openvicloud/titan-control-plane",
     "app": "control-plane", "tag_length": 7},
    {"repo": "OpenViCloud/titan-cloud-console", "workflow": "ci-portal.yml",
     "image": "ghcr.io/openvicloud/titan-cloud-console", "app": "cloud-console", "tag_length": 7},
    {"repo": "OpenViCloud/titan-admin-console", "workflow": "ci-admin-portal.yml",
     "image": "ghcr.io/openvicloud/titan-admin-console", "app": "admin-portal", "tag_length": 7},
    {"repo": "OpenViCloud/titan-landing", "workflow": "ci-site.yml", "image": "ghcr.io/openvicloud/titan-landing",
     "app": "site", "tag_length": 7},
    {"repo": "OpenViCloud/titan-incus-worker", "workflow": "ci.yml", "image": "ghcr.io/openvicloud/titan-incus-worker",
     "app": "incus-worker", "tag_length": 40},
]


class ToolError(Exception):
    pass


def run_command(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def gh_api(run, query, raw=False):
    cmd = ["gh", "api"] + (["-H", "Accept: application/vnd.github.raw"] if raw else []) + [query]
    result = run(cmd)
    if result.returncode != 0:
        raise ToolError("gh api " + query + " exited " + str(result.returncode) + ": " + result.stderr.strip())
    return result.stdout


def images_block(text):
    """The lines of the top-level `images:` block: other blocks (configMapGenerator, patches) have `- name:` too."""
    lines = text.splitlines(keepends=True)
    start = None
    for index, line in enumerate(lines):
        if line.rstrip() == "images:":
            start = index + 1
            break
    if start is None:
        return ""
    block = []
    for line in lines[start:]:
        if line.strip() != "" and not line[0].isspace() and not line.startswith("#"):
            break
        block.append(line)
    return "".join(block)


def image_in(text, where):
    """The image an overlay ends with: its newName, else the name its single images entry matches."""
    block = images_block(text)
    new_names = [name for _, name in NEW_NAME.findall(block)]
    names = [name for _, name in ENTRY_NAME.findall(block)]
    if len(names) == 1 and len(new_names) <= 1:
        return new_names[0] if new_names else names[0]
    raise ToolError(where + " needs exactly one image entry and at most one newName")


def with_entry(text, entry, image, where):
    """The overlay with its single images entry named `entry`, ending with `image`."""
    block = images_block(text)
    if len(ENTRY_NAME.findall(block)) != 1:
        raise ToolError(where + " needs exactly one image entry")
    renamed = NEW_NAME.sub("", block)
    renamed = ENTRY_NAME.sub(lambda match: match.group(1) + entry + "\n", renamed)
    if entry != image:
        renamed = ENTRY_NAME.sub(lambda match: match.group(0) + "    newName: " + image + "\n", renamed)
    return text.replace(block, renamed)


def published_commits(run, repo, workflow):
    """Commits of the newest successful push runs on main of one workflow, newest first."""
    query = "repos/" + repo + "/actions/workflows/" + workflow + "/runs?branch=main&event=push&status=success&per_page=30"
    return [entry["head_sha"] for entry in json.loads(gh_api(run, query))["workflow_runs"]]


def repository_commit(run, repo, workflows):
    """The newest commit every workflow of the repository published: all its images come from one tree, and a commit
    whose tests failed in one workflow moves no image."""
    lists = [published_commits(run, repo, workflow) for workflow in workflows]
    for sha in lists[0]:
        if all(sha in other for other in lists[1:]):
            return sha
    raise ToolError(repo + ": no commit among the last 30 successful push runs on main of " + ", ".join(workflows))


def commit_runs(run, repo, workflow, sha):
    """Push runs on main of one workflow for one commit, newest first; no status filter, a failed run counts."""
    query = ("repos/" + repo + "/actions/workflows/" + workflow + "/runs?branch=main&event=push&head_sha=" + sha
             + "&per_page=5")
    return json.loads(gh_api(run, query))["workflow_runs"]


def wait_for_commit(run, repo, workflows, sha, sleep, clock):
    """Wait until every workflow of the repository finished its push run on main for the commit. Right after a merge
    a run may not exist yet: that is waited for too, not read as "no CI"."""
    deadline = clock() + WAIT_LIMIT_SECONDS
    finished = {}
    while True:
        for workflow in workflows:
            if workflow in finished:
                continue
            runs = commit_runs(run, repo, workflow, sha)
            if len(runs) == 0 or runs[0]["status"] != "completed":
                continue
            finished[workflow] = runs[0]["conclusion"]
            print("  " + repo + " " + workflow + ": " + str(runs[0]["conclusion"]) + " " + runs[0]["html_url"],
                  flush=True)
            if runs[0]["conclusion"] != "success":
                raise ToolError(repo + " " + workflow + " concluded " + str(runs[0]["conclusion"]) + " on " + sha)
        if len(finished) == len(workflows):
            return
        if clock() >= deadline:
            waiting = [workflow for workflow in workflows if workflow not in finished]
            raise ToolError(repo + " " + ", ".join(waiting) + ": no finished push run on main for " + sha + " after "
                            + str(WAIT_LIMIT_SECONDS // 60) + " minutes")
        sleep(WAIT_POLL_SECONDS)


def titan_references(root):
    """Every file here naming titan-ops, with the commits it names; ArgoCD renders them all."""
    found = {}
    for path in sorted(list(root.rglob("*.yaml")) + list(root.rglob("*.yml"))):
        if ".git" in path.parts or ".github" in path.parts:
            continue
        text = path.read_text()
        commits = [ref for _, ref in REMOTE_BASE.findall(text)] + [rev for _, rev in SOURCE.findall(text)]
        if commits:
            found[path] = (text, commits)
    return found


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Move dev to the images and the titan-ops commit main publishes.")
    parser.add_argument("--titan", help="full 40-hex commit on titan-ops's main (default: titan-ops's main)")
    parser.add_argument("--wait", help="<repo>@<full 40-hex commit>: wait for that repository's push runs on main first")
    return parser.parse_args(argv)


def main(argv, images, run, root, sleep=time.sleep, clock=time.monotonic):
    writes = {}
    changes = []
    try:
        try:
            args = parse_args(argv)
        except SystemExit:
            raise ToolError("bad arguments")
        workflows_by_repo = {}
        for image in images:
            workflows_by_repo.setdefault(image["repo"], [])
            if image["workflow"] not in workflows_by_repo[image["repo"]]:
                workflows_by_repo[image["repo"]].append(image["workflow"])
        if args.wait:
            wait_repo, _, wait_sha = args.wait.partition("@")
            if wait_repo not in workflows_by_repo:
                raise ToolError("--wait names " + wait_repo + "; IMAGES has " + ", ".join(workflows_by_repo))
            # GitHub matches head_sha only in full: a short commit finds no run and would wait out the limit.
            if not GIT_SHA.match(wait_sha):
                raise ToolError("--wait needs a full 40-hex commit, got " + (wait_sha or "none"))
            wait_for_commit(run, wait_repo, workflows_by_repo[wait_repo], wait_sha, sleep, clock)
        titan =args.titan or json.loads(gh_api(run, "repos/" + TITAN + "/commits/main"))["sha"]
        if not GIT_SHA.match(titan):
            raise ToolError("the titan commit must be a full 40-hex commit, got " + titan)
        if args.titan:
            # Dev runs only what titan-ops merged; compare <commit>...main is "ahead" or "identical" when main contains it.
            status = json.loads(gh_api(run, "repos/" + TITAN + "/compare/" + titan + "...main"))["status"]
            if status not in ("ahead", "identical"):
                raise ToolError(titan + " is not on titan's main (compare: " + status + ")")

        references = titan_references(root)
        current = {commit for _, commits in references.values() for commit in commits}
        if len(current) != 1 or not GIT_SHA.match(next(iter(current))):
            raise ToolError("titan references must name one full commit, found " + ", ".join(sorted(current) or ["none"]))
        old_titan = current.pop()
        if old_titan != titan:
            for path, (text, _) in references.items():
                text = REMOTE_BASE.sub(lambda match: match.group(1) + titan, text)
                writes[path] = SOURCE.sub(lambda match: match.group(1) + titan, text)
            changes.append("titan: " + old_titan + " -> " + titan)

        commits ={repo: repository_commit(run, repo, workflows) for repo, workflows in workflows_by_repo.items()}

        for image in images:
            where = "gitops/" + image["app"] + "/kustomization.yaml"
            path = root / where
            text = writes.get(path, path.read_text())
            if image_in(text, where) != image["image"]:
                raise ToolError(where + " does not end with " + image["image"])
            tags = TAG.findall(text)
            if len(tags) != 1:
                raise ToolError(where + " has " + str(len(tags)) + " newTag lines; needs exactly one")
            staging_path = "gitops/" + image["app"] + "/overlays/staging/kustomization.yaml"
            staging = gh_api(run, "repos/" + TITAN + "/contents/" + staging_path + "?ref=" + titan, raw=True)
            entry = image_in(staging, TITAN + ":" + staging_path)
            old_entry = ENTRY_NAME.findall(images_block(text))[0][1]
            new_text = with_entry(text, entry, image["image"], where)
            if old_entry != entry:
                changes.append(image["app"] + " entry: " + old_entry + " -> " + entry)
            wanted = commits[image["repo"]][:image["tag_length"]]
            if tags[0][1] != wanted:
                new_text = TAG.sub(lambda match: match.group(1) + '"' + wanted + '"', new_text)
                changes.append(image["app"] + ": " + tags[0][1] + " -> " + wanted)
            if new_text != path.read_text():
                writes[path] = new_text
    except (ToolError, ValueError, KeyError, OSError) as failure:
        print("ERROR: " + str(failure), file=sys.stderr)
        print("PULL_RESULT=ERROR")
        return 2
    if len(writes) == 0:
        print("PULL_RESULT=NO_CHANGE")
        return 0
    for path, text in writes.items():
        path.write_text(text)
    for change in changes:
        print("  " + change)
    print("PULL_RESULT=WRITTEN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], IMAGES, run_command, pathlib.Path.cwd()))
