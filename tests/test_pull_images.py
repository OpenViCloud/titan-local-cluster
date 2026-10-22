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

OLD_TITAN = "1" * 40
NEW_TITAN = "2" * 40
SHA = "4410205e4c9b5d152537a26fe1bd1ff08c04b108"
SITE = {"repo": "OpenViCloud/example-web", "workflow": "ci-site.yml", "image": "ghcr.io/openvicloud/example-web-site",
        "app": "site", "tag_length": 7}
PORTAL = dict(SITE, workflow="ci-portal.yml", image="ghcr.io/openvicloud/example-web-portal", app="portal")


def overlay(app, name, new_name, tag, titan=OLD_TITAN):
    images = "images:\n  - name: " + name + "\n"
    if new_name is not None:
        images += "    newName: " + new_name + "\n"
    return ("resources:\n  - https://github.com/OpenViCloud/titan-ops//gitops/" + app + "/overlays/staging?ref=" + titan
            + "\n" + images + '    newTag: "' + tag + '"\n')


def staging(app, new_name):
    return "images:\n  - name: " + app + "\n    newName: " + new_name + '\n    newTag: "0eed82d"\n'


APP_WITH_VALUES = ("  sources:\n    - repoURL: https://github.com/OpenViCloud/titan-ops\n      targetRevision: " + OLD_TITAN
                   + "\n      ref: values\n")


class FakeGitHub:
    """Answers workflow runs (head shas newest first, per workflow file), titan-ops's main, and titan-ops files at a commit."""

    def __init__(self, head_shas, titan_main=NEW_TITAN, staging_names=None, fail=None, on_main=True, commit_runs=None,
                 hang=None):
        self.head_shas = head_shas
        # Runs of one commit per workflow file, one state per query (the last one repeats): None is no run yet,
        # else (status, conclusion).
        self.commit_runs = commit_runs or {}
        # A call matching `hang` times out, as run_command's timeout makes a stuck gh call do.
        self.hang = hang
        self.titan_main = titan_main
        # Name staging's overlay gives each app's image at NEW_TITAN.
        self.staging_names = staging_names or {}
        self.fail = fail
        self.on_main = on_main
        self.calls = []

    def __call__(self, cmd):
        self.calls.append(cmd)
        joined = " ".join(cmd)
        if self.hang is not None and self.hang in joined:
            raise subprocess.TimeoutExpired(cmd, pull.GH_TIMEOUT_SECONDS)
        if self.fail is not None and self.fail in joined:
            return subprocess.CompletedProcess(cmd, 1, "", "boom: " + self.fail)
        if "repos/OpenViCloud/titan-ops/compare/" in joined:
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"status": "ahead" if self.on_main else "diverged"}), "")
        if "repos/OpenViCloud/titan-ops/commits/main" in joined:
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"sha": self.titan_main}), "")
        if "repos/OpenViCloud/titan-ops/contents/gitops/" in joined:
            app = joined.split("contents/gitops/")[1].split("/")[0]
            assert ("ref=" + NEW_TITAN) in joined, joined
            name = self.staging_names.get(app, "ghcr.io/openvicloud/titan-" + app)
            return subprocess.CompletedProcess(cmd, 0, staging(app, name), "")
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
        self.write("site", overlay("site", "ghcr.io/openvicloud/titan-site", SITE["image"], "f5bcd6c"))
        self.apps = self.root / "gitops/apps"
        self.apps.mkdir(parents=True)
        (self.apps / "keycloak.yaml").write_text(APP_WITH_VALUES)

    def tearDown(self):
        self.dir.cleanup()

    def write(self, app, text):
        path = self.root / "gitops" / app / "kustomization.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def read(self, app):
        return (self.root / "gitops" / app / "kustomization.yaml").read_text()

    def test_writes_the_tag_of_the_newest_successful_push_run_on_main_and_moves_titan_to_its_main(self):
        runner = FakeGitHub({"ci-site.yml": SHA})
        code, out, _ = run([SITE], runner, self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"),
                         overlay("site", "ghcr.io/openvicloud/titan-site", SITE["image"], "4410205", titan=NEW_TITAN))
        self.assertEqual((self.apps / "keycloak.yaml").read_text(), APP_WITH_VALUES.replace(OLD_TITAN, NEW_TITAN))
        self.assertIn("site: f5bcd6c -> 4410205", out)
        self.assertIn("titan: " + OLD_TITAN + " -> " + NEW_TITAN, out)
        self.assertEqual(last_line(out), "PULL_RESULT=WRITTEN")
        query = " ".join(next(c for c in runner.calls if "/runs" in " ".join(c)))
        self.assertIn("repos/OpenViCloud/example-web/actions/workflows/ci-site.yml/runs", query)
        for condition in ("branch=main", "event=push", "status=success", "per_page=30"):
            self.assertIn(condition, query)

    def test_a_given_titan_commit_is_used_instead_of_main(self):
        runner = FakeGitHub({"ci-site.yml": SHA}, titan_main="9" * 40)
        code, _, _ = run([SITE], runner, self.root, ["--titan", NEW_TITAN])
        self.assertEqual(code, 0)
        self.assertIn("ref=" + NEW_TITAN, self.read("site"))
        self.assertFalse(any("commits/main" in " ".join(c) for c in runner.calls))

    def test_a_given_titan_commit_off_main_is_an_error_and_writes_nothing(self):
        # Dev runs only what titan-ops merged: a commit of a branch would test manifests staging never gets.
        text = self.read("site")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}, on_main=False), self.root, ["--titan", NEW_TITAN])
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertIn("not on titan's main", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_titan_reference_in_a_yml_file_is_moved_too(self):
        (self.apps / "nats.yml").write_text(APP_WITH_VALUES)
        code, _, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 0)
        self.assertEqual((self.apps / "nats.yml").read_text(), APP_WITH_VALUES.replace(OLD_TITAN, NEW_TITAN))

    def test_a_short_titan_commit_is_a_usage_error(self):
        text = self.read("site")
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root, ["--titan", "2222222"])
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_the_entry_takes_the_name_staging_gives_at_the_new_titan_commit(self):
        # Staging was promoted to the new name: an entry keeping the old name would match nothing, and dev would
        # silently run staging's tag. The entry is the image itself now, so no newName is left.
        runner = FakeGitHub({"ci-site.yml": SHA}, staging_names={"site": SITE["image"]})
        code, out, _ = run([SITE], runner, self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"), overlay("site", SITE["image"], None, "4410205", titan=NEW_TITAN))
        self.assertIn("site entry: ghcr.io/openvicloud/titan-site -> " + SITE["image"], out)

    def test_an_entry_without_new_name_gets_one_when_staging_names_another_image(self):
        self.write("site", overlay("site", SITE["image"], None, "f5bcd6c"))
        runner = FakeGitHub({"ci-site.yml": SHA}, staging_names={"site": "ghcr.io/openvicloud/other-site"})
        code, _, _ = run([SITE], runner, self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"), overlay("site", "ghcr.io/openvicloud/other-site", SITE["image"], "4410205",
                                                    titan=NEW_TITAN))

    def test_images_of_one_repository_take_the_newest_commit_every_workflow_published(self):
        self.write("portal", overlay("portal", "ghcr.io/openvicloud/titan-portal", PORTAL["image"], "1111111"))
        newest, common, oldest = "c" * 40, "b" * 40, "a" * 40
        runner = FakeGitHub({"ci-site.yml": [newest, common, oldest], "ci-portal.yml": [common, oldest]})
        code, _, _ = run([SITE, PORTAL], runner, self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "bbbbbbb"', self.read("site"))
        self.assertIn('newTag: "bbbbbbb"', self.read("portal"))

    def test_no_commit_every_workflow_of_a_repository_published_is_an_error_and_writes_nothing(self):
        self.write("portal", overlay("portal", "ghcr.io/openvicloud/titan-portal", PORTAL["image"], "1111111"))
        before = (self.read("site"), self.read("portal"), (self.apps / "keycloak.yaml").read_text())
        code, out, err = run([SITE, PORTAL], FakeGitHub({"ci-site.yml": ["c" * 40], "ci-portal.yml": ["b" * 40]}),
                             self.root)
        self.assertEqual(code, 2)
        self.assertEqual((self.read("site"), self.read("portal"), (self.apps / "keycloak.yaml").read_text()), before)
        self.assertIn("OpenViCloud/example-web", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_titan_references_on_two_commits_are_an_error_and_write_nothing(self):
        (self.apps / "nats.yaml").write_text(APP_WITH_VALUES.replace(OLD_TITAN, "3" * 40))
        before = self.read("site")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), before)
        self.assertIn("titan", err)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_titan_reference_on_a_branch_is_an_error(self):
        self.write("site", self.read("site").replace("ref=" + OLD_TITAN, "ref=main"))
        (self.apps / "keycloak.yaml").write_text(APP_WITH_VALUES.replace(OLD_TITAN, "main"))
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_full_sha_tag_keeps_all_40_characters(self):
        self.write("site", overlay("site", SITE["image"], None, "f5bcd6c"))
        runner = FakeGitHub({"ci-site.yml": SHA}, staging_names={"site": SITE["image"]})
        code, _, _ = run([dict(SITE, tag_length=40)], runner, self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "' + SHA + '"', self.read("site"))

    def test_nothing_to_move_is_no_change(self):
        text = overlay("site", "ghcr.io/openvicloud/titan-site", SITE["image"], "4410205", titan=NEW_TITAN)
        self.write("site", text)
        (self.apps / "keycloak.yaml").write_text(APP_WITH_VALUES.replace(OLD_TITAN, NEW_TITAN))
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}), self.root)
        self.assertEqual(code, 0)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=NO_CHANGE")

    def test_an_overlay_that_does_not_end_with_the_image_is_an_error_and_is_not_written(self):
        # Writing one repository's tag onto another repository's image would make dev pull a tag that image never had.
        text = overlay("site", "ghcr.io/openvicloud/titan-site", None, "f5bcd6c")
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
        self.write("site", overlay("site", SITE["image"], None, "f5bcd6c") + "configMapGenerator:\n  - name: cfg\n")
        runner = FakeGitHub({"ci-site.yml": SHA}, staging_names={"site": SITE["image"]})
        code, _, _ = run([SITE], runner, self.root)
        self.assertEqual(code, 0)
        self.assertIn('newTag: "4410205"', self.read("site"))
        self.assertIn("configMapGenerator:\n  - name: cfg\n", self.read("site"))

    def test_a_github_call_that_times_out_writes_nothing(self):
        text = self.read("site")
        code, out, _ = run([SITE], FakeGitHub({"ci-site.yml": SHA}, hang="contents/gitops"), self.root)
        self.assertEqual(code, 2)
        self.assertEqual(self.read("site"), text)
        self.assertEqual(last_line(out), "PULL_RESULT=ERROR")

    def test_a_failing_api_call_writes_nothing(self):
        text = self.read("site")
        code, out, err = run([SITE], FakeGitHub({"ci-site.yml": SHA}, fail="contents/gitops"), self.root)
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
        (self.root / "gitops/apps").mkdir(parents=True)
        (self.root / "gitops/apps/keycloak.yaml").write_text(APP_WITH_VALUES)
        self.write("site", overlay("site", SITE["image"], None, self.LOCAL))
        self.write("portal", overlay("portal", PORTAL["image"], None, self.LOCAL))
        self.worker = dict(SITE, repo="OpenViCloud/titan-incus-worker", workflow="ci.yml",
                           image="ghcr.io/openvicloud/titan-incus-worker", app="incus-worker")
        self.write("incus-worker", overlay("incus-worker", self.worker["image"], None, "f5bcd6c"))
        self.runner = FakeGitHub({"ci-site.yml": SHA, "ci-portal.yml": SHA, "ci.yml": SHA},
                                 staging_names={"site": SITE["image"], "portal": PORTAL["image"],
                                                "incus-worker": self.worker["image"]})

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
        self.write("portal", overlay("portal", PORTAL["image"], None, "1111111"))
        self.worker = dict(SITE, repo="OpenViCloud/example-worker", workflow="ci.yml",
                           image="ghcr.io/openvicloud/example-worker", app="incus-worker")
        self.write("incus-worker", overlay("incus-worker", self.worker["image"], None, "1111111"))
        self.names = {"site": SITE["image"], "portal": PORTAL["image"], "incus-worker": self.worker["image"]}
        self.clock = FakeClock()

    def tearDown(self):
        self.dir.cleanup()

    def files(self):
        return (self.read("site"), self.read("portal"), self.read("incus-worker"),
                (self.apps / "keycloak.yaml").read_text())

    def pull(self, commit_runs, wait="OpenViCloud/example-web@" + SHA, argv=(), hang=None, fail=None):
        runner = FakeGitHub({"ci-site.yml": SHA, "ci-portal.yml": SHA, "ci.yml": SHA}, staging_names=self.names,
                            commit_runs=commit_runs, hang=hang, fail=fail)
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
        # Only the named repository's runs of the commit are read: no titan, no other runs, no staging overlay.
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
        for titan in (NEW_TITAN, ""):
            code, out, err, runner = self.pull({}, argv=["--titan", titan])
            self.assertEqual(code, 2, titan)
            self.assertIn("--wait takes no other flag", err, titan)
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

    def test_every_pulled_overlay_has_a_tag_of_its_row_length(self):
        # A wrong tag_length writes a tag the other repository never published: dev pulls an image that does not exist.
        for image in pull.IMAGES:
            tags = pull.TAG.findall((ROOT / "gitops" / image["app"] / "kustomization.yaml").read_text())
            self.assertEqual(len(tags), 1, image["app"])
            self.assertEqual(len(tags[0][1]), image["tag_length"], image["app"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
