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

    def test_zone_list_is_local_mac_only(self):
        self.assertEqual(zones(render("control-plane")), {"Zones__0__Id": "local-mac", "Zones__0__Name": "Local Mac"})


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
