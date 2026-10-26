#!/usr/bin/env python3
"""Move dev to what main publishes: the images other repositories last published from their main.

    python3 scripts/pull-images.py
                                                            (from the repo root, on the Mac; needs `gh` logged in)

It writes, and only writes; committing and pushing to main is the deploy (ArgoCD on dev follows main here): newTag of
each dev overlay in IMAGES, the newest commit every workflow of that repository published from main (images of one
repository move together). Every tag moves: dev runs only images CI published. Each overlay's `images` entry must be
the name base/<app>/deployment.yaml gives the image: any other name matches nothing, and dev would silently run the
base's placeholder, so the pull stops there instead. Everything is read and checked before anything is written: one
bad row writes nothing.

Exit 0 written / nothing to do · 2 error, nothing written. The last stdout line is PULL_RESULT=WRITTEN|NO_CHANGE|ERROR;
the error itself goes to stderr.

    python3 scripts/pull-images.py --wait <repo>@<40 hex>

--wait <repo>@<commit> (right after merging a PR of an IMAGES repository, its merge commit) only waits, and writes
nothing: until every workflow IMAGES lists for that repository finished its push run on main for that commit, printing
one line per finished workflow. A run not created yet is waited for. The last stdout line is WAIT_RESULT=OK (exit 0),
or WAIT_RESULT=ERROR (exit 2) for any conclusion but success, a failed GitHub call, a run still unfinished after
WAIT_LIMIT_SECONDS, or bad arguments (a repository outside IMAGES, a short commit, another flag). Pull after OK, in a
separate run: the wait takes minutes, and other sessions push main here meanwhile.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

# A push run on main takes at most ~4 minutes (measured in titan's iteration:deploy); the rest is room for a queue.
# With a last poll and GH_TIMEOUT_SECONDS per call (one workflow per repository in IMAGES: about 21.5 minutes) it stays
# under the 25 minutes the Monitor that runs --wait is given, so the result line gets out.
WAIT_LIMIT_SECONDS = 20 * 60
WAIT_POLL_SECONDS = 30
GH_TIMEOUT_SECONDS = 60
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
TAG = re.compile(r'^(\s*newTag:\s*)"([^"]+)"', re.MULTILINE)
NEW_NAME = re.compile(r"^(\s*newName:\s*)(\S+)\n", re.MULTILINE)
ENTRY_NAME = re.compile(r"^(\s*-\s*name:\s*)(\S+)\n", re.MULTILINE)
BASE_IMAGE = re.compile(r"^\s*image:\s*([^\s:]+)(?::\S*)?\s*$", re.MULTILINE)

# One row per image another repository publishes. tag_length: how many characters of the commit that repository
# tags its image with. app: gitops/<app>/ and base/<app>/ here.
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
    return subprocess.run(cmd, capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS)


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


def base_image_name(root, app):
    """The name base/<app>/deployment.yaml gives the image: the name an overlay's images entry must match."""
    where = "base/" + app + "/deployment.yaml"
    names = BASE_IMAGE.findall((root / where).read_text())
    if len(names) != 1:
        raise ToolError(where + " needs exactly one image line, found " + str(len(names)))
    return names[0]


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


def parse_args(argv):
    # No abbreviations: `--wai` would wait yet report its errors as a pull.
    parser = argparse.ArgumentParser(allow_abbrev=False, description="Move dev to the images main publishes.")
    parser.add_argument("--wait", help="<repo>@<full 40-hex commit>: only wait for that repository's push runs on main")
    return parser.parse_args(argv)


def wait(args, workflows_by_repo, run, sleep, clock):
    wait_repo, _, wait_sha = args.wait.partition("@")
    if wait_repo not in workflows_by_repo:
        raise ToolError("--wait names " + wait_repo + "; IMAGES has " + ", ".join(workflows_by_repo))
    # GitHub matches head_sha only in full: a short commit finds no run and would wait out the limit.
    if not GIT_SHA.match(wait_sha):
        raise ToolError("--wait needs a full 40-hex commit, got " + (wait_sha or "none"))
    wait_for_commit(run, wait_repo, workflows_by_repo[wait_repo], wait_sha, sleep, clock)


def main(argv, images, run, root, sleep=time.sleep, clock=time.monotonic):
    writes = {}
    changes = []
    # Read before parsing: a waiting run ends with WAIT_RESULT even when its arguments are bad.
    result = "WAIT_RESULT" if any(arg.split("=")[0] == "--wait" for arg in argv) else "PULL_RESULT"
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
        if args.wait is not None:
            wait(args, workflows_by_repo, run, sleep, clock)
            print("WAIT_RESULT=OK")
            return 0
        commits = {repo: repository_commit(run, repo, workflows) for repo, workflows in workflows_by_repo.items()}

        for image in images:
            where = "gitops/" + image["app"] + "/kustomization.yaml"
            path = root / where
            text = path.read_text()
            if image_in(text, where) != image["image"]:
                raise ToolError(where + " does not end with " + image["image"])
            tags = TAG.findall(text)
            if len(tags) != 1:
                raise ToolError(where + " has " + str(len(tags)) + " newTag lines; needs exactly one")
            entry = ENTRY_NAME.findall(images_block(text))[0][1]
            base_name = base_image_name(root, image["app"])
            if entry != base_name:
                raise ToolError(where + ": images entry " + entry + " matches nothing; base/" + image["app"]
                                + " names its image " + base_name)
            new_text = text
            wanted = commits[image["repo"]][:image["tag_length"]]
            if tags[0][1] != wanted:
                new_text = TAG.sub(lambda match: match.group(1) + '"' + wanted + '"', new_text)
                changes.append(image["app"] + ": " + tags[0][1] + " -> " + wanted)
            if new_text != path.read_text():
                writes[path] = new_text
    except (ToolError, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as failure:
        print("ERROR: " + str(failure), file=sys.stderr)
        print(result + "=ERROR")
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
