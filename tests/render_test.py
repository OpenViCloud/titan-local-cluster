#!/usr/bin/env python3
"""Renders dev's overlays and reads dev's ArgoCD Applications.

What must hold on dev: the control plane and the worker run only their own container (staging's Incus tunnel sidecar
is removed), the control plane lists zone local-mac only, and no Application or app directory is a fake service
(Titan's rule: doubles only in unit tests).

Run:  python3 tests/render_test.py     (needs kubectl for `kubectl kustomize`, ruby, and network: the overlays build on
      staging's overlays in OpenViCloud/titan)
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
