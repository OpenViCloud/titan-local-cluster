#!/usr/bin/env python3
"""Make dev run images built on this Mac from the commit a checkout of another repository stands on.

    python3 scripts/build-local.py ../<repository>      (from the repo root, on the Mac; both Lima VMs running)

The checkout's HEAD is sent with `git archive` to buildkit in titan-incus, every image of that repository in IMAGES is
built the way its CI workflow builds it at that commit (context, Dockerfile, platform, labels), imported into
titan-k3s's containerd, and its dev overlay gets newTag `local-<12 hex of the commit>`. Committing and pushing main
here is the deploy, as after a pull. Promotion refuses that tag: it takes only the 7 or 40 hex characters CI tags with.

Refused before anything is built: tracked changes not committed (the image would not hold them), a commit on no
branch of origin (nobody else could find what dev ran), a repository without images here, a workflow building in a way
this script does not repeat (build-args, target, …), an overlay not ending with its image, and a buildkit whose build
steps run outside buildkit.slice (the memory cap would stop nothing). A failed send, build or import writes nothing.

Exit 0 written / nothing to write · 2 error, nothing written (unless writing an overlay itself fails). The last stdout
line is BUILD_RESULT=WRITTEN|NO_CHANGE|ERROR; the error itself goes to stderr.
"""
import argparse
import importlib.util
import pathlib
import posixpath
import re
import subprocess
import sys
import tempfile
import time

_spec = importlib.util.spec_from_file_location("pull_images", pathlib.Path(__file__).resolve().parent / "pull-images.py")
pull = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pull)
IMAGES = pull.IMAGES
ToolError = pull.ToolError

BUILD_VM = "titan-incus"
CLUSTER_VM = "titan-k3s"
WORK = "/var/tmp/build-local"
PLATFORM = "linux/arm64"
ORIGIN = re.compile(r"^(?:https://github\.com/|git@github\.com:)([^/\s]+/[^/\s]+?)(?:\.git)?/?$")
# Keys of docker/build-push-action this script repeats; any other one would make the local image differ from CI's.
BUILD_KEYS = {"context", "file", "labels", "platforms", "push", "tags"}
# The one expression a label may hold: the repository, which this script knows from origin.
REPOSITORY_EXPRESSION = "${{ github.repository }}"
# Where the running buildkitd is (its build steps go under the same slice); a unit changed but not restarted fails.
RUNNING_CGROUP = "0::/buildkit.slice/buildkit.service"
CGROUP_PARENT = re.compile(r'^\s*defaultCgroupParent\s*=\s*"buildkit\.slice"\s*$', re.MULTILINE)


def local_tag(sha):
    return "local-" + sha[:12]


def repository_of(url):
    match = ORIGIN.match(url.strip())
    return match.group(1) if match else None


def run_command(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def pipe_commands(producer, consumer):
    """Runs `producer | consumer`; returns both exit codes and their stderr. stderr goes to files: a pipe nobody reads
    until the end would block a command writing more than the pipe holds."""
    with tempfile.TemporaryFile() as first_err, tempfile.TemporaryFile() as second_err:
        first = subprocess.Popen(producer, stdout=subprocess.PIPE, stderr=first_err)
        second = subprocess.Popen(consumer, stdin=first.stdout, stdout=subprocess.DEVNULL, stderr=second_err)
        first.stdout.close()
        second.wait()
        first.wait()
        first_err.seek(0)
        second_err.seek(0)
        return first.returncode, second.returncode, (first_err.read() + second_err.read()).decode(errors="replace")


def checked(run, cmd, what):
    result = run(cmd)
    if result.returncode != 0:
        raise ToolError(what + " exited " + str(result.returncode) + ": " + result.stderr.strip()[-2000:])
    return result.stdout


def on_vm(vm, *cmd):
    return ["limactl", "shell", vm, "--", "sudo"] + list(cmd)


def build_step(text, where):
    """The `with:` keys of the one docker/build-push-action step of a workflow."""
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines)
              if not line.lstrip().startswith("#") and re.search(r"\buses:\s*docker/build-push-action@", line)]
    if len(starts) != 1:
        raise ToolError(where + " has " + str(len(starts)) + " docker/build-push-action steps; needs exactly one")
    column = lines[starts[0]].index("uses:")
    keys = {}
    inside = False
    child = None
    for line in lines[starts[0] + 1:]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if not inside:
            if indent < column or line.lstrip().startswith("-"):
                break
            inside = indent == column and line.strip() == "with:"
            continue
        if indent <= column:
            break
        if child is None:
            child = indent
        if indent == child:
            key, _, value = line.strip().partition(":")
            keys[key.strip()] = value.strip()
    if not keys:
        raise ToolError(where + ": the docker/build-push-action step has no `with:` keys")
    return keys


def build_plan(keys, image, repository, where):
    """Context dir, Dockerfile (dir, name) relative to the repository root, and labels, checked against the row."""
    unknown = sorted(set(keys) - BUILD_KEYS)
    if unknown:
        raise ToolError(where + " builds with " + ", ".join(unknown) + ", which build-local does not repeat")
    # A tag holds `${{ … }}` with spaces: tags are split on commas only.
    tags = [tag.strip() for tag in keys.get("tags", "").split(",") if tag.strip()]
    if len(tags) != 1 or tags[0].split(":", 1)[0] != image["image"]:
        raise ToolError(where + " tags " + (", ".join(tags) or "nothing") + ", not one tag of " + image["image"])
    if keys.get("platforms", "") != PLATFORM:
        raise ToolError(where + " builds for " + (keys.get("platforms") or "no platform") + ", not " + PLATFORM)
    labels = []
    if keys.get("labels"):
        label = keys["labels"].replace(REPOSITORY_EXPRESSION, repository)
        # A block (`|`) or another expression would need a reading of YAML or of GitHub's context this script lacks.
        if label in ("|", ">") or "${{" in label or "=" not in label:
            raise ToolError(where + " labels the image with " + keys["labels"] + ", which build-local cannot repeat")
        labels.append(label)
    context = posixpath.normpath(keys.get("context", "."))
    dockerfile = posixpath.normpath(keys.get("file") or posixpath.join(context, "Dockerfile"))
    return context, posixpath.dirname(dockerfile) or ".", posixpath.basename(dockerfile), labels


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Build a checkout's images on the Mac's dev cluster and point dev at them.")
    parser.add_argument("checkout", help="path of a checkout of a repository whose images dev runs")
    return parser.parse_args(argv)


def main(argv, images, run, pipe, root):
    writes = {}
    changes = []
    try:
        try:
            args = parse_args(argv)
        except SystemExit:
            raise ToolError("bad arguments")
        checkout = str(pathlib.Path(args.checkout).resolve())

        def git(*cmd):
            return checked(run, ["git", "-C", checkout] + list(cmd), "git " + cmd[0]).strip()

        url = git("config", "--get", "remote.origin.url")
        repository = repository_of(url)
        rows = [image for image in images if image["repo"] == repository]
        if not rows:
            raise ToolError((repository or url) + " has no image in IMAGES; build-local builds only those")
        if git("status", "--porcelain", "--untracked-files=no"):
            raise ToolError(checkout + " has uncommitted changes: commit them, the image is built from the commit")
        sha = git("rev-parse", "HEAD")
        git("fetch", "-q", "--prune", "origin")
        if not git("branch", "-r", "--list", "origin/*", "--contains", sha):
            raise ToolError(sha + " is on no branch of origin: push it, so the commit dev runs can be found")
        tag = local_tag(sha)
        name = repository.split("/", 1)[1]
        src = WORK + "/" + name + "/src"

        plans = []
        for image in rows:
            where = repository + ":.github/workflows/" + image["workflow"] + "@" + sha[:12]
            text = git("show", sha + ":.github/workflows/" + image["workflow"])
            context, dockerfile_dir, dockerfile, labels = build_plan(build_step(text, where), image, repository, where)
            overlay = "gitops/" + image["app"] + "/kustomization.yaml"
            path = root / overlay
            current = path.read_text()
            if pull.image_in(current, overlay) != image["image"]:
                raise ToolError(overlay + " does not end with " + image["image"])
            tags = pull.TAG.findall(current)
            if len(tags) != 1:
                raise ToolError(overlay + " has " + str(len(tags)) + " newTag lines; needs exactly one")
            plans.append((image, context, dockerfile_dir, dockerfile, labels, path, current, tags[0][1]))

        state = checked(run, on_vm(BUILD_VM, "/usr/local/sbin/buildkit-check"), "buildkit-check").splitlines()
        if len(state) < 2 or state[0] != "active" or state[1] != RUNNING_CGROUP or not CGROUP_PARENT.search(
                "\n".join(state[2:])):
            raise ToolError("buildkit on " + BUILD_VM + " must be active with build steps in buildkit.slice (got: "
                            + " | ".join(state) + "); provision it again with mac/provision/incus.sh")

        sent = pipe(["git", "-C", checkout, "archive", "--format=tar", sha],
                    on_vm(BUILD_VM, "sh", "-c", "rm -rf " + src + " && mkdir -p " + src + " && tar -x -C " + src))
        if sent[0] != 0 or sent[1] != 0:
            raise ToolError("sending " + sha[:12] + " to " + BUILD_VM + " exited " + str(sent[:2]) + ": " + sent[2])

        tars = []
        for image, context, dockerfile_dir, dockerfile, labels, _, _, _ in plans:
            tar = WORK + "/" + name + "/" + image["app"] + ".tar"
            started = time.monotonic()
            checked(run, on_vm(BUILD_VM, "buildctl", "build", "--frontend", "dockerfile.v0",
                               "--local", "context=" + posixpath.normpath(posixpath.join(src, context)),
                               "--local", "dockerfile=" + posixpath.normpath(posixpath.join(src, dockerfile_dir)),
                               "--opt", "filename=" + dockerfile, "--opt", "platform=" + PLATFORM,
                               *[part for label in labels for part in ("--opt", "label:" + label)],
                               "--output", "type=docker,name=" + image["image"] + ":" + tag + ",dest=" + tar),
                    "buildctl build " + image["app"])
            print("  built " + image["image"] + ":" + tag + " in " + str(round(time.monotonic() - started)) + " s")
            tars.append((image, tar))

        # Every time, not only when containerd lacks the tag: it may hold that tag on other content.
        for image, tar in tars:
            reference = image["image"] + ":" + tag
            imported = pipe(on_vm(BUILD_VM, "cat", tar), on_vm(CLUSTER_VM, "k3s", "ctr", "-n", "k8s.io", "images",
                                                                "import", "-"))
            if imported[0] != 0 or imported[1] != 0:
                raise ToolError("importing " + reference + " exited " + str(imported[:2]) + ": " + imported[2])
            print("  imported " + reference + " into " + CLUSTER_VM)

        for image, _, _, _, _, path, current, old in plans:
            if old != tag:
                writes[path] = pull.TAG.sub(lambda match: match.group(1) + '"' + tag + '"', current)
                changes.append(image["app"] + ": " + old + " -> " + tag)
        for path, text in writes.items():
            path.write_text(text)
    except (ToolError, ValueError, KeyError, OSError) as failure:
        print("ERROR: " + str(failure), file=sys.stderr)
        print("BUILD_RESULT=ERROR")
        return 2
    if len(writes) == 0:
        print("BUILD_RESULT=NO_CHANGE")
        return 0
    for change in changes:
        print("  " + change)
    print("BUILD_RESULT=WRITTEN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], IMAGES, run_command, pipe_commands, pathlib.Path.cwd()))
