#!/usr/bin/env python3
"""Check that the Keycloak login theme files, the ConfigMap generator, the volume items,
the restart checksum and the stylesheet version agree
(https://github.com/OpenViCloud/titan-ops/blob/main/docs/architecture/platform-infra.md#keycloak-theme).

  python3 scripts/keycloak-theme.py --check    # exit 1 and list each problem
  python3 scripts/keycloak-theme.py --print    # the checksum and the lines to paste
"""
import argparse
import base64
import hashlib
import os
import re
import sys

THEME_DIR = "base/keycloak/realm-import/theme/openvicloud"
KUSTOMIZATION = "base/keycloak/realm-import/kustomization.yaml"
VALUES = "base/keycloak/values.yaml"
ANNOTATION = "checksum/openvicloud-theme"
THEME_PROPERTIES = "login/theme.properties"
RESOURCES = "login/resources/"
# ArgoCD applies client-side, so the whole ConfigMap is copied into the last-applied-configuration
# annotation, and annotations hold at most 256 KiB. Binary files are stored base64, a third larger.
CONFIGMAP_LIMIT = 200 * 1024


def theme_files(root):
    base = os.path.join(root, THEME_DIR)
    found = []
    for directory, _, names in os.walk(base):
        for name in names:
            full_path = os.path.join(directory, name)
            found.append(os.path.relpath(full_path, base).replace(os.sep, "/"))
    found.sort()
    return found


def key_for(path):
    return path.replace("/", "__")


def checksum(root):
    digest = hashlib.sha256()
    for path in theme_files(root):
        with open(os.path.join(root, THEME_DIR, path), "rb") as handle:
            content = handle.read()
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(content)
        digest.update(b"\0")
    return digest.hexdigest()


def assets_version(root):
    """Version of the files under login/resources/; the template appends it to the theme's
    stylesheet and favicon URLs, because Keycloak lets browsers cache static files for 30 days under an unchanged URL."""
    digest = hashlib.sha256()
    for path in theme_files(root):
        if not path.startswith(RESOURCES):
            continue
        with open(os.path.join(root, THEME_DIR, path), "rb") as handle:
            content = handle.read()
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(content)
        digest.update(b"\0")
    return digest.hexdigest()[:12]


def declared_assets_version(root):
    path = os.path.join(root, THEME_DIR, THEME_PROPERTIES)
    if not os.path.exists(path):
        return None
    with open(path) as handle:
        match = re.search(r"^ovcAssetsVersion=(\S*)\s*$", handle.read(), re.MULTILINE)
    if match is None:
        return None
    return match.group(1)


def stored_size(root):
    total = 0
    for path in theme_files(root):
        with open(os.path.join(root, THEME_DIR, path), "rb") as handle:
            content = handle.read()
        try:
            content.decode("utf-8")
            total += len(content)
        except UnicodeDecodeError:
            total += len(base64.b64encode(content))
    return total


def read_text(root, relative_path):
    with open(os.path.join(root, relative_path)) as handle:
        return handle.read()


def generator_entries(root):
    text = read_text(root, KUSTOMIZATION)
    prefix = "theme/openvicloud/"
    entries = {}
    for key, source in re.findall(r"^\s*-\s*([A-Za-z0-9._-]+)=(\S+)\s*$", text, re.MULTILINE):
        if source.startswith(prefix):
            entries[key] = source[len(prefix):]
    return entries


def volume_items(root):
    text = read_text(root, VALUES)
    items = {}
    for key, path in re.findall(r"-\s*key:\s*(\S+)\s*\n\s*path:\s*(\S+)", text):
        items[key] = path
    return items


def annotation_value(root):
    text = read_text(root, VALUES)
    match = re.search(r'^\s*' + re.escape(ANNOTATION) + r':\s*"?([0-9a-f]*)"?\s*$', text, re.MULTILINE)
    if match is None:
        return None
    return match.group(1)


def mapping_problems(name, found, expected):
    problems = []
    for key, path in sorted(expected.items()):
        if key not in found:
            problems.append(f"{name} lacks {path} (key {key})")
        elif found[key] != path:
            problems.append(f"{name} maps key {key} to {found[key]}, expected {path}")
    for key in sorted(set(found) - set(expected)):
        problems.append(f"{name} has key {key} for {found[key]}, which is not a theme file")
    return problems


def problems(root, size_limit=CONFIGMAP_LIMIT):
    expected = {key_for(path): path for path in theme_files(root)}
    found = []
    found.extend(mapping_problems(KUSTOMIZATION + " configMapGenerator", generator_entries(root), expected))
    found.extend(mapping_problems(VALUES + " volume items", volume_items(root), expected))
    wanted = checksum(root)
    stored = annotation_value(root)
    if stored != wanted:
        found.append(f"{VALUES} {ANNOTATION} is {stored!r}, the theme files give \"{wanted}\"")
    wanted_version = assets_version(root)
    declared_version = declared_assets_version(root)
    if declared_version != wanted_version:
        found.append(f"{THEME_DIR}/{THEME_PROPERTIES} ovcAssetsVersion is {declared_version!r}, the resource files give \"{wanted_version}\"")
    size = stored_size(root)
    if size > size_limit:
        found.append(f"theme ConfigMap would hold {size} bytes, over the {size_limit} bytes limit")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--print", action="store_true", dest="print_lines")
    arguments = parser.parse_args()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if arguments.print_lines:
        print(f"ovcAssetsVersion={assets_version(root)}")
        print(f'{ANNOTATION}: "{checksum(root)}"')
        print(f"stored size: {stored_size(root)} bytes")
        for path in theme_files(root):
            print(f"generator: - {key_for(path)}=theme/openvicloud/{path}")
        for path in theme_files(root):
            print(f"item: - key: {key_for(path)} / path: {path}")
        return 0

    found = problems(root)
    for problem in found:
        print(problem)
    if found:
        return 1
    print(f"theme consistent: {len(theme_files(root))} files, checksum {checksum(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
