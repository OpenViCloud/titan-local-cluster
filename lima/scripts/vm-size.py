#!/usr/bin/env python3
"""Prints the `limactl edit` flags that bring an existing Lima VM to the cpus and memory of its Lima file.

Usage: limactl list --json VM | python3 vm-size.py <VM.yaml>
up.sh creates a VM from its file only once, so a new size in the file (docs/topology.md#ram-budget) never reaches a VM
that exists: up.sh stops the VM and runs `limactl edit VM <flags>` when this prints something. Prints nothing when the
VM already has the file's size. The file must hold top-level `cpus: <n>` and `memory: <n>GiB`, the form lima/*/ uses;
anything else exits 2, so a size the script cannot read never passes as a match.
Standard library only: python3 is all up.sh asks of the host.
"""
import json
import re
import sys

GIB = 1024 ** 3


def wanted(text):
    cpus = re.search(r"^cpus: (\d+)\s*$", text, re.M)
    memory = re.search(r"^memory: (\d+)GiB\s*$", text, re.M)
    missing = [key for key, found in (("cpus: <n>", cpus), ("memory: <n>GiB", memory)) if not found]
    if missing:
        raise ValueError("no top-level " + " or ".join(missing))
    return int(cpus.group(1)), int(memory.group(1))


def main():
    path = sys.argv[1]
    try:
        cpus, memory_gib = wanted(open(path).read())
    except ValueError as error:
        print(f"ERROR: {path}: {error}", file=sys.stderr)
        sys.exit(2)
    instance = json.loads(sys.stdin.readline())
    if instance.get("cpus") != cpus or instance.get("memory") != memory_gib * GIB:
        print(f"--cpus {cpus} --memory {memory_gib}")


if __name__ == "__main__":
    main()
