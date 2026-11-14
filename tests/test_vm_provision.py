#!/usr/bin/env python3
"""lima/scripts/vm-provision.py: the `limactl edit --set` expressions that copy a Lima file's provision scripts into an
existing VM, nothing when the VM already runs them (docs/topology.md#provision-sync). `limactl create` copies each
script into the instance once, so without it a change to lima/provision/*.sh never reaches a VM that exists.

Run:  python3 tests/test_vm_provision.py     (the repo-file test needs ruby: python's stdlib reads no YAML)
"""
import base64
import json
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "lima" / "scripts" / "vm-provision.py"
# A backslash pair, an escape character and non-ASCII; the first two are what a JSON string through Lima's yq would change.
K3S = '#!/bin/bash\nprintf "k3s \\\\ \\n $HOME `x`\\033[0m" ──\x1b\n'
LLMNR = "#!/bin/bash\n# Lima's own, for Debian\n"
FILE = "vmType: vz\ncpus: 3\nprovision:\n- mode: system\n  file:\n    url: provision/k3s.sh\ncopyToHost:\n- guest: /x\n"


def run(yaml_text, provision, scripts=None):
    """(exit code, stdout lines, stderr) for a Lima file next to provision/, and the instance's provision list."""
    with tempfile.TemporaryDirectory() as d:
        (pathlib.Path(d) / "provision").mkdir()
        for name, text in (scripts or {"k3s.sh": K3S}).items():
            (pathlib.Path(d) / "provision" / name).write_text(text)
        path = pathlib.Path(d) / "titan-k3s.yaml"
        path.write_text(yaml_text)
        instance = json.dumps({"name": "titan-k3s", "config": {"provision": provision}})
        out = subprocess.run(["python3", str(SCRIPT), str(path)], input=instance + "\n", capture_output=True, text=True)
    return out.returncode, out.stdout.splitlines(), out.stderr


def set_value(line):
    """The script an expression sets: base64 that yq decodes with @base64d. That Lima's yq gives back the exact bytes
    was checked with `limactl edit` on a copy of an instance file (docs/topology.md#provision-sync); CI has no Lima."""
    match = re.fullmatch(r'\.provision\[(\d+)\]\.script = \("([A-Za-z0-9+/=]*)" \| @base64d\)', line)
    return int(match.group(1)), base64.b64decode(match.group(2)).decode()


class VmProvisionTest(unittest.TestCase):
    def test_a_vm_running_the_files_script_needs_nothing(self):
        self.assertEqual(run(FILE, [{"mode": "system", "script": K3S}]), (0, [], ""))

    def test_a_vm_with_an_old_script_gets_the_files_script(self):
        code, out, _ = run(FILE, [{"mode": "system", "script": "#!/bin/bash\necho old\n"}])
        self.assertEqual(code, 0)
        self.assertEqual([set_value(line) for line in out], [(0, K3S)])

    def test_limas_own_scripts_before_the_files_are_left_alone(self):
        code, out, _ = run(FILE, [{"mode": "system", "script": LLMNR}, {"mode": "system", "script": "old\n"}])
        self.assertEqual((code, [set_value(line) for line in out]), (0, [(1, K3S)]))

    def test_only_the_scripts_that_differ_are_set(self):
        two = FILE.replace("copyToHost:", "- mode: user\n  file:\n    url: provision/user.sh\ncopyToHost:")
        code, out, _ = run(two, [{"mode": "system", "script": K3S}, {"mode": "user", "script": "old\n"}],
                           {"k3s.sh": K3S, "user.sh": "new\n"})
        self.assertEqual((code, [set_value(line) for line in out]), (0, [(1, "new\n")]))

    def test_a_crlf_script_the_vm_already_runs_needs_nothing(self):
        crlf = "#!/bin/bash\r\necho k3s\r\n"
        self.assertEqual(run(FILE, [{"mode": "system", "script": crlf}], {"k3s.sh": crlf}), (0, [], ""))
        code, out, _ = run(FILE, [{"mode": "system", "script": "#!/bin/bash\necho k3s\n"}], {"k3s.sh": crlf})
        self.assertEqual((code, [set_value(line) for line in out]), (0, [(0, crlf)]))

    def test_a_blank_line_in_the_files_provision_stops(self):
        two = FILE.replace("copyToHost:", "\n- mode: user\n  file:\n    url: provision/k3s.sh\ncopyToHost:")
        code, out, err = run(two, [{"mode": "system", "script": K3S}, {"mode": "user", "script": K3S}])
        self.assertEqual((code, out), (2, []))
        self.assertIn("provision entry", err)

    def test_a_vm_with_fewer_scripts_than_the_file_stops(self):
        code, out, err = run(FILE, [])
        self.assertEqual((code, out), (2, []))
        self.assertIn("provision scripts", err)

    def test_a_mode_that_differs_stops(self):
        code, out, err = run(FILE, [{"mode": "user", "script": K3S}])
        self.assertEqual((code, out), (2, []))
        self.assertIn("mode", err)

    def test_an_inline_script_in_the_file_stops(self):
        code, out, err = run(FILE.replace("  file:\n    url: provision/k3s.sh\n", "  script: echo hi\n"),
                             [{"mode": "system", "script": K3S}])
        self.assertEqual((code, out), (2, []))
        self.assertIn("provision entry", err)

    def test_the_repo_files_read_as_ruby_reads_them(self):
        for path in sorted((ROOT / "lima").glob("*/titan-*.yaml")):
            spec = json.loads(subprocess.run(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"],
                input=path.read_text(), capture_output=True, text=True, check=True).stdout)
            scripts = [(p["mode"], (path.parent / p["file"]["url"]).read_text()) for p in spec["provision"]]
            stale = [{"mode": mode, "script": "old\n"} for mode, _ in scripts]
            code, out, err = run_repo(path, stale)
            self.assertEqual(code, 0, err)
            self.assertEqual([set_value(line)[1] for line in out], [script for _, script in scripts], path)
            code, out, _ = run_repo(path, [{"mode": mode, "script": script} for mode, script in scripts])
            self.assertEqual((code, out), (0, []), path)


def run_repo(path, provision):
    instance = json.dumps({"name": path.stem, "config": {"provision": provision}})
    out = subprocess.run(["python3", str(SCRIPT), str(path)], input=instance + "\n", capture_output=True, text=True)
    return out.returncode, out.stdout.splitlines(), out.stderr


if __name__ == "__main__":
    unittest.main()
