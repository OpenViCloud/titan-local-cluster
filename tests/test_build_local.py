"""Tests for scripts/build-local.py. Stdlib only: python3 tests/test_build_local.py

git runs for real on a checkout and its origin in a temp dir; limactl (buildkit in titan-incus, containerd in titan-k3s)
goes through a fake. The last class reads mac/provision/incus.sh, which installs the buildkit the script talks to.
"""
import contextlib
import importlib.util
import io
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("build_local", ROOT / "scripts" / "build-local.py")
build = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build)

FRONTEND_IMAGES = [
    {"repo": "OpenViCloud/frontend", "workflow": "ci-portal.yml", "image": "ghcr.io/openvicloud/frontend-portal",
     "app": "portal", "tag_length": 7},
    {"repo": "OpenViCloud/frontend", "workflow": "ci-admin-portal.yml",
     "image": "ghcr.io/openvicloud/frontend-admin-portal", "app": "admin-portal", "tag_length": 7},
]
WORKER = {"repo": "OpenViCloud/incus-worker", "workflow": "ci.yml", "image": "ghcr.io/openvicloud/incus-worker",
          "app": "incus-worker", "tag_length": 40}


def workflow(image, context, file=None, extra=""):
    lines = ["name: CI", "on:", "  push:", "jobs:", "  build:", "    runs-on: ubuntu-latest", "    steps:",
             "      - uses: actions/checkout@v4", "      - name: Build, and push from main",
             "        uses: docker/build-push-action@v5", "        with:", "          context: " + context]
    if file is not None:
        lines.append("          file: " + file)
    # The shape of OpenViCloud/frontend's workflows at 4d5209a, labels included.
    lines += ["          platforms: linux/arm64", "          push: true",
              "          labels: org.opencontainers.image.source=https://github.com/${{ github.repository }}",
              "          tags: " + image + ":${{ env.SHORT_SHA }}"]
    return "\n".join(lines) + "\n" + extra


def overlay(name, tag):
    return ("resources:\n  - https://github.com/OpenViCloud/titan//gitops/x/overlays/staging?ref=" + "1" * 40 + "\n"
            "images:\n  - name: " + name + '\n    newTag: "' + tag + '"\n')


def git(cwd, *args):
    result = subprocess.run(["git", "-C", str(cwd)] + list(args), capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError("git " + " ".join(args) + ": " + result.stderr)
    return result.stdout.strip()


class FakeLima:
    """Answers the limactl commands build-local runs and records them; every other command runs for real."""

    def __init__(self, cgroup="0::/buildkit.slice/buildkit.service", cgroup_parent='"buildkit.slice"', fail=None):
        self.cgroup = cgroup
        self.cgroup_parent = cgroup_parent
        self.fail = fail
        self.calls = []
        self.pipes = []

    def run(self, cmd):
        if cmd[0] != "limactl":
            return subprocess.run(cmd, capture_output=True, text=True)
        self.calls.append(cmd)
        joined = " ".join(cmd)
        if self.fail is not None and self.fail in joined:
            return subprocess.CompletedProcess(cmd, 1, "", "boom: " + self.fail)
        if "buildkit-check" in joined:
            parent = "" if self.cgroup_parent is None else "defaultCgroupParent = " + self.cgroup_parent
            return subprocess.CompletedProcess(cmd, 0, "active\n" + self.cgroup + "\n" + parent + "\n", "")
        if "buildctl build" in joined:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        raise AssertionError("unexpected command: " + joined)

    def pipe(self, producer, consumer):
        self.pipes.append((producer, consumer))
        joined = " ".join(producer + ["|"] + consumer)
        if self.fail is not None and self.fail in joined:
            return 0, 1, "boom: " + self.fail
        if producer[0] == "git":
            result = subprocess.run(producer, capture_output=True)
            return result.returncode, 0, result.stderr.decode()
        return 0, 0, ""

    def builds(self):
        return [" ".join(cmd) for cmd in self.calls if "buildctl build" in " ".join(cmd)]

    def imports(self):
        return [" ".join(producer) for producer, consumer in self.pipes if "images import" in " ".join(consumer)]


def run(argv, images, lima, root):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = build.main(list(argv), images, lima.run, lima.pipe, root)
    return code, out.getvalue(), err.getvalue()


def last_line(out):
    return out.rstrip().splitlines()[-1]


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        base = pathlib.Path(self.dir.name)
        self.origin = base / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], check=True)
        self.checkout = base / "frontend"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.checkout)], check=True,
                       capture_output=True)
        git(self.checkout, "config", "user.email", "t@example.com")
        git(self.checkout, "config", "user.name", "t")
        # origin names the GitHub repository, as a real checkout's does; insteadOf sends fetch and push to the temp one.
        git(self.checkout, "remote", "set-url", "origin", "https://github.com/OpenViCloud/frontend.git")
        git(self.checkout, "config", "url." + str(self.origin) + ".insteadOf",
            "https://github.com/OpenViCloud/frontend.git")
        self.write_checkout(".github/workflows/ci-portal.yml", workflow(FRONTEND_IMAGES[0]["image"], "portal"))
        self.write_checkout(".github/workflows/ci-admin-portal.yml",
                            workflow(FRONTEND_IMAGES[1]["image"], "portal", "portal/Dockerfile.admin"))
        self.write_checkout("portal/Dockerfile", "FROM scratch\n")
        self.commit_and_push("first")
        self.root = base / "dev"
        for image in FRONTEND_IMAGES + [WORKER]:
            self.write_overlay(image["app"], overlay(image["image"], "4d5209a"))

    def tearDown(self):
        self.dir.cleanup()

    def write_checkout(self, path, text):
        target = self.checkout / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit_and_push(self, message, push=True):
        git(self.checkout, "add", "-A")
        git(self.checkout, "commit", "-q", "-m", message)
        if push:
            git(self.checkout, "push", "-q", "origin", "HEAD")
        return git(self.checkout, "rev-parse", "HEAD")

    def write_overlay(self, app, text):
        path = self.root / "gitops" / app / "kustomization.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def read_overlay(self, app):
        return (self.root / "gitops" / app / "kustomization.yaml").read_text()

    def overlays(self):
        return {app: self.read_overlay(app) for app in ("portal", "admin-portal", "incus-worker")}

    def run_build(self, lima, images=None):
        return run([str(self.checkout)], images or FRONTEND_IMAGES + [WORKER], lima, self.root)

    def head(self):
        return git(self.checkout, "rev-parse", "HEAD")

    def test_builds_every_image_of_the_repository_imports_them_and_writes_local_tags(self):
        lima = FakeLima()
        code, out, err = self.run_build(lima)
        self.assertEqual(code, 0, err)
        tag = "local-" + self.head()[:12]
        self.assertEqual(self.read_overlay("portal"), overlay(FRONTEND_IMAGES[0]["image"], tag))
        self.assertEqual(self.read_overlay("admin-portal"), overlay(FRONTEND_IMAGES[1]["image"], tag))
        self.assertEqual(self.read_overlay("incus-worker"), overlay(WORKER["image"], "4d5209a"))
        self.assertEqual(last_line(out), "BUILD_RESULT=WRITTEN")
        self.assertEqual(len(lima.builds()), 2)
        self.assertEqual(len(lima.imports()), 2)

    def test_context_and_dockerfile_come_from_the_workflow_at_that_commit(self):
        lima = FakeLima()
        code, _, err = self.run_build(lima)
        self.assertEqual(code, 0, err)
        portal, admin = lima.builds()
        self.assertIn("context=/var/tmp/build-local/frontend/src/portal ", portal + " ")
        self.assertIn("dockerfile=/var/tmp/build-local/frontend/src/portal ", portal + " ")
        self.assertIn("filename=Dockerfile ", portal + " ")
        self.assertIn("filename=Dockerfile.admin ", admin + " ")
        self.assertIn("platform=linux/arm64", admin)
        self.assertIn("name=ghcr.io/openvicloud/frontend-admin-portal:local-" + self.head()[:12], admin)
        self.assertIn("label:org.opencontainers.image.source=https://github.com/OpenViCloud/frontend", admin)

    def test_a_label_with_another_expression_is_an_error(self):
        self.write_checkout(".github/workflows/ci-portal.yml", workflow(FRONTEND_IMAGES[0]["image"], "portal").replace(
            "${{ github.repository }}", "${{ github.sha }}"))
        self.commit_and_push("label sha")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "labels", err)

    def test_a_commented_out_build_step_is_not_a_second_one(self):
        self.write_checkout(".github/workflows/ci-portal.yml", workflow(FRONTEND_IMAGES[0]["image"], "portal")
                            + "      # - uses: docker/build-push-action@v5\n")
        self.commit_and_push("comment")
        code, _, err = self.run_build(FakeLima())
        self.assertEqual(code, 0, err)

    def test_the_source_sent_is_the_committed_head(self):
        lima = FakeLima()
        self.run_build(lima)
        producers = [producer for producer, consumer in lima.pipes if producer[0] == "git"]
        self.assertEqual(len(producers), 1)
        self.assertIn("archive", producers[0])
        self.assertIn(self.head(), producers[0])

    def test_a_local_tag_never_has_the_shape_of_a_ci_tag(self):
        # Promotion takes a tag of exactly 7 or 40 hex characters: a local tag of that shape would reach staging.
        tag = build.local_tag("0123456789abcdef0123456789abcdef01234567")
        self.assertEqual(tag, "local-0123456789ab")
        self.assertIsNone(re.match(r"^[0-9a-f]{7}$", tag))
        self.assertIsNone(re.match(r"^[0-9a-f]{40}$", tag))

    def assert_error_and_nothing_done(self, lima, code, out, before, err_part, err):
        self.assertEqual(code, 2)
        self.assertEqual(last_line(out), "BUILD_RESULT=ERROR")
        self.assertEqual(self.overlays(), before)
        self.assertEqual(lima.builds(), [])
        self.assertEqual(lima.imports(), [])
        self.assertIn(err_part, err)

    def test_a_tracked_change_not_committed_is_an_error(self):
        # git archive sends the commit: an image built from it would not hold the change the tree shows.
        self.write_checkout("portal/Dockerfile", "FROM scratch\nRUN true\n")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "uncommitted", err)

    def test_an_untracked_file_is_not_a_change(self):
        self.write_checkout("notes.txt", "scratch\n")
        code, out, err = self.run_build(FakeLima())
        self.assertEqual(code, 0, err)
        self.assertEqual(last_line(out), "BUILD_RESULT=WRITTEN")

    def test_a_commit_only_on_a_branch_deleted_from_origin_is_an_error(self):
        # A stale remote-tracking ref would hide that nobody can find the commit any more.
        git(self.checkout, "switch", "-q", "-c", "gone")
        self.write_checkout("portal/Dockerfile", "FROM scratch\nRUN true\n")
        self.commit_and_push("on gone")
        git(self.checkout, "push", "-q", "origin", "--delete", "gone")
        git(self.checkout, "update-ref", "refs/remotes/origin/gone", "HEAD")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "origin", err)

    def test_a_commit_on_no_branch_of_origin_is_an_error(self):
        # Dev would run a commit nobody else can find.
        self.write_checkout("portal/Dockerfile", "FROM scratch\nRUN true\n")
        self.commit_and_push("local only", push=False)
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "origin", err)

    def test_a_repository_without_images_is_an_error(self):
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima, images=[WORKER])
        self.assert_error_and_nothing_done(lima, code, out, before, "OpenViCloud/frontend", err)

    def test_the_repository_is_read_from_origin(self):
        self.assertEqual(build.repository_of("https://github.com/OpenViCloud/frontend.git"), "OpenViCloud/frontend")
        self.assertEqual(build.repository_of("https://github.com/OpenViCloud/frontend"), "OpenViCloud/frontend")
        self.assertEqual(build.repository_of("git@github.com:OpenViCloud/incus-worker.git"), "OpenViCloud/incus-worker")
        self.assertIsNone(build.repository_of("/tmp/origin.git"))

    def test_a_build_argument_in_the_workflow_is_an_error(self):
        # A local build without it would differ from CI's image and nobody would see it.
        self.write_checkout(".github/workflows/ci-portal.yml",
                            workflow(FRONTEND_IMAGES[0]["image"], "portal").replace(
                                "          platforms:", "          build-args: |\n            A=1\n          platforms:"))
        self.commit_and_push("args")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "build-args", err)

    def test_a_workflow_tagging_another_image_is_an_error(self):
        self.write_checkout(".github/workflows/ci-portal.yml", workflow("ghcr.io/openvicloud/other", "portal"))
        self.commit_and_push("other image")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "ghcr.io/openvicloud/other", err)

    def test_a_workflow_without_a_build_step_is_an_error(self):
        self.write_checkout(".github/workflows/ci-portal.yml", "name: CI\non:\n  push:\n")
        self.commit_and_push("no build")
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, "ci-portal.yml", err)

    def test_an_overlay_that_does_not_end_with_the_image_is_an_error(self):
        self.write_overlay("portal", overlay("ghcr.io/openvicloud/titan-portal", "4d5209a"))
        before, lima = self.overlays(), FakeLima()
        code, out, err = self.run_build(lima)
        self.assert_error_and_nothing_done(lima, code, out, before, FRONTEND_IMAGES[0]["image"], err)

    def test_build_steps_outside_the_buildkit_slice_are_an_error(self):
        # Without defaultCgroupParent a build step runs outside the slice: its memory cap stops nothing (measured).
        for lima in (FakeLima(cgroup_parent=None), FakeLima(cgroup="0::/system.slice/buildkit.service")):
            before = self.overlays()
            code, out, err = self.run_build(lima)
            self.assert_error_and_nothing_done(lima, code, out, before, "buildkit.slice", err)

    def test_a_failed_build_writes_nothing_and_imports_nothing(self):
        before, lima = self.overlays(), FakeLima(fail="buildctl build")
        code, out, err = self.run_build(lima)
        self.assertEqual(code, 2)
        self.assertEqual(last_line(out), "BUILD_RESULT=ERROR")
        self.assertEqual(self.overlays(), before)
        self.assertEqual(lima.imports(), [])
        self.assertIn("boom", err)

    def test_a_failed_import_writes_nothing(self):
        before, lima = self.overlays(), FakeLima(fail="images import")
        code, out, _ = self.run_build(lima)
        self.assertEqual(code, 2)
        self.assertEqual(last_line(out), "BUILD_RESULT=ERROR")
        self.assertEqual(self.overlays(), before)

    def test_a_failed_send_builds_nothing(self):
        before, lima = self.overlays(), FakeLima(fail="tar -x")
        code, out, _ = self.run_build(lima)
        self.assertEqual(code, 2)
        self.assertEqual(self.overlays(), before)
        self.assertEqual(lima.builds(), [])

    def test_the_same_commit_again_is_no_change_and_imports_again(self):
        # containerd may hold that tag from an earlier build of other content (a changed recipe, a rebuilt titan-k3s
        # missing it): importing every time keeps the tag on what was just built.
        tag = "local-" + self.head()[:12]
        for image in FRONTEND_IMAGES:
            self.write_overlay(image["app"], overlay(image["image"], tag))
        before = self.overlays()
        lima = FakeLima()
        code, out, err = self.run_build(lima)
        self.assertEqual(code, 0, err)
        self.assertEqual(last_line(out), "BUILD_RESULT=NO_CHANGE")
        self.assertEqual(self.overlays(), before)
        self.assertEqual(len(lima.imports()), 2)


class SharedTableTests(unittest.TestCase):
    def test_build_local_reads_the_table_pull_images_writes(self):
        # One table: a row added for pulling is a row build-local builds.
        self.assertIs(build.IMAGES, build.pull.IMAGES)
        self.assertEqual(sorted(image["app"] for image in build.IMAGES),
                         ["admin-portal", "control-plane", "incus-worker", "portal", "site"])


class ProvisionTests(unittest.TestCase):
    """mac/provision/incus.sh installs the buildkit build-local needs; LB-0 measured each line below on titan-incus."""

    @classmethod
    def setUpClass(cls):
        cls.text = (ROOT / "mac" / "provision" / "incus.sh").read_text()

    def test_buildkit_is_pinned_by_version_and_sha256(self):
        for line in ("buildkit-v0.34.0.linux-arm64.tar.gz", "sha256sum -c",
                     "0619ca3e3205a32ea2beb115e0242136e4a0716cc1917ba0ceaa4ef4d52382c9"):
            self.assertTrue(line in self.text, line)

    def test_build_steps_run_in_a_capped_slice(self):
        # A cap on the unit alone left `dotnet` in /buildkit/<id>, uncapped.
        self.assertTrue(re.search(r'defaultCgroupParent = "buildkit\.slice"', self.text), r'defaultCgroupParent = "buildkit\.slice"')
        self.assertTrue(re.search(r"\nSlice=buildkit\.slice\n", self.text), r"\nSlice=buildkit\.slice\n")
        self.assertTrue(re.search(r"\nMemoryMax=\d+[MG]\n", self.text), r"\nMemoryMax=\d+[MG]\n")
        self.assertTrue("\nMemorySwapMax=0\n" in self.text, "MemorySwapMax=0")

    def test_buildkit_is_what_the_kernel_kills_first(self):
        # A full VM OOM killed the build step, not a guest's qemu, because of this score.
        self.assertTrue("\nOOMScoreAdjust=1000\n" in self.text, "OOMScoreAdjust=1000")

    def test_build_steps_use_the_host_network_and_cache_is_capped(self):
        self.assertTrue("--oci-worker-net=host" in self.text, "--oci-worker-net=host")
        self.assertTrue(re.search(r'maxUsedSpace = "10GB"', self.text), r'maxUsedSpace = "10GB"')

    def test_the_check_build_local_runs_is_installed(self):
        self.assertTrue("cat > /usr/local/sbin/buildkit-check" in self.text, "buildkit-check")
        self.assertTrue("MainPID" in self.text, "buildkit-check reads the running buildkitd's cgroup")


if __name__ == "__main__":
    unittest.main(verbosity=2)
