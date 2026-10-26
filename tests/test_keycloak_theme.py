#!/usr/bin/env python3
"""Tests for scripts/keycloak-theme.py — the theme files, the ConfigMap generator,
the volume items and the restart checksum must agree.

Run:  python3 tests/test_keycloak_theme.py
"""
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("keycloak_theme", os.path.join(HERE, "..", "scripts", "keycloak-theme.py"))
kt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kt)


def write(root, relative_path, content):
    path = os.path.join(root, relative_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = "wb" if isinstance(content, bytes) else "w"
    with open(path, mode) as handle:
        handle.write(content)


def kustomization(entries):
    lines = [
        "configMapGenerator:",
        "  - name: keycloak-theme-openvicloud",
        "    options:",
        "      disableNameSuffixHash: true",
        "    files:",
    ]
    for key, path in entries:
        lines.append(f"      - {key}=theme/openvicloud/{path}")
    return "\n".join(lines) + "\n"


def values(entries, checksum):
    lines = [
        "podAnnotations:",
        f'  checksum/openvicloud-theme: "{checksum}"',
        "extraVolumes: |",
        "  - name: theme-openvicloud",
        "    configMap:",
        "      name: keycloak-theme-openvicloud",
        "      items:",
    ]
    for key, path in entries:
        lines.append(f"        - key: {key}")
        lines.append(f"          path: {path}")
    return "\n".join(lines) + "\n"


class ThemeCheckTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/theme.properties", "parent=keycloak.v2\n")
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/resources/fonts/a.woff2", b"\x00\xff\x10")
        self.paths = ["login/resources/fonts/a.woff2", "login/theme.properties"]
        self.set_assets_version()

    def entries(self):
        return [(kt.key_for(path), path) for path in self.paths]

    def write_config(self, entries=None, checksum=None):
        if entries is None:
            entries = self.entries()
        if checksum is None:
            checksum = kt.checksum(self.root)
        write(self.root, "base/keycloak/realm-import/kustomization.yaml", kustomization(entries))
        write(self.root, "base/keycloak/values.yaml", values(entries, checksum))

    def test_consistent_config_has_no_problem(self):
        self.write_config()
        self.assertEqual(kt.problems(self.root), [])

    def test_changed_file_with_old_checksum_is_reported_with_the_right_checksum(self):
        self.write_config()
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/theme.properties", f"parent=keycloak.v2\novcAssetsVersion={kt.assets_version(self.root)}\nstyles=x\n")
        found = kt.problems(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn(kt.checksum(self.root), found[0])

    def test_checksum_changes_when_a_file_is_renamed(self):
        before = kt.checksum(self.root)
        os.rename(
            os.path.join(self.root, "base/keycloak/realm-import/theme/openvicloud/login/resources/fonts/a.woff2"),
            os.path.join(self.root, "base/keycloak/realm-import/theme/openvicloud/login/resources/fonts/b.woff2"),
        )
        self.assertNotEqual(before, kt.checksum(self.root))

    def test_file_missing_from_the_generator_is_reported(self):
        self.write_config()
        entries = self.entries()
        write(self.root, "base/keycloak/realm-import/kustomization.yaml", kustomization(entries[1:]))
        found = kt.problems(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn("login/resources/fonts/a.woff2", found[0])

    def test_file_missing_from_the_volume_items_is_reported(self):
        entries = self.entries()
        self.write_config()
        write(self.root, "base/keycloak/values.yaml", values(entries[:1], kt.checksum(self.root)))
        found = kt.problems(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn("login/theme.properties", found[0])

    def test_item_mapped_to_the_wrong_path_is_reported(self):
        entries = self.entries()
        wrong = [(entries[0][0], "login/resources/fonts/other.woff2"), entries[1]]
        self.write_config()
        write(self.root, "base/keycloak/values.yaml", values(wrong, kt.checksum(self.root)))
        self.assertNotEqual(kt.problems(self.root), [])

    def test_configmap_over_the_size_limit_is_reported(self):
        self.write_config()
        found = kt.problems(self.root, size_limit=10)
        self.assertEqual(len(found), 1)
        self.assertIn("bytes", found[0])

    def test_listed_file_that_no_longer_exists_is_reported(self):
        entries = self.entries() + [(kt.key_for("login/old.css"), "login/old.css")]
        self.write_config(entries=entries)
        found = kt.problems(self.root)
        self.assertEqual(len(found), 2)
        for problem in found:
            self.assertIn("login/old.css", problem)

    def test_binary_files_count_at_their_base64_size(self):
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/resources/fonts/a.woff2", b"\xff" * 300)
        self.set_assets_version()
        self.write_config()
        text_size = len(f"parent=keycloak.v2\novcAssetsVersion={kt.assets_version(self.root)}\n")
        # 300 raw bytes are 400 base64 bytes: a limit between the two must be exceeded.
        self.assertEqual(len(kt.problems(self.root, size_limit=text_size + 350)), 1)
        self.assertEqual(kt.problems(self.root, size_limit=text_size + 400), [])

    def test_resource_change_without_a_new_assets_version_is_reported_with_the_right_version(self):
        self.set_assets_version()
        self.write_config()
        self.assertEqual(kt.problems(self.root), [])
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/resources/fonts/a.woff2", b"\x01\x02")
        self.write_config()
        found = kt.problems(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn(kt.assets_version(self.root), found[0])

    def test_assets_version_ignores_files_outside_resources(self):
        before = kt.assets_version(self.root)
        write(self.root, "base/keycloak/realm-import/theme/openvicloud/login/messages/messages_en.properties", "a=b\n")
        self.assertEqual(before, kt.assets_version(self.root))

    def set_assets_version(self):
        write(
            self.root,
            "base/keycloak/realm-import/theme/openvicloud/login/theme.properties",
            f"parent=keycloak.v2\novcAssetsVersion={kt.assets_version(self.root)}\n",
        )

    def test_key_has_no_slash(self):
        self.assertNotIn("/", kt.key_for("login/resources/css/openvicloud.css"))


class RepositoryTest(unittest.TestCase):
    def test_repository_theme_is_consistent(self):
        repository = os.path.dirname(HERE)
        self.assertGreater(len(kt.theme_files(repository)), 0)
        self.assertEqual(kt.problems(repository), [])


if __name__ == "__main__":
    unittest.main()
