#!/usr/bin/env python3
"""The function cluster of function/ (k3s + Kata `fc` + Knative + registry on the Ubuntu dev host).

What must hold without the cluster: the manifests render, nothing floats (every image in manifests/ is a digest, every downloaded
release manifest still has the SHA-256 pinned in function/manifests/pins.txt), the Kata RuntimeClass carries our own
overhead and not kata-deploy's, the cluster takes none of the host ports Lima's VMs hold, and the scripts stop before
they write anything when the host cannot run it (no KVM, not x86_64, too little RAM) or when kubectl points at another
cluster. What needs the cluster (a function answering, scale to zero) is function/verify.sh.

Run:  python3 tests/test_function_cluster.py     (needs kubectl, ruby and network: the Knative manifests are
      release assets of knative/serving and knative-extensions/net-kourier)
"""
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import tempfile
import unittest
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
FUNCTION = REPO / "function"
CLUSTER = FUNCTION / "manifests" / "cluster"
WORKER = FUNCTION / "manifests" / "worker"
CRDS = FUNCTION / "manifests" / "crds"
PINS = FUNCTION / "manifests" / "pins.txt"
INSTALL = FUNCTION / "host" / "install.sh"
UNINSTALL = FUNCTION / "host" / "uninstall.sh"
UP = FUNCTION / "up.sh"
VERIFY = FUNCTION / "verify.sh"
RUNTIMES_VERIFY = FUNCTION / "runtimes-verify.sh"

# Host ports of Lima's two VMs (docs/topology.md#network), and 5000, which another program held when this was measured.
LIMA_PORTS = {6443, 10250, 10255, 8080, 8443, 9100, 8472, 5000}
KATA_DEPLOY_DEFAULT_OVERHEAD = ("250m", "130Mi")


def render(path):
    out = subprocess.run(["kubectl", "kustomize", str(path)], capture_output=True, text=True, check=True).stdout
    as_json = subprocess.run(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"],
        input=out, capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def images_of(obj):
    """Every container image an object names: pod specs, and the ConfigMap keys Knative reads an image from."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "image" and isinstance(value, str):
                    found.append(value)
                elif key.endswith("-image") and isinstance(value, str):
                    found.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(obj)
    return found


class RenderTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cluster = render(CLUSTER)
        cls.crds = render(CRDS)
        cls.worker = render(WORKER)

    def test_kata_fc_runtimeclass_is_ours(self):
        rc = [o for o in self.cluster if o["kind"] == "RuntimeClass" and o["metadata"]["name"] == "kata-fc"]
        self.assertEqual(len(rc), 1, "one RuntimeClass kata-fc")
        rc = rc[0]
        self.assertEqual(rc["handler"], "kata-fc")
        fixed = rc["overhead"]["podFixed"]
        self.assertNotEqual((fixed["cpu"], fixed["memory"]), KATA_DEPLOY_DEFAULT_OVERHEAD,
                            "kata-deploy's default overhead (250m, 130Mi) allows only 11 pods on 6 CPUs")
        self.assertEqual(rc["scheduling"]["nodeSelector"], {"katacontainers.io/kata-runtime": "true"})

    def test_runtimeclassname_is_enabled_in_knative(self):
        features = [o for o in self.cluster if o["kind"] == "ConfigMap" and o["metadata"]["name"] == "config-features"]
        self.assertEqual(features[0]["data"]["kubernetes.podspec-runtimeclassname"], "enabled")

    def test_kourier_stays_inside_the_host(self):
        svc = [o for o in self.cluster if o["kind"] == "Service" and o["metadata"]["name"] == "kourier"]
        self.assertEqual(svc[0]["spec"]["type"], "ClusterIP", "Kourier has no address outside the cluster: a function is reached through the host")

    def test_no_image_floats(self):
        seen = 0
        for obj in self.cluster + self.crds + self.worker:
            for image in images_of(obj):
                seen += 1
                self.assertIn("@sha256:", image, f"{obj['kind']}/{obj['metadata']['name']}: {image}")
                self.assertNotIn(":latest", image)
        self.assertGreater(seen, 8, "Knative's four Deployments, queue-proxy, Kourier, Envoy and the registry")

    def test_envoy_is_pinned_by_digest(self):
        envoy = [i for o in self.cluster for i in images_of(o) if "envoyproxy/envoy" in i]
        self.assertTrue(envoy, "net-kourier's gateway runs Envoy")
        for image in envoy:
            self.assertRegex(image, r"@sha256:[0-9a-f]{64}$")
            self.assertNotIn("-latest", image, "net-kourier 1.24.0 names envoy:v1.37-latest, a floating tag")

    def test_the_function_worker_is_one_pod_reaching_the_control_plane_on_the_host(self):
        deploy = [o for o in self.worker if o["kind"] == "Deployment"]
        self.assertEqual(len(deploy), 1)
        self.assertEqual(deploy[0]["spec"]["replicas"], 1, "two workers would report each runtime twice")
        self.assertEqual(deploy[0]["spec"]["strategy"]["type"], "Recreate")
        spec = deploy[0]["spec"]["template"]["spec"]
        self.assertTrue(spec["hostNetwork"], "the dev control plane is at the host's 127.0.0.1:8080 only (docs/network.md)")
        self.assertIn({"ip": "127.0.0.1", "hostnames": ["api.localhost"]}, spec["hostAliases"])
        container = spec["containers"][0]
        env = {e["name"]: e.get("value") for e in container["env"]}
        self.assertEqual(env["CP_BASE_URL"], "http://api.localhost:8080")
        self.assertEqual(env["FUNCTION_CLUSTER_ID"], "local-function")
        port = int(env["HEALTH_ADDR"].rsplit(":", 1)[1])
        self.assertNotIn(port, LIMA_PORTS)
        self.assertEqual(container["livenessProbe"]["httpGet"]["port"], port)
        self.assertEqual(container["envFrom"], [{"secretRef": {"name": "function-worker-secrets"}}])
        self.assertEqual(spec["serviceAccountName"], "function-worker")

    def test_the_function_worker_may_read_nodes_and_run_pods_in_its_namespace_only(self):
        roles = {o["metadata"]["name"]: o for o in self.worker if o["kind"] in ("ClusterRole", "Role")}
        self.assertEqual(roles["titan-function-worker"]["rules"], [{"apiGroups": [""], "resources": ["nodes"], "verbs": ["list"]}])
        pulls = roles["function-worker-pulls"]
        self.assertEqual(pulls["metadata"]["namespace"], "titan-function-system")
        self.assertEqual(pulls["rules"][0]["resources"], ["pods"])
        self.assertEqual(set(pulls["rules"][0]["verbs"]), {"get", "create", "patch", "deletecollection"})

    def test_registry_is_ours_and_local(self):
        deploy = [o for o in self.cluster if o["kind"] == "Deployment" and o["metadata"]["name"] == "registry"]
        self.assertEqual(len(deploy), 1)
        spec = deploy[0]["spec"]["template"]["spec"]
        self.assertTrue(spec["hostNetwork"])
        env = {e["name"]: e.get("value") for e in spec["containers"][0]["env"]}
        self.assertEqual(env["REGISTRY_HTTP_ADDR"], "127.0.0.1:5100")


class PinsTest(unittest.TestCase):
    def pins(self):
        out = {}
        for line in PINS.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                digest, url = line.split(None, 1)
                out[url.strip()] = digest
        return out

    def test_every_remote_resource_is_pinned(self):
        wanted = set()
        for kustomization in (CLUSTER / "kustomization.yaml", CRDS / "kustomization.yaml"):
            wanted |= set(re.findall(r"^\s*-\s*(https://\S+)", kustomization.read_text(), re.MULTILINE))
        self.assertTrue(wanted)
        self.assertEqual(wanted, set(self.pins()), "pins.txt lists exactly the URLs the kustomizations download")
        for url in wanted:
            self.assertRegex(url, r"/download/knative-v1\.24\.0/", "pinned to one release tag")

    def test_each_download_matches_its_sha256(self):
        for url, digest in self.pins().items():
            with urllib.request.urlopen(url) as response:
                body = response.read()
            self.assertEqual(hashlib.sha256(body).hexdigest(), digest, url)


class ScriptTest(unittest.TestCase):
    def test_scripts_exist_and_parse(self):
        for script in (INSTALL, UNINSTALL, UP, VERIFY, RUNTIMES_VERIFY):
            self.assertTrue(script.exists(), script)
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_install_is_what_the_design_asks(self):
        text = INSTALL.read_text()
        for needle in ("--secrets-encryption", "--https-listen-port 6444", "--kubelet-arg=port=10350",
                       "--flannel-backend=host-gw", "snapshotter: \"devmapper\"", "version: 4.4.0",
                       "devpool", "INSTALL_K3S_VERSION"):
            self.assertIn(needle, text)
        self.assertRegex(text, r"runtimeClasses:\s*\n\s*enabled: false", "the RuntimeClass is function/manifests'")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotRegex(code, r"ufw|iptables|nft ", "the firewall is not touched")

    def test_k3s_kubectl_and_secrets_encrypt_name_our_cluster(self):
        # `k3s secrets-encrypt` defaults to port 6443, which is titan-k3s's (Lima) API on this host, and `k3s kubectl`
        # follows $KUBECONFIG when it is set (sudo -E): each names its server or kubeconfig.
        seen = 0
        for script in (INSTALL, UNINSTALL):
            for number, line in enumerate(script.read_text().splitlines(), 1):
                if re.search(r"\bk3s secrets-encrypt\b", line):
                    seen += 1
                    self.assertIn("--server https://127.0.0.1:6444", line, f"{script.name}:{number}")
                if re.search(r"\bk3s kubectl\b", line):
                    seen += 1
                    self.assertIn("--kubeconfig /etc/rancher/k3s/k3s.yaml", line, f"{script.name}:{number}")
        self.assertGreaterEqual(seen, 8)

    def test_runtimes_verify_talks_to_the_function_cluster_only(self):
        # the cluster's own kubeconfig is in `kc`; a bare kubectl would follow the default context, which is titan-k3s's
        text = RUNTIMES_VERIFY.read_text()
        self.assertRegex(text, r"kc=\(kubectl --kubeconfig \"\$kubeconfig\"\)")
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("   #")[0]  # a trailing comment may name kubectl
            if code.lstrip().startswith("#"):
                continue
            self.assertNotRegex(code, r"(?<![\w\[\"{$-])kubectl (?!--kubeconfig)(?!&)(?!>)", f"runtimes-verify.sh:{number}: {line}")
        self.assertIn("jsonpath={.clusters[0].cluster.server}')\" = https://127.0.0.1:6444", text, "it compares the server kubectl will use with the function cluster's")
        self.assertNotRegex(text, r"\bsudo\b(?!\.)", "no sudo")

    def test_the_runtime_samples_answer_in_the_shape_the_script_reads(self):
        # runtimes-verify.sh matches one body shape (`case` patterns on `kernel=`, ` uid=1000 `, ` fnwrite=denied tmpwrite=ok `,
        # ` path=/some/path fn=f-sample version=v-sample left=<digits>`): each sample says these fields in this order
        order = ("hello ", "kernel=", " uid=", " fnwrite=", " tmpwrite=", " path=", " fn=", " version=", " left=")
        for lang, name in (("python", "main.py"), ("node", "index.mjs"), ("go", "main.go")):
            text = (FUNCTION / "sample" / "runtimes" / lang / name).read_text()
            body = text[text.index("hello " + lang):]
            at = [body.index(token.replace("hello ", "hello " + lang) if token == "hello " else token) for token in order]
            self.assertEqual(at, sorted(at), f"{lang}/{name}: fields out of order")
            for needle in ("CRON-EVENT ", "sample failure", "sample cron failure", "x-runtime"):
                self.assertIn(needle, text, f"{lang}/{name}: {needle}")
        script = RUNTIMES_VERIFY.read_text()
        for pattern in ('"hello $lang kernel="*', '*" uid=1000 "*', '*" fnwrite=denied tmpwrite=ok "*', '" path=/some/path fn=f-sample version=v-sample left="'):
            self.assertIn(pattern, script)

    def test_runtimes_verify_wants_a_full_sha(self):
        for sha in ("main", "c9a2d77", "../x", "a b", "x&scope=repository:o/r:pull", "C9A2D7746BD30C418F7BC0AFB2FD61AF16F3F7B1"):
            # a kubeconfig that is not there: if the sha guard ever regressed, this must not go on against the real cluster
            out = subprocess.run(["bash", str(RUNTIMES_VERIFY), sha], capture_output=True, text=True,
                                 env={**os.environ, "FN_KUBECONFIG": "/nonexistent/kubeconfig"})
            self.assertEqual(out.returncode, 1, sha)
            self.assertIn("40-hex", out.stderr, sha)

    def test_runtimes_verify_refuses_a_kubeconfig_that_points_elsewhere(self):
        with tempfile.TemporaryDirectory() as work:
            bad = pathlib.Path(work, "kubeconfig")
            bad.write_text("apiVersion: v1\nkind: Config\ncurrent-context: c\nclusters:\n- name: c\n  cluster: {server: 'https://127.0.0.1:6443'}\n"
                           "contexts:\n- name: c\n  context: {cluster: c, user: u}\nusers:\n- name: u\n  user: {}\n")
            out = subprocess.run(["bash", str(RUNTIMES_VERIFY), "a" * 40], capture_output=True, text=True, env={**os.environ, "FN_KUBECONFIG": str(bad)})
            self.assertEqual(out.returncode, 1)
            self.assertIn("does not point at the function cluster", out.stderr)

    def test_the_cronjob_and_the_job_are_deleted_by_separate_commands(self):
        # `kubectl delete cronjob A job B` reads B as a cronjob and leaves the Job: a second run then finds a stale one
        for number, line in enumerate(RUNTIMES_VERIFY.read_text().splitlines(), 1):
            code = line.split("   #")[0]
            if "delete" in code and not code.lstrip().startswith("#"):
                self.assertFalse(re.search(r"delete cronjob \S+ job\b", code), f"runtimes-verify.sh:{number}")

    def test_copy_image_checks_digests_without_assert_and_reads_both_registries(self):
        text = (FUNCTION / "sample" / "copy_image.py").read_text()
        self.assertNotRegex(text, r"(?m)^\s*assert\b", "python -O strips asserts: a digest check must not be one")
        self.assertIn("https://ghcr.io/token", text)
        self.assertIn("auth.docker.io", text)

    def test_scripts_replace_an_old_log(self):
        # a log left by an earlier run may belong to the user: root cannot write over it in /tmp (fs.protected_regular)
        for script in (INSTALL, UNINSTALL):
            self.assertRegex(script.read_text(), r'rm -f "\$LOG"', script.name)

    def test_install_log_is_not_chowned(self):
        # root cannot append to a file another user owns in /tmp (fs.protected_regular): tee failed on it.
        self.assertNotRegex(INSTALL.read_text(), r"chown .*\$LOG")

    def test_cluster_ports_do_not_meet_limas(self):
        text = INSTALL.read_text() + CLUSTER.joinpath("registry.yaml").read_text()
        ports = set(map(int, re.findall(r"(?:https-listen-port|kubelet-arg=port=|127\.0\.0\.1:)\s*(\d{4,5})", text)))
        self.assertTrue({6444, 10350, 5100} <= ports, ports)
        self.assertFalse(ports & LIMA_PORTS, ports & LIMA_PORTS)

    def run_script(self, script, env, stub_kubectl=False, args=()):
        with tempfile.TemporaryDirectory() as work:
            full = {"PATH": os.environ["PATH"], "HOME": work, **env}
            if stub_kubectl:
                bin_dir = pathlib.Path(work, "bin")
                bin_dir.mkdir()
                calls = pathlib.Path(work, "calls")
                stub = bin_dir / "kubectl"
                stub.write_text(f"#!/bin/bash\necho \"$@\" >> {calls}\nexit 0\n")
                stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
                full["PATH"] = f"{bin_dir}:{full['PATH']}"
                full["FN_KUBECTL"] = "kubectl"
            result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True, env=full, cwd=work)
            written = pathlib.Path(work, "calls").read_text() if pathlib.Path(work, "calls").exists() else ""
            return result, written

    def meminfo(self, work, available_kib, swap_total=4194300, swap_free=4194300):
        path = pathlib.Path(work, "meminfo")
        path.write_text(f"MemTotal: 15777388 kB\nMemAvailable: {available_kib} kB\nSwapTotal: {swap_total} kB\nSwapFree: {swap_free} kB\n")
        return str(path)

    def test_install_stops_without_kvm(self):
        with tempfile.TemporaryDirectory() as work:
            result, _ = self.run_script(INSTALL, {"FN_KVM_DEVICE": f"{work}/no-kvm", "FN_MACHINE": "x86_64",
                                                  "HOST_MEMINFO": self.meminfo(work, 8000000), "FN_DRY_GATES": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("/dev/kvm", result.stderr + result.stdout)

    def test_install_stops_off_x86(self):
        with tempfile.TemporaryDirectory() as work:
            kvm = pathlib.Path(work, "kvm")
            kvm.write_text("")
            result, _ = self.run_script(INSTALL, {"FN_KVM_DEVICE": str(kvm), "FN_MACHINE": "aarch64",
                                                  "HOST_MEMINFO": self.meminfo(work, 8000000), "FN_DRY_GATES": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("x86_64", result.stderr + result.stdout)

    def test_install_stops_when_host_memory_is_low(self):
        with tempfile.TemporaryDirectory() as work:
            kvm = pathlib.Path(work, "kvm")
            kvm.write_text("")
            result, _ = self.run_script(INSTALL, {"FN_KVM_DEVICE": str(kvm), "FN_MACHINE": "x86_64",
                                                  "HOST_MEMINFO": self.meminfo(work, 1048576), "FN_DRY_GATES": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HOST_MEMORY=LOW", result.stdout + result.stderr)

    def test_install_gates_pass_on_a_good_host(self):
        with tempfile.TemporaryDirectory() as work:
            kvm = pathlib.Path(work, "kvm")
            kvm.write_text("")
            result, _ = self.run_script(INSTALL, {"FN_KVM_DEVICE": str(kvm), "FN_MACHINE": "x86_64",
                                                  "HOST_MEMINFO": self.meminfo(work, 4800000), "FN_DRY_GATES": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GATES_OK", result.stdout)

    def test_up_refuses_another_cluster(self):
        with tempfile.TemporaryDirectory() as work:
            kubeconfig = pathlib.Path(work, "kubeconfig")
            kubeconfig.write_text("apiVersion: v1\nclusters:\n- cluster: {server: 'https://127.0.0.1:6443'}\n  name: x\n")
            result, calls = self.run_script(UP, {"FN_KUBECONFIG": str(kubeconfig), "HOST_MEMINFO": self.meminfo(work, 8000000)},
                                            stub_kubectl=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("6444", result.stderr + result.stdout)
        self.assertNotIn("apply", calls, "nothing is applied to titan-k3s's API")

    def test_up_stops_when_host_memory_is_low(self):
        with tempfile.TemporaryDirectory() as work:
            kubeconfig = pathlib.Path(work, "kubeconfig")
            kubeconfig.write_text("apiVersion: v1\nclusters:\n- cluster: {server: 'https://127.0.0.1:6444'}\n  name: x\n")
            result, calls = self.run_script(UP, {"FN_KUBECONFIG": str(kubeconfig), "HOST_MEMINFO": self.meminfo(work, 1048576)},
                                            stub_kubectl=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HOST_MEMORY=LOW", result.stdout + result.stderr)
        self.assertNotIn("apply", calls)

    def test_up_applies_crds_then_the_rest_then_the_worker_and_its_token(self):
        with tempfile.TemporaryDirectory() as work:
            kubeconfig = pathlib.Path(work, "kubeconfig")
            kubeconfig.write_text("apiVersion: v1\nclusters:\n- cluster: {server: 'https://127.0.0.1:6444'}\n  name: x\n")
            secrets = pathlib.Path(work, "secrets.env")
            secrets.write_text("TITAN_DB_PASSWORD=x\nINTERNAL_TOKEN=tok-9f3a\n")
            result, calls = self.run_script(UP, {"FN_KUBECONFIG": str(kubeconfig), "HOST_MEMINFO": self.meminfo(work, 8000000),
                                                 "FN_SECRETS_ENV": str(secrets)}, stub_kubectl=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        applies = [line for line in calls.splitlines() if " apply " in f" {line} "]
        self.assertEqual(len(applies), 4, calls)
        self.assertIn("manifests/crds", applies[0])
        self.assertIn("manifests/cluster", applies[1])
        self.assertIn("manifests/worker", applies[2])
        self.assertTrue(applies[3].endswith("-f -"), "the worker's Secret is applied from stdin")
        for line in applies:
            self.assertIn("--server-side", line)
        self.assertNotIn("tok-9f3a", calls, "the token never reaches argv")
        self.assertIn("function-worker-secrets --from-env-file=/dev/stdin", calls)
        for line in calls.splitlines():
            self.assertIn(str(kubeconfig), line, "every call names the function cluster's kubeconfig, never the default")

    def test_up_without_the_internal_token_applies_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            kubeconfig = pathlib.Path(work, "kubeconfig")
            kubeconfig.write_text("apiVersion: v1\nclusters:\n- cluster: {server: 'https://127.0.0.1:6444'}\n  name: x\n")
            result, calls = self.run_script(UP, {"FN_KUBECONFIG": str(kubeconfig), "HOST_MEMINFO": self.meminfo(work, 8000000),
                                                 "FN_SECRETS_ENV": str(pathlib.Path(work, "absent.env"))}, stub_kubectl=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INTERNAL_TOKEN", result.stderr)
        self.assertNotIn("apply", calls)


class RuntimesVerifyHarness(unittest.TestCase):
    """runtimes-verify.sh run against stubs of kubectl, curl, go and python3 (the stub python3 only fakes the two image scripts),
    so what it does to the cluster is what the test reads from the stub's log: no cluster is touched."""

    def setUp(self):
        self.work = pathlib.Path(tempfile.mkdtemp(prefix="rv-harness-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.work, ignore_errors=True))
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.log = self.work / "kubectl.log"
        real_python = __import__("shutil").which("python3")
        stubs = {
            "kubectl": f'''#!/bin/bash
echo "$*" >> {self.log}
case "$*" in
  *"config view"*) echo https://127.0.0.1:6444 ;;
  *"apply -f -"*) cat > {self.work}/apply-$(date +%s%N).yaml ;;
  *"get svc kourier"*) echo 10.0.0.1 ;;
  *"create namespace"*) echo "apiVersion: v1" ;;
esac
exit 0
''',
            "curl": '''#!/bin/bash
case "$*" in
  *"/v2/"|*"/v2/ "*) exit 0 ;;
  *"/manifests/"*) echo '{"config": {"digest": "sha256:cfg"}}' ;;
  *"/blobs/"*) echo '{"os": "linux", "architecture": "amd64", "config": {"User": "1000:1000"}}' ;;
esac
''',
            "go": "#!/bin/bash\ntouch bootstrap   # `go build -o bootstrap` leaves the file the script zips\nexit 0\n",
            "python3": f'''#!/bin/bash
case "$*" in
  *copy_image.py*) touch {self.work}/copy-started; echo "COPIED x -> y manifest=sha256:abcdef012345 layers=1 mediaType=application/vnd.oci.image.manifest.v1+json"; sleep ${{STUB_COPY_SLEEP:-0}} ;;
  *compose_image.py*) echo "MANIFEST_DIGEST=sha256:" ;;
  *) exec {real_python} "$@" ;;
esac
''',
        }
        for name, body in stubs.items():
            f = self.bin / name
            f.write_text(body)
            f.chmod(0o755)
        self.kubeconfig = self.work / "kubeconfig"
        self.kubeconfig.write_text("apiVersion: v1\nkind: Config\ncurrent-context: c\nclusters:\n- name: c\n  cluster: {server: 'https://127.0.0.1:6444'}\n"
                                   "contexts:\n- name: c\n  context: {cluster: c, user: u}\nusers:\n- name: u\n  user: {}\n")

    def start(self, **extra):
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "FN_KUBECONFIG": str(self.kubeconfig), **extra}
        return subprocess.Popen(["bash", str(RUNTIMES_VERIFY), "a" * 40], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)

    def stop_when(self, proc, condition, seconds=60):
        """Wait for condition(), then stop the script the way Ctrl-C would (its cleanup trap runs)."""
        import signal, time
        for _ in range(int(seconds * 10)):
            if condition() or proc.poll() is not None:
                break
            time.sleep(0.1)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=60)

    def test_the_server_guard_lets_the_function_cluster_through(self):
        # the positive case of the refusal test: a 6444 kubeconfig gets past the guard (the stub kubectl then sees its commands)
        proc = self.start()
        self.stop_when(proc, lambda: self.log.exists() and "create namespace" in self.log.read_text())
        self.assertIn("create namespace", self.log.read_text())

    def test_the_cleanup_trap_deletes_the_cronjobs_and_jobs_when_the_run_is_stopped(self):
        proc = self.start(STUB_COPY_SLEEP="30")
        self.stop_when(proc, lambda: (self.work / "copy-started").exists())
        deletes = [l for l in self.log.read_text().splitlines() if " delete " in l]
        want = {f"-n fn-runtimes delete {kind} fn-{lang}-{suffix} --ignore-not-found"
                for lang in ("python", "node", "go") for kind, suffix in (("cronjob", "cron"), ("job", "cronfail"))}
        self.assertEqual({d.split("--kubeconfig ")[-1].split(" ", 1)[1] if "--kubeconfig " in d else d for d in deletes} & want, want, deletes)
        self.assertTrue(all("-n fn-runtimes" in d for d in deletes), deletes)

    def test_the_throwing_cron_job_gets_sample_cron_fail_and_the_plain_cronjob_does_not(self):
        proc = self.start()
        self.stop_when(proc, lambda: len(list(self.work.glob("apply-*.yaml"))) >= 4, seconds=120)   # the namespace, then one apply per runtime that carries its CronJob and its Job
        rendered = "\n---\n".join(f.read_text() for f in sorted(self.work.glob("apply-*.yaml")))
        cron = [d for d in rendered.split("\n---\n") if "kind: CronJob" in d]
        jobs = [d for d in rendered.split("\n---\n") if "kind: Job" in d]
        self.assertEqual((len(cron), len(jobs)), (3, 3), rendered[:500])
        for d in cron:
            self.assertIn('{name: SAMPLE_CRON, value: ""}', d)
        for d in jobs:
            self.assertIn('{name: SAMPLE_CRON, value: "fail"}', d)


class CopyImageDigests(unittest.TestCase):
    """copy_image.py against a fake registry: a manifest or blob that does not hash to its digest stops the copy."""

    def run_copy(self, child_body, blob_body):
        import hashlib, io, json, runpy, sys, unittest.mock as mock
        sample = str(FUNCTION / "sample")
        sha = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
        blob = b"layer"
        child = json.dumps({"config": {"digest": sha(b"cfg"), "mediaType": "c"}, "layers": [{"digest": sha(blob)}],
                            "mediaType": "application/vnd.oci.image.manifest.v1+json"}).encode()
        index = json.dumps({"manifests": [{"digest": sha(child), "platform": {"architecture": "amd64", "os": "linux"}}]}).encode()
        pushed = []

        def fake_http(method, url, data=None, headers=None, ok=(200, 201, 202)):
            if method == "GET" and "/manifests/sha256:" in url:
                return 200, {}, child_body if child_body is not None else child
            if method == "GET" and "/manifests/" in url:
                return 200, {}, index
            if method == "GET" and "/blobs/" in url:
                return 200, {}, blob_body if blob_body is not None else (b"cfg" if sha(b"cfg") in url else blob)
            pushed.append((method, url))
            return 201, {"Location": "/x"}, b""

        token = io.BytesIO(b'{"token": "t"}')
        with mock.patch.object(sys, "dont_write_bytecode", True), mock.patch.object(sys, "argv", ["copy_image.py", "ghcr.io/o/r/p:t", "http://127.0.0.1:1", "runtime/p:t"]), \
                mock.patch.object(sys, "path", [sample] + sys.path), \
                mock.patch("urllib.request.urlopen", return_value=token), \
                mock.patch("compose_image.http", fake_http, create=True), \
                mock.patch("compose_image.push_blob", lambda *a: pushed.append(("blob", a[-1]))), \
                mock.patch("builtins.print"):
            sys.modules.pop("compose_image", None)
            self.addCleanup(sys.modules.pop, "compose_image", None)   # the fake http must not outlive the test
            import compose_image  # noqa: F401
            compose_image.http, compose_image.push_blob = fake_http, lambda *a: pushed.append(("blob", a[-1]))
            return pushed, runpy.run_path(str(FUNCTION / "sample" / "copy_image.py"))

    def test_a_good_manifest_and_blobs_are_copied(self):
        pushed, _ = self.run_copy(None, None)
        self.assertTrue([p for p in pushed if p[0] == "blob"], "the blobs are pushed")
        self.assertTrue([p for p in pushed if p[0] == "PUT" and "/manifests/" in p[1]], "and then the manifest")

    def test_a_child_manifest_that_does_not_hash_to_its_digest_is_refused(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_copy(b"{}", None)
        self.assertIn("manifest sha256:", str(raised.exception))

    def test_a_blob_that_does_not_hash_to_its_digest_is_refused(self):
        with self.assertRaises(SystemExit) as raised:
            self.run_copy(None, b"tampered")
        self.assertIn("blob sha256:", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
