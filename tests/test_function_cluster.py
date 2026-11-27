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
        for obj in self.cluster + self.crds:
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
            if line.lstrip().startswith("#"):
                continue
            self.assertNotRegex(line, r"(?<![\w\[\"{$-])kubectl (?!--kubeconfig)(?!&)(?!>)", f"runtimes-verify.sh:{number}: {line}")
        self.assertIn("https://127\\.0\\.0\\.1:6444", text, "it refuses a kubeconfig that is not the function cluster's")
        self.assertNotRegex(text, r"\bsudo\b(?!\.)", "no sudo")

    def test_the_runtime_samples_answer_alike(self):
        # runtimes-verify.sh reads one body shape from all three
        for lang, name in (("python", "main.py"), ("node", "index.mjs"), ("go", "main.go")):
            text = (FUNCTION / "sample" / "runtimes" / lang / name).read_text()
            for needle in ("hello " + lang, "kernel=", "uid=", "fnwrite=", "tmpwrite=", "path=", "fn=", "version=", "left=",
                           "CRON-EVENT ", "sample failure", "sample cron failure", "x-runtime"):
                self.assertIn(needle, text, f"{lang}/{name}: {needle}")

    def test_copy_image_reads_ghcr_and_docker_hub(self):
        text = (FUNCTION / "sample" / "copy_image.py").read_text()
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

    def test_up_applies_crds_before_the_rest(self):
        with tempfile.TemporaryDirectory() as work:
            kubeconfig = pathlib.Path(work, "kubeconfig")
            kubeconfig.write_text("apiVersion: v1\nclusters:\n- cluster: {server: 'https://127.0.0.1:6444'}\n  name: x\n")
            result, calls = self.run_script(UP, {"FN_KUBECONFIG": str(kubeconfig), "HOST_MEMINFO": self.meminfo(work, 8000000)},
                                            stub_kubectl=True)
        applies = [line for line in calls.splitlines() if " apply " in f" {line} "]
        self.assertEqual(len(applies), 2, calls)
        self.assertIn("manifests/crds", applies[0])
        self.assertIn("manifests/cluster", applies[1])
        for line in applies:
            self.assertIn("--server-side", line)
        for line in calls.splitlines():
            self.assertIn(str(kubeconfig), line, "every call names the function cluster's kubeconfig, never the default")


if __name__ == "__main__":
    unittest.main()
