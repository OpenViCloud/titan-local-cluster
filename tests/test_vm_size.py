#!/usr/bin/env python3
"""lima/scripts/vm-size.py: the `limactl edit` flags that bring an existing VM to the cpus and memory of its Lima file,
nothing when they already match (docs/topology.md#ram-budget). up.sh creates a VM only once, so without it a new size
in the file never reaches a VM that exists.

Run:  python3 tests/test_vm_size.py     (the repo-file test needs ruby: python's stdlib reads no YAML)
"""
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "lima" / "scripts" / "vm-size.py"
GIB = 1024 ** 3


def run(yaml_text, cpus, memory_bytes):
    """(exit code, stdout, stderr) of vm-size.py for a Lima file and the instance `limactl list --json` reports."""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(yaml_text)
    instance = json.dumps({"name": "titan-k3s", "status": "Running", "cpus": cpus, "memory": memory_bytes})
    out = subprocess.run(["python3", str(SCRIPT), f.name], input=instance + "\n", capture_output=True, text=True)
    pathlib.Path(f.name).unlink()
    return out.returncode, out.stdout.strip(), out.stderr


FILE = "base: template:_images/ubuntu-24.04\nvmType: qemu\ncpus: 3\nmemory: 6GiB\ndisk: 30GiB\n"


class VmSizeTest(unittest.TestCase):
    def test_a_vm_of_the_files_size_needs_nothing(self):
        self.assertEqual(run(FILE, 3, 6 * GIB), (0, "", ""))

    def test_a_vm_with_less_memory_gets_both_flags(self):
        code, out, _ = run(FILE, 3, 4 * GIB)
        self.assertEqual((code, out), (0, "--cpus 3 --memory 6"))

    def test_a_vm_with_other_cpus_gets_both_flags(self):
        code, out, _ = run(FILE, 2, 6 * GIB)
        self.assertEqual((code, out), (0, "--cpus 3 --memory 6"))

    def test_a_file_without_a_whole_gib_memory_stops(self):
        code, out, err = run(FILE.replace("memory: 6GiB", "memory: 6144MiB"), 3, 6 * GIB)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("memory", err)

    def test_a_file_without_top_level_cpus_stops(self):
        code, out, err = run(FILE.replace("cpus: 3\n", "  cpus: 3\n"), 3, 6 * GIB)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("cpus", err)

    def test_the_repo_files_read_as_ruby_reads_them(self):
        for path in sorted((ROOT / "lima").glob("*/titan-*.yaml")):
            spec = json.loads(subprocess.run(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"],
                input=path.read_text(), capture_output=True, text=True, check=True).stdout)
            want = f"--cpus {spec['cpus']} --memory {int(spec['memory'].removesuffix('GiB'))}"
            code, out, _ = run(path.read_text(), 1, 1 * GIB)
            self.assertEqual((code, out), (0, want), path)


if __name__ == "__main__":
    unittest.main()
