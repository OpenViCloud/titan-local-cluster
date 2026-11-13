#!/usr/bin/env python3
r"""Prints the `limactl edit --set` expressions that bring an existing Lima VM's provision scripts to its Lima file's.

Usage: limactl list --json VM | python3 vm-provision.py <VM.yaml>
`limactl create` copies each `file:` provision script into the instance (~/.lima/VM/lima.yaml), and every boot runs
that copy, so a change to lima/provision/*.sh never reaches a VM that exists (docs/topology.md#provision-sync). Prints
one expression per line, one per script that differs, for up.sh to pass as `--set` to `limactl edit` on the stopped
VM; nothing when every script matches. The script goes in as base64 decoded by yq (`@base64d`): Lima's yq unescapes a
quoted string twice, so a JSON string would turn `\\` into `\` and keep `\u001b` as text.
Lima puts provision scripts of its own before the file's (the LLMNR one of its debian-13 template), both in
`limactl list --json` and in the instance file `limactl edit` changes, so the file's n scripts are compared with the
instance's last n.
The file's provision must be entries of the form lima/*/ uses (`- mode: <mode>`, `file:`, `url: <path>` relative to
the file), up to the next top-level key; anything else, a blank or comment line among them too, exits 2, so a
provision the script cannot read never passes as a match.
Standard library only: python3 is all up.sh asks of the host.
"""
import base64
import json
import pathlib
import re
import sys

ENTRY = re.compile(r"- mode: (\S+)\n  file:\n    url: (\S+)\n")


def wanted(path):
    """[(mode, script)] of the Lima file's provision, in order."""
    text = path.read_text()
    block = re.search(r"^provision:\n((?:(?![A-Za-z]).*\n)*)", text, re.M)
    if not block:
        raise ValueError("no top-level provision:")
    entries = []
    rest = block.group(1).rstrip("\n") + "\n"
    while rest:
        entry = ENTRY.match(rest)
        if not entry:
            raise ValueError(f"provision entry not of the form '- mode:, file:, url:': {rest.splitlines()[0]!r}")
        entries.append((entry.group(1), (path.parent / entry.group(2)).read_text()))
        rest = rest[entry.end():]
    return entries


def main():
    path = pathlib.Path(sys.argv[1])
    try:
        entries = wanted(path)
    except (ValueError, OSError) as error:
        print(f"ERROR: {path}: {error}", file=sys.stderr)
        sys.exit(2)
    current = json.loads(sys.stdin.readline()).get("config", {}).get("provision") or []
    offset = len(current) - len(entries)
    if offset < 0:
        print(f"ERROR: the VM has {len(current)} provision scripts, {path} has {len(entries)}", file=sys.stderr)
        sys.exit(2)
    for i, (mode, script) in enumerate(entries):
        have = current[offset + i]
        if have.get("mode") != mode:
            print(f"ERROR: provision[{offset + i}] of the VM is mode {have.get('mode')}, {path} says {mode}",
                  file=sys.stderr)
            sys.exit(2)
        if have.get("script") != script:
            encoded = base64.b64encode(script.encode()).decode()
            print(f'.provision[{offset + i}].script = ("{encoded}" | @base64d)')


if __name__ == "__main__":
    main()
