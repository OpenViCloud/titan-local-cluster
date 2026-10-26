#!/usr/bin/env python3
"""Renders dev's overlays and reads dev's ArgoCD Applications.

What must hold on dev: the control plane and the worker run only their own container (the Incus tunnel sidecar is
staging's alone), the control plane lists zone local-mac only, and no Application or app directory is a fake service
(Titan's rule: doubles only in unit tests).

Run:  python3 tests/render_test.py     (needs kubectl for `kubectl kustomize` and ruby; the overlays build on base/ here,
      so nothing private is read)
"""
import json
import pathlib
import re
import subprocess
import unittest

GITOPS = pathlib.Path(__file__).resolve().parent.parent / "gitops"
MAC = GITOPS.parent / "mac"
# Dev's S3 (SeaweedFS): one name for pods and titan-incus alike, on Lima's user-v2 network, and the NodePort of gitops/seaweedfs.
S3_ENDPOINT = "https://lima-titan-k3s.internal:30833"
CA_FILE = "/etc/ssl/certs/titan-local-s3.crt"
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
        self.assertEqual(env["BackupTarget__Region"], "us-east-1")
        self.assertEqual(env["BackupTarget__Endpoint"], S3_ENDPOINT)

    def test_the_backup_key_pair_comes_from_an_optional_secret(self):
        refs = [r["secretRef"] for c in containers(render("control-plane"), "control-plane") for r in c["envFrom"] if "secretRef" in r]
        self.assertIn({"name": "control-plane-backup-credentials", "optional": True}, refs)

    def test_the_worker_hands_incus_the_bucket_and_endpoint_the_control_plane_reads(self):
        worker = {e["name"]: e.get("value") for c in containers(render("incus-worker"), "incus-worker") for e in c["env"]}
        plane = {e["name"]: e.get("value") for c in containers(render("control-plane"), "control-plane") for e in c["env"]}
        self.assertEqual(worker["BACKUP_S3_BUCKET"], "titan-backup-dev")
        self.assertEqual(worker["BACKUP_S3_BUCKET"], plane["BackupTarget__Bucket"])
        self.assertEqual(worker["BACKUP_S3_URL"], plane["BackupTarget__Endpoint"])

    # A patch of envFrom replaces the whole list: the worker must still read its internal token.
    def test_the_worker_still_reads_its_internal_token(self):
        refs = [r["secretRef"] for c in containers(render("incus-worker"), "incus-worker") for r in c.get("envFrom", []) if "secretRef" in r]
        self.assertIn({"name": "worker-secrets"}, refs)

    def test_the_workers_backup_key_pair_comes_from_an_optional_secret(self):
        refs = [r["secretRef"] for c in containers(render("incus-worker"), "incus-worker") for r in c.get("envFrom", []) if "secretRef" in r]
        self.assertIn({"name": "incus-worker-backup-credentials", "optional": True}, refs)

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
    """Dev backs titan-db up through git, with base's backup component (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/oci/architecture.md#backup-bucket).
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
        self.assertEqual(found.get("plugin-barman-cloud", ("", ""))[1], "base/barman-cloud-plugin")


class DevRestore(unittest.TestCase):
    """titan-k3s was rebuilt on a bucket that already held titan-db's archive, so the cluster restores from it and archives
    under a new name, or barman refuses the non-empty archive (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#runbook)."""

    def test_the_cluster_recovers_from_the_last_archive_and_archives_under_a_new_name(self):
        spec = first(render("titan-db"), "Cluster", "titan-db")["spec"]
        self.assertNotIn("initdb", spec["bootstrap"])
        self.assertEqual(spec["bootstrap"]["recovery"]["source"], "titan-db-source")
        read = {c["name"]: c["plugin"]["parameters"]["serverName"] for c in spec["externalClusters"]}
        self.assertEqual(read, {"titan-db-source": "titan-db"})
        self.assertEqual(spec["plugins"][0]["parameters"]["serverName"], "titan-db-restored")

    def test_the_restore_reads_the_same_object_store(self):
        # The same ObjectStore, so the same endpoint and CA (DevS3.test_cnpg_reaches_s3_at_the_shared_endpoint_and_trusts_the_ca).
        spec = first(render("titan-db"), "Cluster", "titan-db")["spec"]
        self.assertEqual([c["plugin"]["parameters"]["barmanObjectName"] for c in spec["externalClusters"]], ["titan-db-backup"])


def yaml_file(path):
    as_json = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load(STDIN.read))"],
                             input=path.read_text(), capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def mounts_of(objects, deployment, container):
    spec = first(objects, "Deployment", deployment)["spec"]["template"]["spec"]
    volumes = {v["name"]: v for v in spec.get("volumes", [])}
    found = [c for c in spec["containers"] if c["name"] == container][0]
    return [(m["mountPath"], m.get("subPath"), volumes[m["name"]]) for m in found.get("volumeMounts", [])]


class DevS3(unittest.TestCase):
    """SeaweedFS in titan-k3s over TLS, with its data on a folder of the Mac (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#s3)."""

    def test_cnpg_reaches_s3_at_the_shared_endpoint_and_trusts_the_ca(self):
        configuration = first(render("titan-db"), "ObjectStore", "titan-db-backup")["spec"]["configuration"]
        self.assertEqual(configuration["endpointURL"], S3_ENDPOINT)
        self.assertEqual(configuration["endpointCA"], {"name": "s3-ca", "key": "ca.crt"})

    def test_the_control_plane_and_the_worker_trust_the_ca_from_the_system_store(self):
        # One more file in /etc/ssl/certs, so the image's own CAs stay; .NET and Go are expected to read every file there.
        for app in ("control-plane", "incus-worker"):
            mounts = mounts_of(render(app), app, app)
            self.assertIn((CA_FILE, "ca.crt", {"name": "s3-ca", "secret": {"secretName": "s3-ca"}}), mounts, app)

    def test_no_dev_manifest_names_r2(self):
        for app in sorted(p.name for p in GITOPS.iterdir() if (p / "kustomization.yaml").exists()):
            text = subprocess.run(["kubectl", "kustomize", str(GITOPS / app)], capture_output=True, text=True, check=True).stdout
            self.assertNotIn("r2.cloudflarestorage", text, app)

    def test_seaweedfs_serves_s3_over_tls_with_the_bootstrap_secrets(self):
        objects = render("seaweedfs")
        container = containers(objects, "seaweedfs")[0]
        args = " ".join(container.get("command", []) + container.get("args", []))
        for flag in ("-s3", "-s3.cert.file=/etc/seaweedfs/tls/tls.crt", "-s3.key.file=/etc/seaweedfs/tls/tls.key",
                     "-s3.config=/etc/seaweedfs/s3/s3.json", "-dir=/data"):
            self.assertIn(flag, args.split())
        secrets = {v["secret"]["secretName"] for v in first(objects, "Deployment", "seaweedfs")["spec"]["template"]["spec"]["volumes"]
                   if "secret" in v}
        self.assertEqual(secrets, {"seaweedfs-tls", "seaweedfs-s3-config"})

    def test_seaweedfs_memory_is_bounded(self):
        # A VM backup (670 MB, multipart from Incus) got SeaweedFS OOM-killed at 512 MiB with no bound on the Go heap
        # or on uploads in flight; measured 2026-10-26 on dev.
        container = containers(render("seaweedfs"), "seaweedfs")[0]
        args = container.get("args", [])
        for flag in ("-s3.concurrentUploadLimitMB=64", "-filer.concurrentUploadLimitMB=64", "-volume.concurrentUploadLimitMB=64"):
            self.assertIn(flag, args)
        env = {e["name"]: e.get("value") for e in container.get("env", [])}
        self.assertEqual(env.get("GOMEMLIMIT"), "350MiB")
        self.assertEqual(container["resources"]["limits"]["memory"], "640Mi")

    def test_readiness_does_not_open_tls_connections_it_never_finishes(self):
        probe = containers(render("seaweedfs"), "seaweedfs")[0]["readinessProbe"]
        self.assertEqual(probe.get("httpGet", {}).get("port"), "master")

    def test_seaweedfs_data_is_the_folder_titan_k3s_mounts_from_the_mac(self):
        mounts = yaml_file(MAC / "titan-k3s.yaml")["mounts"]
        self.assertEqual(len(mounts), 1, mounts)
        self.assertEqual(mounts[0]["location"], "~/.local/share/titan-local-cluster/s3")
        self.assertTrue(mounts[0]["writable"])
        data = [v for _, _, v in mounts_of(render("seaweedfs"), "seaweedfs", "seaweedfs") if "hostPath" in v]
        # Directory, not DirectoryOrCreate: without the mount the pod must fail, not write into the VM's disk.
        self.assertEqual(data, [{"name": "data", "hostPath": {"path": mounts[0]["mountPoint"], "type": "Directory"}}])

    def test_the_nodeport_is_the_endpoints_port(self):
        service = first(render("seaweedfs"), "Service", "seaweedfs-s3")["spec"]
        self.assertEqual(service["type"], "NodePort")
        self.assertEqual([p["nodePort"] for p in service["ports"]], [int(S3_ENDPOINT.rsplit(":", 1)[1])])

    def test_the_bucket_job_makes_the_bucket_the_control_plane_reads(self):
        job = first(render("seaweedfs"), "Job", "seaweedfs-bucket")
        script = " ".join(job["spec"]["template"]["spec"]["containers"][0]["args"])
        self.assertIn("s3.bucket.create -name " + control_plane_env()["BackupTarget__Bucket"], script)
        self.assertEqual(job["metadata"]["annotations"]["argocd.argoproj.io/hook"], "PostSync")

    def test_seaweedfs_is_an_application_synced_before_the_database(self):
        found = {name: (file, path) for file, name, path in applications()}
        self.assertEqual(found.get("seaweedfs", ("", ""))[1], "gitops/seaweedfs")
        wave = lambda name: int(re.search(r'sync-wave:\s*"(-?\d+)"', (GITOPS / "apps" / found[name][0]).read_text()).group(1))
        self.assertLess(wave("seaweedfs"), wave("titan-db-local-mac"))


def overlay_image(app):
    """The image an overlay sets: its single `images` entry's newName (else the entry name) and newTag."""
    text = (GITOPS / app / "kustomization.yaml").read_text().split("\nimages:\n", 1)[1]
    name = re.search(r"newName:\s*(\S+)", text) or re.search(r"-\s*name:\s*(\S+)", text)
    return name.group(1) + ":" + re.search(r'newTag:\s*"([^"]+)"', text).group(1)


class DevImages(unittest.TestCase):
    """An `images` entry matches the name base/<app> gives the image. An entry with another name matches nothing, and
    dev silently runs the base's placeholder image."""

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


TITAN_REMOTE_BASE = re.compile(r"OpenViCloud/titan-ops(?:\.git)?//")
TITAN_SOURCE = re.compile(r"""repoURL:\s*["']?https://github\.com/OpenViCloud/titan-ops(?:\.git)?["']?\s*$""", re.MULTILINE)


def titan_reads(text):
    """How many times a manifest makes kustomize or ArgoCD read titan-ops: a remote base or an Application source."""
    return len(TITAN_REMOTE_BASE.findall(text)) + len(TITAN_SOURCE.findall(text))


class NoTitanRead(unittest.TestCase):
    """The local cluster builds without OpenViCloud/titan-ops, which is private: everything ArgoCD renders here comes
    from base/ and gitops/ of this repository (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#titan-integration).
    Links to titan-ops in comments stay; they are read by people, not by a render."""

    def test_the_check_sees_both_kinds_of_read(self):
        self.assertEqual(titan_reads("  - https://github.com/OpenViCloud/titan-ops//gitops/x/overlays/staging?ref=" + "1" * 40), 1)
        self.assertEqual(titan_reads("    - repoURL: https://github.com/OpenViCloud/titan-ops\n      targetRevision: main"), 1)
        self.assertEqual(titan_reads("    repoURL: 'https://github.com/OpenViCloud/titan-ops.git'"), 1)
        self.assertEqual(titan_reads("# https://github.com/OpenViCloud/titan-ops/blob/main/docs/x.md"), 0)

    def test_no_manifest_reads_titan_ops(self):
        manifests = [path for path in sorted(list(GITOPS.parent.rglob("*.yaml")) + list(GITOPS.parent.rglob("*.yml")))
                     if ".git" not in path.parts]
        self.assertGreater(len(manifests), 20)
        offenders = [str(path.relative_to(GITOPS.parent)) for path in manifests if titan_reads(path.read_text())]
        self.assertEqual(offenders, [])


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
