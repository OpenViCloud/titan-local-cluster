#!/usr/bin/env python3
"""The two deployments of the local cluster: lima/macos/ and lima/ubuntu/ hold the two Lima VM files and a link to
the shared lima/provision; everything else under lima/ is shared, and what differs by OS beyond the VM files is in the
branches of lima/scripts/host-os.sh, which lima/scripts/up.sh asks with `uname -s`.

What differs on Ubuntu (docs/network.md#vm-to-vm):
no user-v2 network, so the Incus API and SeaweedFS's NodePort reach titan-k3s and titan-incus through the host's
127.0.0.1, and Lima's host resolver answers dev's S3 name.

Run:  python3 tests/test_lima_files.py     (needs ruby: python's stdlib reads no YAML)
"""
import json
import pathlib
import subprocess
import unittest

LIMA = pathlib.Path(__file__).resolve().parent.parent / "lima"
VMS = ("titan-incus", "titan-k3s")
S3_NAME = "lima-titan-k3s.internal"


def vm(os_dir, name):
    path = LIMA / os_dir / (name + ".yaml")
    as_json = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"],
                             input=path.read_text(), capture_output=True, text=True, check=True).stdout
    return json.loads(as_json)


def forwards(spec):
    return [f for f in spec.get("portForwards", []) if not f.get("ignore")]


def host_os(function, *args):
    out = subprocess.run(["bash", "-c", 'source "$1"; shift; "$@"', "_", str(LIMA / "scripts" / "host-os.sh"), function, *args],
                         capture_output=True, text=True)
    return out.returncode, out.stdout.strip()


def vm_dir(uname):
    return host_os("vm_dir", uname)


class Layout(unittest.TestCase):
    def test_each_os_folder_holds_the_two_vm_files_and_a_link_to_the_shared_provision(self):
        # Lima refuses a relative provision path with '..' in it, so each folder links lima/provision.
        for os_dir in ("macos", "ubuntu"):
            folder = LIMA / os_dir
            self.assertEqual(sorted(p.name for p in folder.iterdir()), ["provision", "titan-incus.yaml", "titan-k3s.yaml"])
            self.assertTrue((folder / "provision").is_symlink())
            self.assertEqual((folder / "provision").readlink(), pathlib.Path("../provision"))

    def test_both_deployments_run_the_same_provision_script(self):
        for name in VMS:
            scripts = set()
            for os_dir in ("macos", "ubuntu"):
                urls = [p["file"]["url"] for p in vm(os_dir, name)["provision"]]
                self.assertEqual(len(urls), 1)
                self.assertNotIn("..", pathlib.PurePosixPath(urls[0]).parts, (os_dir, name))
                target = (LIMA / os_dir / urls[0]).resolve()
                self.assertTrue(target.is_file(), target)
                scripts.add(target)
            self.assertEqual(len(scripts), 1, scripts)

    def test_same_cpus_memory_disk_and_mounts(self):
        for name in VMS:
            mac, ubuntu = vm("macos", name), vm("ubuntu", name)
            for key in ("cpus", "memory", "disk", "mounts"):
                self.assertEqual(mac.get(key), ubuntu.get(key), (name, key))


class MacOS(unittest.TestCase):
    def test_vz_on_user_v2(self):
        for name in VMS:
            spec = vm("macos", name)
            self.assertEqual(spec["vmType"], "vz")
            self.assertEqual(spec["networks"], [{"lima": "user-v2"}])


class Ubuntu(unittest.TestCase):
    def test_qemu_without_user_v2(self):
        # QEMU 10.2 aborts under load on user-v2's socket NIC (net_socket_send passes -1 on EWOULDBLOCK).
        for name in VMS:
            spec = vm("ubuntu", name)
            self.assertEqual(spec["vmType"], "qemu")
            self.assertNotIn("networks", spec)

    def test_base_brings_no_home_mount(self):
        # template:<os> also merges template:_default/mounts (the user's home, read-only) into the VM.
        for name in VMS:
            self.assertTrue(vm("ubuntu", name)["base"].startswith("template:_images/"), name)

    def test_incus_api_reaches_the_host_on_loopback_only(self):
        self.assertIn({"guestIP": "192.168.5.15", "guestPort": 8443, "hostIP": "127.0.0.1", "hostPort": 8443},
                      forwards(vm("ubuntu", "titan-incus")))

    def test_seaweedfs_nodeport_reaches_the_host_on_loopback_only(self):
        self.assertIn({"guestPort": 30833, "hostIP": "127.0.0.1", "hostPort": 30833}, forwards(vm("ubuntu", "titan-k3s")))

    def test_every_forward_binds_loopback(self):
        for name in VMS:
            for f in forwards(vm("ubuntu", name)):
                self.assertEqual(f.get("hostIP", "127.0.0.1"), "127.0.0.1", (name, f))

    def test_s3_name_resolves_to_seaweedfs_from_both_vms(self):
        # titan-k3s answers it itself; titan-incus reaches it through the host (Lima's 192.168.5.2 is the host's 127.0.0.1).
        self.assertEqual(vm("ubuntu", "titan-k3s")["hostResolver"]["hosts"], {S3_NAME: "192.168.5.15"})
        self.assertEqual(vm("ubuntu", "titan-incus")["hostResolver"]["hosts"], {S3_NAME: "192.168.5.2"})


class VmDir(unittest.TestCase):
    def test_darwin_is_macos(self):
        self.assertEqual(vm_dir("Darwin"), (0, str(LIMA / "macos")))

    def test_linux_is_ubuntu(self):
        self.assertEqual(vm_dir("Linux"), (0, str(LIMA / "ubuntu")))

    def test_another_os_stops(self):
        code, out = vm_dir("FreeBSD")
        self.assertNotEqual(code, 0)
        self.assertEqual(out, "")


class IncusEndpoint(unittest.TestCase):
    # What the control plane in titan-k3s dials for titan-incus, from the API address Incus listens on there.
    def test_macos_dials_the_user_v2_address(self):
        self.assertEqual(host_os("incus_endpoint", "Darwin", "192.168.104.1:8443"), (0, "https://192.168.104.1:8443"))

    def test_ubuntu_dials_the_host_forward(self):
        self.assertEqual(host_os("incus_endpoint", "Linux", "192.168.5.15:8443"), (0, "https://192.168.5.2:8443"))

    def test_ubuntu_forward_is_the_port_incus_listens_on(self):
        port = [f["hostPort"] for f in forwards(vm("ubuntu", "titan-incus")) if f["guestPort"] == 8443]
        self.assertEqual(port, [8443])

    def test_another_os_or_no_address_stops(self):
        self.assertEqual(host_os("incus_endpoint", "FreeBSD", "10.0.0.1:8443")[1], "")
        self.assertNotEqual(host_os("incus_endpoint", "FreeBSD", "10.0.0.1:8443")[0], 0)
        self.assertNotEqual(host_os("incus_endpoint", "Linux", "")[0], 0)


class ClusterSpec(unittest.TestCase):
    SPEC = LIMA / "regression-runner" / "z1" / "z1-cluster.spec.ts"

    def test_no_copy_of_lib_local_proxy(self):
        # run-module.sh of titan-regression loads lib/ and the module into one ConfigMap: a second local-proxy.ts is refused.
        self.assertFalse((self.SPEC.parent / "local-proxy.ts").exists())


if __name__ == "__main__":
    unittest.main()
