"""Tests for scripts/pull-images.py. Stdlib only: python3 tests/test_pull_images.py

The GitHub API goes through a fake runner; the repository is written to a temp dir. The last class reads this
repository's real overlays.
"""
import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import tempfile
import unittest
import unittest.mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("pull_images", ROOT / "scripts" / "pull-images.py")
pull = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pull)

SHA = "4410205e4c9b5d152537a26fe1bd1ff08c04b108"
SITE = {"repo": "OpenViCloud/example-web", "workflow": "ci-site.yml", "image": "ghcr.io/openvicloud/example-web-site",
        "app": "site", "tag_length": 7}
PORTAL = dict(SITE, workflow="ci-portal.yml", image="ghcr.io/openvicloud/example-web-portal", app="portal")


def overlay(app, name, new_name, tag):
    images = "images:\n  - name: " + name + "\n"
    if new_name is not None:
        images += "    newName: " + new_name + "\n"
    return "resources:\n  - ../../base/" + app + "\n" + images + '    newTag: "' + tag + '"\n'


def base_deployment(name):
    return "spec:\n  template:\n    spec:\n      containers:\n        - name: app\n          image: " + name + ":latest\n"


class FakeGitHub:
    """Answers workflow runs (head shas newest first, per workflow file). Any read of titan-ops fails the test: dev
    builds on this repository's base and moves no titan-ops commit."""

    def __init__(self, head_shas, fail=None, commit_runs=None, hang=None):
        self.head_shas = head_shas
        # Runs of one commit per workflow file, one state per query (the last one repeats): None is no run yet,
        # else (status, conclusion).
        self.commit_runs = commit_runs or {}
        # A call matching `hang` times out, as run_command's timeout makes a stuck gh call do.
        self.hang = hang
        self.fail = fail
        self.calls = []

    def __call__(self, cmd):
        self.calls.append(cmd)
        joined = " ".join(cmd)
        if "titan-ops" in joined:
            raise AssertionError("titan-ops read: " + joined)
        if self.hang is not None and self.hang in joined:
            raise subprocess.TimeoutExpired(cmd, pull.GH_TIMEOUT_SECONDS)
        if self.fail is not None and self.fail in joined:
            return subprocess.CompletedProcess(cmd, 1, "", "boom: " + self.fail)
        if "head_sha=" in joined:
            workflow = joined.split("/actions/workflows/")[1].split("/")[0]
            states = self.commit_runs[workflow]
            state = states.pop(0) if len(states) > 1 else states[0]
            runs = [] if state is None else [{"status": state[0], "conclusion": state[1],
                                              "html_url": "https://github.com/runs/" + workflow}]
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"workflow_runs": runs}), "")
        for workflow, head_sha in self.head_shas.items():
            if "/actions/workflows/" + workflow + "/runs" in joined:
                shas = [] if head_sha is None else head_sha if isinstance(head_sha, list) else [head_sha]
                return subprocess.CompletedProcess(cmd, 0, json.dumps({"workflow_runs": [
                    {"head_sha": sha} for sha in shas]}), "")
        raise AssertionError("unexpected command: " + joined)


class FakeClock:
    """Sleeping moves the clock; nothing really waits."""

    def __init__(self):
        self.now = 0
        self.sleeps = 0

    def sleep(self, seconds):
        self.now += seconds
        self.sleeps += 1

    def clock(self):
        return self.now


def run(images, runner, root, argv=(), clock=None):
    clock = clock or FakeClock()
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = pull.main(list(argv), images, runner, root, clock.sleep, clock.clock)
    return code, out.getvalue(), err.getvalue()


def last_line(out):
    return out.rstrip().splitlines()[-1]


class PullTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.dir.name)
        self.write("site", overlay("site", "site", SITE["image"], "f5bcd6c"))

    def tearDown(self):
        self.dir.cleanup()

    def write(self, app, text, base_name=None):
        path = self.root / "gitops" / app / "kustomization.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        base = self.root / "base" / app / "deployment.yaml"
        base.parent.mkdir(parents=True, exist_ok=True)
        base.write_text(base_deployment(base_name or app))

    def read(self, app):
        return (self.root / "gitops" / app / "kustomization.yaml").read_text()

    def test_writes_the_tag_of_the_newest_successful_push_run_on_main(self):
        runner = FakeGitHub({"ci-site.yml": SHA})
        code, out, _ = run([SITE], runner, self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"), overlay("site", "site", SITE["image"], "4410205"))
        self.assertIn("site: f5bcd6c -> 4410205", out)
        self.assertEqual(last_line(out), "PULL_RESULT=WRITTEN")
        query = " ".join(next(c for c in runner.calls if "/runs" in " ".join(c)))
        self.assertIn("repos/OpenViCloud/example-web/actions/workflows/ci-site.yml/runs", query)
        for condition in ("branch=main", "event=push", "status=success", "per_page=30"):
            self.assertIn(condition, query)

    def test_the_titan_flag_is_gone_and_a_pull_with_it_writes_nothing(self):
        # Dev pins no titan-ops commit: a flag naming one would ask for something dev cannot do.
        text = self.read("site")
        runner = FakeGitHub({"ci-site.yml": SHA})
        code, out, _ = run([SITE], runner, self.root, ["--titan", "2" * 40])
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(runner.calls, [])
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_an_entry_other_than_the_name_the_base_gives_is_an_error_and_writes_nothing(self):
        # The entry matches the image by the name base/<app> gives it; any other name matches nothing, and dev would
        # silently run the base's placeholder image.
        text = overlay("site", "ghcr.io/openvicloud/titan-site", SITE["image"], "f5bcd6c")
        self.write("site", text)
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertIn("base/site", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_base_without_a_deployment_image_is_an_error(self):
        (self.root / "base/site/deployment.yaml").write_text("kind: Deployment\n")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertIn("base/site", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_base_with_two_images_is_an_error(self):
        # Two image lines leave the entry's name ambiguous: the pull cannot tell which one the tag is for.
        (self.root / "base/site/deployment.yaml").write_text(base_deployment("site") + "          image: sidecar:latest\n")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertIn("base/site", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_images_of_one_repository_take_the_newest_commit_every_workflow_published(self):
        self.write("portal", overlay("portal", "portal", PORTAL["image"], "1111111"))
        newest, common, oldest = "c" * 40, "b" * 40, "a" * 40
        runner = FakeGitHub({"ci-site.yml": [newest, common, oldest], "ci-portal.yml": [common, oldest]})
        code, _, _ = run([SITE, PORTAL], runner, self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "bbbbbbb"', self.read("site"))
        self.assertIn('newTag: "bbbbbbb"', self.read("portal"))

    def test_no_commit_every_workflow_of_a_repository_published_is_an_error_and_writes_nothing(self):
        self.write("portal", overlay("portal", "portal", PORTAL["image"], "1111111"))
        before = (self.read("site"), self.read("portal"))
        code, out, err = run([SITE, PORTAL], FakeGitHub({"ci-site.yml": ["c" * 40], "ci-portal.yml": ["b" * 40]}),
                             self.root)
        self.assertEqual(code, 2)
        self.assertEqual((self.read("site"), self.read("portal")), before)
        self.assertIn("OpenViCloud/example-web", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_full_sha_tag_keeps_all_40_characters(self):
        code, _, _ = run([dict(SITE, tag_length=40)], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "' + SHA + '"', self.read("site"))

    def test_nothing_to_move_is_no_change(self):
        text = overlay("site", "site", SITE["image"], "4410205")
        self.write("site", text)
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=NO_CHANGE")

    def test_an_overlay_that_does_not_end_with_the_image_is_an_error_and_is_not_written(self):
        # Writing one repository's tag onto another repository's image would make dev pull a tag that image never had.
        text = overlay("site", "site", "ghcr.io/openvicloud/other-site", "f5bcd6c")
        self.write("site", text)
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertIn(SITE["image"], err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_no_successful_run_is_an_error(self):
        text = self.read("site")
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": None}), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_names_outside_the_images_block_are_not_image_entries(self):
        self.write("site", overlay("site", "site", SITE["image"], "f5bcd6c") + "configMapGenerator:\n  - name: cfg\n")
        code, _, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "4410205"', self.read("site"))
        self.assertIn("configMapGenerator:\n  - name: cfg\n", self.read("site"))

    def test_a_github_call_that_times_out_writes_nothing(self):
        text = self.read("site")
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}, hang="/runs"), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_failing_api_call_writes_nothing(self):
        text = self.read("site")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}, fail="/runs"), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertIn("boom", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")


class LocalTagTests(unittest.TestCase):
    """Dev runs only images CI published from main: a pull moves every tag, a local-<12 hex> one included, and
    takes no flag that would keep one."""

    LOCAL = "local-0123456789ab"

    write = PullTests.write
    read = PullTests.read

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.dir.name)
        self.write("site", overlay("site", "site", SITE["image"], self.LOCAL))
        self.write("portal", overlay("portal", "portal", PORTAL["image"], self.LOCAL))
        self.worker = dict(SITE, repo="OpenViCloud/titan-incus-worker", workflow="ci.yml",
                           image="ghcr.io/openvicloud/titan-incus-worker", app="incus-worker")
        self.write("incus-worker", overlay("incus-worker", "incus-worker", self.worker["image"], "f5bcd6c"))
        self.runner = FakeGitHub({"ci-site.yml": SHA, "ci-portal.yml": SHA, "ci.yml": SHA})

    def tearDown(self):
        self.dir.cleanup()

    def pull(self, *argv):
        return run([SITE, PORTAL, self.worker], self.runner, self.root, list(argv))

    def test_a_local_tag_moves_to_what_main_published(self):
        code, out, err = self.pull()
        self.assertEqual(code, 0, err)
        for app in ("site", "portal", "incus-worker"):
            self.assertIn('newTag: "4410205"', self.read(app), app)
        self.assertIn("site: " + self.LOCAL + " -> 4410205", out)
        self.assertEqual(last_line(out), "PULL_RESULT=WRITTEN")

    def test_the_flags_that_kept_a_local_tag_are_usage_errors_and_write_nothing(self):
        before = (self.read("site"), self.read("portal"), self.read("incus-worker"))
        for argv in (["--all"], ["--replace", "OpenViCloud/example-web"]):
            code, out, _ = self.pull(*argv)
            self.assertEqual(code, 2, argv)
            self.assertEqual(last_line(out), "PULL_RESULT=ERROR", argv)
            self.assertEqual((self.read("site"), self.read("portal"), self.read("incus-worker")), before, argv)


class WaitTests(unittest.TestCase):
    """--wait <repo>@<commit>: right after a merge, wait for that repository's push runs on main of the merge commit.
    It only waits: the pull runs separately once it says OK, since other sessions push main during the wait."""

    write = PullTests.write
    read = PullTests.read

    def setUp(self):
        PullTests.setUp(self)
        self.write("portal", overlay("portal", "portal", PORTAL["image"], "1111111"))
        self.worker = dict(SITE, repo="OpenViCloud/example-worker", workflow="ci.yml",
                           image="ghcr.io/openvicloud/example-worker", app="incus-worker")
        self.write("incus-worker", overlay("incus-worker", "incus-worker", self.worker["image"], "1111111"))
        self.clock = FakeClock()

    def tearDown(self):
        self.dir.cleanup()

    def files(self):
        return (self.read("site"), self.read("portal"), self.read("incus-worker"))

    def pull(self, commit_runs, wait="OpenViCloud/example-web@" + SHA, argv=(), hang=None, fail=None):
        runner = FakeGitHub({"ci-site.yml": SHA, "ci-portal.yml": SHA, "ci.yml": SHA}, commit_runs=commit_runs,
                            hang=hang, fail=fail)
        code, out, err = run([SITE, PORTAL, self.worker], runner, self.root, ["--wait", wait] + list(argv), self.clock)
        return code, out, err, runner

    def test_a_run_not_created_yet_then_running_is_waited_for_and_nothing_is_written(self):
        before = self.files()
        code, out, err, runner = self.pull({
            "ci-site.yml": [None, ("in_progress", None), ("completed", "success")],
            "ci-portal.yml": [("queued", None), ("completed", "success")]})
        self.assertEqual(code, 0, err)
        self.assertEqual(self.clock.sleeps, 2)
        self.assertEqual(self.files(), before)
        self.assertIn("  OpenViCloud/example-web ci-site.yml: success https://github.com/runs/ci-site.yml", out)
        self.assertIn("  OpenViCloud/example-web ci-portal.yml: success", out)
        self.assertEqual(last_line(out), "WAIT_RESULT=OK")
        queries = [" ".join(c) for c in runner.calls]
        # Only the named repository's runs of the commit are read: no other runs.
        # A finished workflow is not asked again.
        self.assertEqual(len(queries), 5)
        for query in queries:
            self.assertIn("repos/OpenViCloud/example-web/actions/workflows/", query)
            for condition in ("branch=main", "event=push", "head_sha=" + SHA):
                self.assertIn(condition, query)
            self.assertNotIn("status=", query)

    def test_a_failed_workflow_is_an_error_and_writes_nothing(self):
        before = self.files()
        code, out, err, _ = self.pull({"ci-site.yml": [("completed", "success")],
                                       "ci-portal.yml": [("in_progress", None), ("completed", "failure")]})
        self.assertEqual(code, 2)
        self.assertEqual(self.files(), before)
        self.assertIn("  OpenViCloud/example-web ci-portal.yml: failure", out)
        self.assertIn("ci-portal.yml concluded failure", err)
        self.assertEqual(last_line(out), "WAIT_RESULT=ERROR")

    def test_a_cancelled_run_is_an_error_too(self):
        code, out, err, _ = self.pull({"ci-site.yml": [("completed", "cancelled")],
                                       "ci-portal.yml": [("completed", "success")]})
        self.assertEqual(code, 2)
        self.assertIn("concluded cancelled", err)
        self.assertEqual(last_line(out), "WAIT_RESULT=ERROR")

    def test_a_run_unfinished_at_the_limit_is_an_error_and_writes_nothing(self):
        before = self.files()
        code, out, err, _ = self.pull({"ci-site.yml": [("completed", "success")],
                                       "ci-portal.yml": [None]})
        self.assertEqual(code, 2)
        self.assertEqual(self.files(), before)
        self.assertGreaterEqual(self.clock.now, pull.WAIT_LIMIT_SECONDS)
        self.assertIn("ci-portal.yml: no finished push run on main for " + SHA, err)
        self.assertNotIn("ci-site.yml,", err)
        self.assertEqual(last_line(out), "WAIT_RESULT=ERROR")

    def test_a_short_commit_or_a_repository_outside_images_is_a_usage_error_before_any_wait(self):
        before = self.files()
        for wait, message in (("OpenViCloud/example-web@4410205", "full 40-hex"),
                              ("OpenViCloud/example-web", "full 40-hex"),
                              ("OpenViCloud/other@" + SHA, "IMAGES has OpenViCloud/example-web")):
            code, out, err, runner = self.pull({}, wait=wait)
            self.assertEqual(code, 2, wait)
            self.assertIn(message, err, wait)
            self.assertEqual(runner.calls, [], wait)
            self.assertEqual(self.files(), before, wait)
            self.assertEqual(last_line(out), "WAIT_RESULT=ERROR", wait)

    def test_bad_arguments_of_a_wait_end_with_its_result_line(self):
        for argv in (["--wait"], ["--wait=OpenViCloud/example-web@" + SHA, "--all"], ["--wait", ""], ["--wait="]):
            code, out, _ = run([SITE, PORTAL], FakeGitHub({}), self.root, argv, self.clock)
            self.assertEqual(code, 2, argv)
            self.assertEqual(last_line(out), "WAIT_RESULT=ERROR", argv)

    def test_an_abbreviated_wait_is_not_a_wait(self):
        before = self.files()
        code, out, _ = run([SITE, PORTAL], FakeGitHub({}), self.root, ["--wai", "OpenViCloud/example-web@" + SHA],
                           self.clock)
        self.assertEqual(code, 2)
        self.assertEqual(self.files(), before)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_failing_or_missing_gh_is_an_error_with_its_result_line(self):
        code, out, err, _ = self.pull({"ci-site.yml": [None], "ci-portal.yml": [None]}, fail="head_sha=")
        self.assertEqual(code, 2)
        self.assertIn("boom", err)
        self.assertEqual(last_line(out), "WAIT_RESULT=ERROR")

        def no_gh(cmd):
            raise FileNotFoundError(2, "No such file or directory", "gh")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pull.main(["--wait", "OpenViCloud/example-web@" + SHA], [SITE, PORTAL], no_gh, self.root,
                             self.clock.sleep, self.clock.clock)
        self.assertEqual(code, 2)
        self.assertEqual(last_line(out.getvalue()), "WAIT_RESULT=ERROR")

    def test_wait_with_titan_is_a_usage_error(self):
        for titan in ("2" * 40, ""):
            code, out, err, runner = self.pull({}, argv=["--titan", titan])
            self.assertEqual(code, 2, titan)
            self.assertIn("bad arguments", err, titan)
            self.assertEqual(runner.calls, [], titan)
            self.assertEqual(last_line(out), "WAIT_RESULT=ERROR", titan)

    def test_a_github_call_that_times_out_is_an_error(self):
        # A stuck gh call would otherwise outlast the limit and the Monitor running --wait, with no result line.
        code, out, err, _ = self.pull({"ci-site.yml": [None], "ci-portal.yml": [None]}, hang="head_sha=")
        self.assertEqual(code, 2)
        self.assertIn("timed out", err)
        self.assertEqual(last_line(out), "WAIT_RESULT=ERROR")


class RunCommandTests(unittest.TestCase):
    def test_every_gh_call_has_a_timeout(self):
        # The fakes above raise TimeoutExpired themselves; this pins that the real runner asks subprocess for it.
        with unittest.mock.patch.object(pull.subprocess, "run") as run_mock:
            pull.run_command(["gh", "api", "x"])
        self.assertEqual(run_mock.call_args.kwargs["timeout"], pull.GH_TIMEOUT_SECONDS)
        self.assertEqual(pull.GH_TIMEOUT_SECONDS, 60)

    def test_the_wait_fits_the_monitor_running_it(self):
        # titan's iteration:deploy gives the Monitor 25 minutes and names these numbers.
        self.assertEqual(pull.WAIT_LIMIT_SECONDS, 20 * 60)
        self.assertEqual(pull.WAIT_POLL_SECONDS, 30)
        workflows = max(len({i["workflow"] for i in pull.IMAGES if i["repo"] == repo}) for repo in
                        {i["repo"] for i in pull.IMAGES})
        worst = pull.WAIT_LIMIT_SECONDS + pull.WAIT_POLL_SECONDS + workflows * pull.GH_TIMEOUT_SECONDS
        self.assertLess(worst, 25 * 60)


class RepoTests(unittest.TestCase):
    """This repository's real overlays: the shape pulling relies on."""

    def test_every_pulled_overlay_ends_with_its_image(self):
        self.assertEqual(sorted(image["app"] for image in pull.IMAGES),
                         ["admin-portal", "cloud-console", "control-plane", "incus-worker", "site"])
        for image in pull.IMAGES:
            path = "gitops/" + image["app"] + "/kustomization.yaml"
            self.assertEqual(pull.image_in((ROOT / path).read_text(), path), image["image"], path)

    def test_every_pulled_overlay_entry_is_the_name_its_base_gives_the_image(self):
        for image in pull.IMAGES:
            path = "gitops/" + image["app"] + "/kustomization.yaml"
            entry = pull.ENTRY_NAME.findall(pull.images_block((ROOT / path).read_text()))[0][1]
            self.assertEqual(entry, pull.base_image_name(ROOT, image["app"]), path)

    def test_every_pulled_overlay_has_a_tag_of_its_row_length(self):
        # A wrong tag_length writes a tag the other repository never published: dev pulls an image that does not exist.
        for image in pull.IMAGES:
            tags = pull.TAG.findall((ROOT / "gitops" / image["app"] / "kustomization.yaml").read_text())
            self.assertEqual(len(tags), 1, image["app"])
            self.assertEqual(len(tags[0][1]), image["tag_length"], image["app"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
