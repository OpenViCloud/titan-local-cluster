#!/usr/bin/env python3
"""Renders dev's overlays (and tests/restore, base's restore path that no Application uses) and reads dev's ArgoCD
Applications.

What must hold on dev: the control plane and the worker run only their own container (the Incus tunnel sidecar is
staging's alone), the control plane lists cluster local only, and no Application or app directory is a fake service
(Titan's rule: doubles only in unit tests).

Run:  python3 tests/render_test.py     (needs kubectl for `kubectl kustomize` and ruby; the overlays build on base/ here,
      so nothing private is read)
"""
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
GITOPS = REPO / "gitops"
BASE = REPO / "base"
TESTS = pathlib.Path(__file__).resolve().parent
LIMA = GITOPS.parent / "lima"
# Dev's S3 (SeaweedFS): one name for pods and titan-incus alike (macOS: Lima's user-v2 network; Ubuntu: Lima's host
# resolver, tests/test_lima_files.py), and the NodePort of gitops/seaweedfs.
S3_ENDPOINT = "https://lima-titan-k3s.internal:30833"
CA_FILE = "/etc/ssl/certs/titan-local-s3.crt"
FAKE = re.compile(r"stub|mock|fake", re.IGNORECASE)


def render(app, root=GITOPS):
    """Every object of `kubectl kustomize <root>/<app>`, as dicts (YAML read by ruby's stdlib: python's has none)."""
    out = subprocess.run(["kubectl", "kustomize", str(root / app)], capture_output=True, text=True, check=True).stdout
    as_json = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"],
        input=out, capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def containers(objects, deployment):
    for obj in objects:
        if obj["kind"] == "Deployment" and obj["metadata"]["name"] == deployment:
            return obj["spec"]["template"]["spec"]["containers"]
    raise AssertionError("no Deployment " + deployment)


def cluster_list(objects):
    for obj in objects:
        if obj["kind"] == "ConfigMap" and obj["metadata"]["name"].startswith("control-plane-clusters"):
            return obj["data"]
    raise AssertionError("no ConfigMap control-plane-clusters")


def portal_config(objects):
    for obj in objects:
        if obj["kind"] == "ConfigMap" and obj["metadata"]["name"].startswith("cloud-console-config"):
            return json.loads(obj["data"]["config.json"])
    raise AssertionError("no ConfigMap cloud-console-config")


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

    def test_the_customer_portal_offers_buying_credit_on_dev(self):
        # The portal shows Buy credit and receipts only when config.json holds the boolean true; without it the
        # regression cases that read them in the portal fail on dev
        # (https://github.com/OpenViCloud/titan-ops/blob/main/docs/features/billing/topup/design.md#topup-portal).
        self.assertIs(portal_config(render("cloud-console")).get("topUpEnabled"), True)

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

    # The fingerprint is not in git: it changes with titan-incus and comes from Secret control-plane-cluster. The endpoint in
    # git is macOS's; lima/scripts/join-cluster.sh writes this host's into the same Secret, which overrides it (next test).
    def test_the_cluster_list_is_local_on_titan_incus(self):
        listed = cluster_list(render("control-plane"))
        self.assertEqual({k: v for k, v in listed.items() if k.startswith("Clusters__")}, {
            "Clusters__0__Id": "local",
            "Clusters__0__Name": "Local",
            "Clusters__0__Endpoint": "https://192.168.104.1:8443",
            "Clusters__0__OvnUplinkNetwork": "ovnup",
            "Clusters__0__StoragePool": "default",
            "Clusters__0__Ipv6Block": "2001:db8:0:d400::/56",
        })

    # Without the block, a network that asks for public IPv6 (and so every load balancer) answers 422 IPV6_NOT_AVAILABLE.
    # The block is the one lima/provision/incus.sh routes on ovnup: the control plane hands out /64s that titan-incus routes.
    def test_the_clusters_ipv6_block_is_the_one_titan_incus_routes(self):
        prefix = re.search(r"^IPV6_BLOCK_PREFIX=(\S+)$", (LIMA / "provision/incus.sh").read_text(), re.M).group(1)
        self.assertEqual(cluster_list(render("control-plane"))["Clusters__0__Ipv6Block"], prefix + "00::/56")

    # A key in two envFrom sources takes the value of the later one: Secret control-plane-cluster must come after the
    # ConfigMap, or Ubuntu's endpoint loses to macOS's.
    def test_the_cluster_secret_overrides_the_cluster_list(self):
        sources = [r.get("secretRef", r.get("configMapRef"))["name"] for c in containers(render("control-plane"), "control-plane")
                   for r in c.get("envFrom", [])]
        clusters_cm = [n for n in sources if n.startswith("control-plane-clusters")]
        self.assertEqual(len(clusters_cm), 1, sources)
        self.assertGreater(sources.index("control-plane-cluster"), sources.index(clusters_cm[0]), sources)

    def test_the_cluster_secret_is_optional_so_the_pod_starts_before_it(self):
        refs = [r["secretRef"] for c in containers(render("control-plane"), "control-plane") for r in c.get("envFrom", []) if "secretRef" in r]
        self.assertIn({"name": "control-plane-cluster", "optional": True}, refs)


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

    def test_the_plugin_manifest_is_the_release_bytes(self):
        # The release's own sha256: an edit by hand, or a fetch of another version under this name, turns this red.
        manifest = GITOPS.parent / "base" / "barman-cloud-plugin" / "manifest-v0.15.1.yaml"
        self.assertEqual(hashlib.sha256(manifest.read_bytes()).hexdigest(),
                         "8f377ff4a7d0d3f74fc64b0f7ac4f449fc38ca9e83a40107cca2f9315a9bd920")


class DevStartsEmpty(unittest.TestCase):
    """Anyone's first up.sh has an empty bucket, so main creates an empty database: a restore there finds no backup and
    the database never starts. It archives under the name the maintainers' dev cluster writes since its move to titan-db-dev,
    or barman refuses that non-empty archive (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#runbook)."""

    def test_a_new_cluster_starts_empty_and_restores_nothing(self):
        spec = first(render("titan-db"), "Cluster", "titan-db")["spec"]
        self.assertEqual(list(spec["bootstrap"]), ["initdb"])
        self.assertNotIn("externalClusters", spec)

    def test_it_archives_under_the_name_dev_writes(self):
        spec = first(render("titan-db"), "Cluster", "titan-db")["spec"]
        self.assertEqual(spec["plugins"][0]["parameters"],
                         {"barmanObjectName": "titan-db-backup", "serverName": "titan-db-dev"})


def yaml_text(text):
    as_json = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load(STDIN.read))"],
                             input=text, capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def yaml_file(path):
    return yaml_text(path.read_text())


def mounts_of(objects, deployment, container):
    spec = first(objects, "Deployment", deployment)["spec"]["template"]["spec"]
    volumes = {v["name"]: v for v in spec.get("volumes", [])}
    found = [c for c in spec["containers"] if c["name"] == container][0]
    return [(m["mountPath"], m.get("subPath"), volumes[m["name"]]) for m in found.get("volumeMounts", [])]


class DevS3(unittest.TestCase):
    """SeaweedFS in titan-k3s over TLS, with its data on a folder of the host machine (https://github.com/OpenViCloud/titan-ops/blob/main/docs/infra/environments/local-cluster/topology.md#s3)."""

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
        mounts = yaml_file(LIMA / "macos" / "titan-k3s.yaml")["mounts"]
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
        self.assertLess(wave("seaweedfs"), wave("titan-db-local"))


class DevDatabases(unittest.TestCase):
    """titan-db's databases: Keycloak's is a Database object, not initdb's postInitSQL (a restored cluster runs no initdb),
    and only their owner creates in schema public."""

    def test_keycloak_database_is_declared_on_titan_db_and_never_dropped(self):
        objects = render("titan-db")
        spec = first(objects, "Database", "keycloak")["spec"]
        self.assertEqual((spec["name"], spec["owner"], spec["cluster"]["name"]), ("keycloak", "titan", "titan-db"))
        self.assertEqual((spec["ensure"], spec["databaseReclaimPolicy"]), ("present", "retain"))
        self.assertNotIn("postInitSQL", first(objects, "Cluster", "titan-db")["spec"]["bootstrap"].get("initdb", {}))

    def test_only_the_owner_creates_objects_in_public(self):
        # PostgreSQL 15 lets only the database owner (titan) and superusers create in schema public; a grant TO PUBLIC, in
        # any of initdb's SQL lists, would let every role that can connect in.
        initdb = first(render("titan-db", root=BASE), "Cluster", "titan-db")["spec"]["bootstrap"]["initdb"]
        lists = ("postInitSQL", "postInitTemplateSQL", "postInitApplicationSQL")
        # SQL from a ConfigMap or Secret (the *Refs lists) is not in the render, so none may hide a grant there.
        self.assertEqual([key + "Refs" for key in lists if key + "Refs" in initdb], [])
        sql = [s for key in lists for s in initdb.get(key, [])]
        self.assertEqual([s for s in sql if re.search(r"\bGRANT\b[^;]*\bTO\b[^;]*\bPUBLIC\b", s, re.IGNORECASE)], [])


class RestorePath(unittest.TestCase):
    """base's restore component, as an environment being rebuilt adds it (no dev overlay does: dev starts empty). The
    cluster reads the archive the last cluster wrote and writes under another name: barman refuses a non-empty archive,
    and a cluster that read and wrote one name would restore from a stale archive or stop archiving."""

    def test_a_restore_reads_one_name_and_writes_another_in_the_same_object_store(self):
        spec = first(render("restore", TESTS), "Cluster", "titan-db")["spec"]
        self.assertEqual(list(spec["bootstrap"]), ["recovery"])
        source = [c for c in spec["externalClusters"] if c["name"] == spec["bootstrap"]["recovery"]["source"]][0]
        read, write = source["plugin"]["parameters"], spec["plugins"][0]["parameters"]
        self.assertEqual(read["barmanObjectName"], write["barmanObjectName"])
        self.assertNotEqual(read["serverName"], write["serverName"])


class DevWaves(unittest.TestCase):
    """Root's sync waves order the apps only when ArgoCD can read an Application's health: without the check, each wave
    is applied as soon as the one before it is created, Healthy or not."""

    def test_argocd_reads_the_health_of_an_application_and_of_a_database(self):
        # The HelmChart k3s.sh writes, read as YAML down to the chart's values: a key under the wrong parent fails here.
        script = (LIMA / "provision" / "k3s.sh").read_text()
        chart = re.search(r"manifests/argocd\.yaml <<YAML\n(.*?)\nYAML\n", script, re.DOTALL).group(1)
        cm = yaml_text(yaml_text(chart)["spec"]["valuesContent"])["configs"]["cm"]
        self.assertIn("hs.status = obj.status.health.status", cm["resource.customizations.health.argoproj.io_Application"])
        self.assertIn("obj.status.applied == true", cm["resource.customizations.health.postgresql.cnpg.io_Database"])


def overlay_image(app):
    """The image an overlay sets: its single `images` entry's newName (else the entry name) and newTag."""
    text = (GITOPS / app / "kustomization.yaml").read_text().split("\nimages:\n", 1)[1]
    name = re.search(r"newName:\s*(\S+)", text) or re.search(r"-\s*name:\s*(\S+)", text)
    return name.group(1) + ":" + re.search(r'newTag:\s*"([^"]+)"', text).group(1)


def realm_users(base_dir):
    """Users and realm roles a realm import of base/keycloak declares: the JSON of its ConfigMap of the same name."""
    out = subprocess.run(["kubectl", "kustomize", str(GITOPS.parent / "base" / "keycloak" / base_dir)],
                         capture_output=True, text=True, check=True).stdout
    as_json = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"],
        input=out, capture_output=True, text=True, check=True).stdout
    for obj in json.loads(as_json):
        if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "keycloak-" + base_dir:
            realm = json.loads(next(iter(obj["data"].values())))
            roles = [role["name"] for role in realm.get("roles", {}).get("realm", [])]
            return roles, {user["username"]: user.get("realmRoles", []) for user in realm["users"]}
    raise AssertionError("no ConfigMap in base/keycloak/" + base_dir)


class TestAccounts(unittest.TestCase):
    """The control plane approves on sign-in only accounts with the realm role auto-approve; every other signup waits
    for an admin. The test accounts carry it, or on an empty database nobody could approve anybody
    (https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/tenancy-and-admin.md#approval-is-activation)."""

    def test_the_realm_declares_the_role(self):
        roles, _ = realm_users("realm-import")
        self.assertIn("auto-approve", roles)

    def test_every_test_account_carries_it(self):
        _, users = realm_users("realm-import")
        _, second = realm_users("realm-import-beta-user-2")
        users.update(second)
        self.assertEqual(sorted(users), ["admin-test", "beta-user", "beta-user-2"])
        for name, roles in users.items():
            self.assertIn("auto-approve", roles, name)


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


class DevClusterIdRename(unittest.TestCase):
    """The cluster id was local-mac until 2026-10-27. A PreSync hook of the control plane moves a dev database's rows to
    local in the same sync that rolls the control plane onto the new id, so no command meets a cluster that is gone."""

    def job(self):
        jobs = [o for o in render("control-plane") if o["kind"] == "Job" and o["metadata"]["name"] == "control-plane-rename-cluster-id"]
        self.assertEqual(len(jobs), 1)
        return jobs[0]

    def test_runs_after_the_migration_before_and_after_the_control_plane_rolls(self):
        notes = self.job()["metadata"]["annotations"]
        # PreSync: before the new control plane starts. PostSync again: rows the old pod wrote while PreSync ran.
        self.assertEqual(notes["argocd.argoproj.io/hook"], "PreSync,PostSync")
        migrate = first(render("control-plane"), "Job", "control-plane-migrate")["metadata"]["annotations"]
        self.assertGreater(int(notes["argocd.argoproj.io/sync-wave"]), int(migrate.get("argocd.argoproj.io/sync-wave", "0")))

    def test_one_statement_moves_every_table_keyed_by_cluster(self):
        container = self.job()["spec"]["template"]["spec"]["containers"][0]
        script = [e["value"] for e in container["env"] if e["name"] == "SQL"][0]
        self.assertIn('psql -v ON_ERROR_STOP=1 -At -c "$SQL"', " ".join(container["args"]))
        for table in ("vms", "volumes", "networks", "load_balancers", "provider_commands", "vm_template_clusters"):
            self.assertIn(f"UPDATE core.{table} SET cluster_id = 'local' WHERE cluster_id = 'local-mac'", script, table)
        self.assertIn("DELETE FROM core.vm_template_clusters", script)
        sql = script[script.index("WITH "):]
        self.assertEqual(sql.count(";"), 1, "one statement: all rows move or none")

    def run_script(self, psql_body):
        container = self.job()["spec"]["template"]["spec"]["containers"][0]
        with tempfile.TemporaryDirectory() as tmp:
            fake = pathlib.Path(tmp) / "psql"
            fake.write_text("#!/bin/sh\n" + psql_body + "\n")
            fake.chmod(0o755)
            env = {"PATH": f"{tmp}:/usr/bin:/bin", "SQL": "SELECT 1;",
                   "ConnectionStrings__Titan": "Host=h;Port=5432;Database=titan;Username=titan;Password=abc123"}
            return subprocess.run(["sh", "-c", container["args"][0]], env=env, capture_output=True, text=True)

    def test_a_failed_psql_fails_the_job(self):
        # A failing PreSync run stops the sync, so the control plane does not roll onto local with the rows still under
        # local-mac; a failing PostSync run marks the sync failed.
        self.assertNotEqual(self.run_script('echo "could not connect" >&2; exit 2').returncode, 0)

    def test_a_working_psql_reports_the_count(self):
        out = self.run_script('[ "$PGHOST" = h ] && [ "$PGUSER" = titan ] && [ "$PGPASSWORD" = abc123 ] && echo 24')
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("24", out.stdout)

    def test_reads_the_connection_the_migration_reads(self):
        env = self.job()["spec"]["template"]["spec"]["containers"][0]["envFrom"]
        self.assertIn({"secretRef": {"name": "control-plane-db"}}, env)

    def test_staging_has_no_such_job(self):
        base = subprocess.run(["kubectl", "kustomize", str(GITOPS.parent / "base" / "control-plane")], capture_output=True,
                              text=True, check=True).stdout
        self.assertNotIn("rename-cluster-id", base)


class NoFakeService(unittest.TestCase):
    def test_reads_the_applications(self):
        names = [name for _, name, _ in applications()]
        self.assertIn("root-local", names)
        self.assertIn("control-plane-local", names)

    def test_no_application_is_named_after_one_os(self):
        # One dev environment on macOS or Ubuntu: the names ArgoCD shows must not say which.
        names = [name for _, name, _ in applications()]
        self.assertEqual([n for n in names if "mac" in n or "ubuntu" in n or "linux" in n], [])

    def test_no_application_deploys_a_fake(self):
        offenders = [f"{file}: {name} {path}" for file, name, path in applications() if FAKE.search(name + " " + path)]
        self.assertEqual(offenders, [])

    def test_no_app_directory_is_a_fake(self):
        directories = [d.name for d in GITOPS.iterdir() if d.is_dir()]
        self.assertIn("control-plane", directories)
        self.assertEqual([d for d in directories if FAKE.search(d)], [])


# Names that belong to one environment: the environments' own words and namespaces, local and public addresses, and a
# storage account. Test accounts' e-mail addresses are the same everywhere. A value of another shape (an IP, an endpoint
# of another provider) is not seen.
ENVIRONMENT_WORD = re.compile(
    r"staging|\bprd\b|titan(-auth|-db)?-dev\b|localhost|\.internal\b|cloudflarestorage\.com|(?<!@)\b[a-z0-9.-]+\.openvicloud\.com",
    re.IGNORECASE)


def environment_words(root):
    """Every line of a file under root that names one environment, as (path, line number, line)."""
    hits = []
    for path in sorted(pathlib.Path(root).rglob("*")):
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if ENVIRONMENT_WORD.search(line.replace("github.com/OpenViCloud", "")):
                hits.append((str(path.relative_to(root)), number, line.strip()))
    return hits


class BaseNamesNoEnvironment(unittest.TestCase):
    """base/ is shared by every environment, which sets what is its own in its overlay
    (https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/platform-infra.md#gitops-flow)."""

    def test_no_file_of_base_names_an_environment(self):
        self.assertEqual(environment_words(BASE), [])

    def test_the_check_sees_a_name_of_each_kind(self):
        with tempfile.TemporaryDirectory() as root:
            lines = ["ns: titan-auth-staging", "env: prd", "url: http://localhost:5173",
                     "url: https://portal.openvicloud.com", "ns: titan-db-dev", "host: lima-titan-k3s.internal",
                     "endpoint: https://f74ed847.r2.cloudflarestorage.com",
                     "email: beta-user@openvicloud.com", "doc: https://github.com/OpenViCloud/titan-ops/blob/main/x.md",
                     "log: /dev/null", "dir: devices"]
            pathlib.Path(root, "a.yaml").write_text("\n".join(lines) + "\n")
            self.assertEqual([number for _, number, _ in environment_words(root)], [1, 2, 3, 4, 5, 6, 7])


class EnvironmentValuesReachTheirReaders(unittest.TestCase):
    """What base reads from a ConfigMap the overlay generates is there on dev: the realm's portal addresses and the
    runner's URLs. A missing key fails at run time: keycloak-config-cli stops on an undefined $(env:...) (and a missing
    ConfigMap keeps its hook pod from starting); the runner pod does not start (configMapKeyRef is not optional)."""

    def test_every_variable_of_the_realm_has_a_source(self):
        objects = render("keycloak/realm-import")
        job = first(objects, "Job", "keycloak-config-cli")
        container = job["spec"]["template"]["spec"]["containers"][0]
        provided = {entry["name"] for entry in container["env"]}
        for source in container["envFrom"]:
            config_map = first(objects, "ConfigMap", source["configMapRef"]["name"])
            provided |= set(config_map["data"])
        realm = next(obj for obj in objects if obj["kind"] == "ConfigMap" and obj["metadata"]["name"] == "keycloak-realm-import")
        wanted = set(re.findall(r"\$\(env:([A-Z0-9_]+)\)", json.dumps(realm["data"])))
        self.assertIn("PORTAL_ORIGIN", wanted)
        self.assertEqual(sorted(wanted - provided), [])

    def test_the_runner_reads_its_urls_from_a_generated_config_map(self):
        objects = render("regression-runner", root=REPO / "lima")
        for name in ("titan-regression", "titan-regression-b"):
            env = first(objects, "CronJob", name)["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["env"]
            refs = [entry["valueFrom"]["configMapKeyRef"] for entry in env if "configMapKeyRef" in entry.get("valueFrom", {})]
            self.assertEqual(sorted(ref["key"] for ref in refs), ["ADMIN_BASE_URL", "API_BASE_URL", "PORTAL_BASE_URL"])
            for ref in refs:
                self.assertTrue(first(objects, "ConfigMap", ref["name"])["data"][ref["key"]].startswith("http://"))


class KeycloakRealm(unittest.TestCase):
    """Keycloak itself creates and changes no realm; the keycloak-config-cli hooks do
    (https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/platform-infra.md#keycloak-realm-as-code):
    Keycloak's own --import-realm does not resolve $(env:...), so on an empty database it stopped on the realm's
    redirect URIs and never started."""

    def test_keycloak_creates_no_realm_itself(self):
        app = yaml_file(GITOPS / "apps" / "keycloak.yaml")
        chart = next(source for source in app["spec"]["sources"] if source.get("chart") == "keycloakx")
        values = {}
        for value_file in chart["helm"]["valueFiles"]:
            values.update(yaml_file(REPO / value_file.removeprefix("$local/")))
        self.assertIn("start", values["command"])
        self.assertNotIn("--import-realm", values["command"])
        volumes = yaml_text(values["extraVolumes"])
        self.assertIn("keycloak-theme-openvicloud", [v.get("configMap", {}).get("name") for v in volumes])
        self.assertNotIn("keycloak-realm-import", [v.get("configMap", {}).get("name") for v in volumes])
        self.assertNotIn("/opt/keycloak/data/import", [m["mountPath"] for m in yaml_text(values["extraVolumeMounts"])])


if __name__ == "__main__":
    unittest.main(verbosity=2)
