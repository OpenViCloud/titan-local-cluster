#!/usr/bin/env python3
"""Renders dev's overlays and reads dev's ArgoCD Applications.

What must hold on dev: the control plane and the worker run only their own container (staging's Incus tunnel sidecar
is removed), the control plane lists zone local-mac only, and no Application or app directory is a fake service
(Titan's rule: doubles only in unit tests).

Run:  python3 tests/render_test.py     (needs kubectl for `kubectl kustomize`, ruby, and git signed in to GitHub: the
      overlays build on staging's overlays in OpenViCloud/titan-ops, which is private)
"""
import json
import pathlib
import re
import subprocess
import unittest

GITOPS = pathlib.Path(__file__).resolve().parent.parent / "gitops"
FAKE = re.compile(r"stub|mock|fake", re.IGNORECASE)


def render(app):
    """Every object of `kubectl kustomize gitops/<app>`, as dicts (YAML read by ruby's stdlib: python's has none)."""
    out = subprocess.run(["kubectl", "kustomize", str(GITOPS / app)], capture_output=True, text=True, check=True).stdout
    as_json = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"],
        input=out, capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def containers(objects, deployment):
    for obj in objects:
        if obj["kind"] == "Deployment" and obj["metadata"]["name"] == deployment:
            return obj["spec"]["template"]["spec"]["containers"]
    raise AssertionError("no Deployment " + deployment)


def zones(objects):
    for obj in objects:
        if obj["kind"] == "ConfigMap" and obj["metadata"]["name"].startswith("control-plane-zones"):
            return obj["data"]
    raise AssertionError("no ConfigMap control-plane-zones")


def applications():
    found = []
    for manifest in sorted((GITOPS / "apps").glob("*.yaml")):
        text = manifest.read_text()
        if "kind: Application" not in text:
            continue
        name = re.search(r"^  name:\s*(\S+)", text, re.MULTILINE)
        paths = re.findall(r"^\s+path:\s*(\S+)", text, re.MULTILINE)
        found.append((manifest.name, name.group(1) if name else "", " ".join(paths)))
    return found


class DevRender(unittest.TestCase):
    def test_control_plane_has_only_its_own_container(self):
        names = [c["name"] for c in containers(render("control-plane"), "control-plane")]
        self.assertEqual(names, ["control-plane"])

    def test_incus_worker_has_only_its_own_container(self):
        names = [c["name"] for c in containers(render("incus-worker"), "incus-worker")]
        self.assertEqual(names, ["incus-worker"])

    def test_backup_target_is_the_dev_bucket_not_stagings(self):
        env = {e["name"]: e.get("value") for c in containers(render("control-plane"), "control-plane") for e in c["env"]}
        self.assertEqual(env["BackupTarget__Bucket"], "titan-backup-dev")
        self.assertEqual(env["BackupTarget__Region"], "auto")
        self.assertTrue(env["BackupTarget__Endpoint"].startswith("https://"))

    def test_the_backup_key_pair_comes_from_an_optional_secret(self):
        refs = [r["secretRef"] for c in containers(render("control-plane"), "control-plane") for r in c["envFrom"] if "secretRef" in r]
        self.assertIn({"name": "control-plane-backup-credentials", "optional": True}, refs)

    def test_zone_list_is_local_mac_only(self):
        self.assertEqual(zones(render("control-plane")), {"Zones__0__Id": "local-mac", "Zones__0__Name": "Local Mac"})


def first(objects, kind, name):
    for obj in objects:
        if obj["kind"] == kind and obj["metadata"]["name"] == name:
            return obj
    raise AssertionError("no %s %s" % (kind, name))


def control_plane_env():
    return {e["name"]: e.get("value") for c in containers(render("control-plane"), "control-plane") for e in c["env"]}


class DevBackup(unittest.TestCase):
    """Dev backs titan-db up through git, with titan-ops's backup component (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/oci/architecture.md#backup-bucket).
    CNPG writes the bucket the control plane reads: declared in two Applications, so held equal here."""

    def test_cnpg_writes_the_bucket_and_endpoint_the_control_plane_reads(self):
        configuration = first(render("titan-db"), "ObjectStore", "titan-db-backup")["spec"]["configuration"]
        bucket = re.fullmatch(r"s3://([^/]+)/postgres/", configuration["destinationPath"])
        self.assertIsNotNone(bucket, configuration["destinationPath"])
        env = control_plane_env()
        self.assertEqual(bucket.group(1), env["BackupTarget__Bucket"])
        self.assertEqual(configuration["endpointURL"], env["BackupTarget__Endpoint"])

    def test_the_cluster_archives_through_the_plugin_and_has_a_daily_base_backup(self):
        objects = render("titan-db")
        plugins = first(objects, "Cluster", "titan-db")["spec"]["plugins"]
        self.assertEqual([(p["name"], p["isWALArchiver"], p["parameters"]["barmanObjectName"]) for p in plugins],
                         [("barman-cloud.cloudnative-pg.io", True, "titan-db-backup")])
        scheduled = first(objects, "ScheduledBackup", "titan-db-daily")["spec"]
        self.assertEqual((scheduled["cluster"]["name"], scheduled["method"]), ("titan-db", "plugin"))

    def test_cert_manager_and_the_plugin_are_applications(self):
        found = {name: (file, path) for file, name, path in applications()}
        self.assertIn("cert-manager", found)
        self.assertIn("targetRevision: v1.18.2", (GITOPS / "apps" / found["cert-manager"][0]).read_text())
        self.assertEqual(found.get("plugin-barman-cloud", ("", ""))[1], "gitops/barman-cloud-plugin")


class DevRestore(unittest.TestCase):
    """Dev's titan-db came back from the bucket (restore drill, https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/oci/runbook.md#disaster-recovery):
    a Cluster created from this overlay recovers from the archive of the cluster before it and archives under another name, or barman
    refuses the non-empty archive."""

    def test_the_cluster_recovers_from_the_old_archive_and_archives_under_a_new_name(self):
        spec = first(render("titan-db"), "Cluster", "titan-db")["spec"]
        self.assertNotIn("initdb", spec["bootstrap"])
        self.assertEqual(spec["bootstrap"]["recovery"]["source"], "titan-db-source")
        read = {c["name"]: c["plugin"]["parameters"]["serverName"] for c in spec["externalClusters"]}
        written = spec["plugins"][0]["parameters"]["serverName"]
        self.assertEqual(read, {"titan-db-source": "titan-db"})
        self.assertEqual(written, "titan-db-restored")


def overlay_image(app):
    """The image an overlay sets: its single `images` entry's newName (else the entry name) and newTag."""
    text = (GITOPS / app / "kustomization.yaml").read_text().split("\nimages:\n", 1)[1]
    name = re.search(r"newName:\s*(\S+)", text) or re.search(r"-\s*name:\s*(\S+)", text)
    return name.group(1) + ":" + re.search(r'newTag:\s*"([^"]+)"', text).group(1)


class DevImages(unittest.TestCase):
    """An `images` entry matches the name staging's overlay gives the image. When titan-ops renames it and the entry here
    keeps the old name, the entry matches nothing and dev silently runs staging's tag."""

    APPS = ["control-plane", "incus-worker", "cloud-console", "admin-portal", "site"]

    def test_every_openvicloud_image_rendered_is_the_overlay_image(self):
        for app in self.APPS:
            wanted = overlay_image(app)
            rendered = set()
            for obj in render(app):
                spec = obj.get("spec", {})
                pod = spec.get("template", {}).get("spec") or spec.get("jobTemplate", {}).get("spec", {}).get(
                    "template", {}).get("spec") or {}
                for container in pod.get("containers", []) + pod.get("initContainers", []):
                    if container["image"].startswith("ghcr.io/openvicloud/"):
                        rendered.add(container["image"])
            self.assertEqual(rendered, {wanted}, app)


class TitanIsPinned(unittest.TestCase):
    """Dev runs one titan-ops commit: ArgoCD caches a render by the revision of this repository, so a change to a remote base
    on a moving branch is neither rendered nor applied without a hard refresh and a manual sync (measured on ArgoCD
    v2.11.2: the old base stayed for ten minutes and the app reported Synced)."""

    def references(self):
        found = []
        for path in sorted(list(GITOPS.parent.rglob("*.yaml")) + list(GITOPS.parent.rglob("*.yml"))):
            if ".git" in path.parts or ".github" in path.parts:
                continue
            text = path.read_text()
            found += [(path.name, ref) for ref in re.findall(r"OpenViCloud/titan-ops//\S+\?ref=(\S+)", text)]
            found += [(path.name, rev) for rev in re.findall(
                r"repoURL: https://github\.com/OpenViCloud/titan-ops\n\s+targetRevision: (\S+)", text)]
        return found

    def test_reads_both_kinds_of_reference(self):
        files = {file for file, _ in self.references()}
        self.assertIn("kustomization.yaml", files)
        self.assertIn("keycloak.yaml", files)

    def test_every_titan_mention_is_a_reference_read_here(self):
        mentions = 0
        for path in sorted(list(GITOPS.parent.rglob("*.yaml")) + list(GITOPS.parent.rglob("*.yml"))):
            if ".git" in path.parts or ".github" in path.parts:
                continue
            text = path.read_text()
            mentions += len(re.findall(r"OpenViCloud/titan-ops//", text))
            mentions += len(re.findall(r"""repoURL:\s*["']?https://github\.com/OpenViCloud/titan-ops(?:\.git)?["']?\s*$""", text, re.MULTILINE))
        self.assertEqual(mentions, len(self.references()))

    def test_every_titan_reference_is_one_full_commit(self):
        refs = {ref for _, ref in self.references()}
        self.assertEqual(len(refs), 1, sorted(self.references()))
        self.assertRegex(refs.pop(), r"^[0-9a-f]{40}$")


class NoFakeService(unittest.TestCase):
    def test_reads_the_applications(self):
        names = [name for _, name, _ in applications()]
        self.assertIn("root-local-mac", names)
        self.assertIn("control-plane-local-mac", names)

    def test_no_application_deploys_a_fake(self):
        offenders = [f"{file}: {name} {path}" for file, name, path in applications() if FAKE.search(name + " " + path)]
        self.assertEqual(offenders, [])

    def test_no_app_directory_is_a_fake(self):
        directories = [d.name for d in GITOPS.iterdir() if d.is_dir()]
        self.assertIn("control-plane", directories)
        self.assertEqual([d for d in directories if FAKE.search(d)], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
