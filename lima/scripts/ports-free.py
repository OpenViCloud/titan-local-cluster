#!/usr/bin/env python3
"""Stops when a host port of a Lima VM is already held.

Reads `limactl list --json VM` on stdin, whose config.portForwards Lima has already filled in (hostIP, and a missing
hostPort means the guest port). When another cluster holds one of those ports, Lima only warns it cannot listen and starts
the VM anyway; up.sh would then talk to the other cluster. Exits 1 naming every held port, 0 (silent) when all are free.
Standard library only: python3 is all up.sh asks of the host.
"""
import errno
import json
import socket
import sys


def held(rules):
    out = []
    for rule in rules:
        if rule.get("ignore") or "guestPortRange" in rule and "guestPort" not in rule:
            continue
        host_ip = rule.get("hostIP") or "127.0.0.1"
        port = rule.get("hostPort") or rule.get("guestPort")
        if not port:
            continue
        with socket.socket(socket.AF_INET6 if ":" in host_ip else socket.AF_INET) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((host_ip, port))
            except OSError as e:
                out.append((host_ip, port, "in use" if e.errno == errno.EADDRINUSE else e.strerror))
    return out


def main():
    instance = json.loads(sys.stdin.readline())
    found = held(instance.get("config", {}).get("portForwards", []))
    for host_ip, port, why in found:
        print(f"ERROR: {instance.get('name', 'this VM')} needs {host_ip}:{port}, which is {why}: another local cluster "
              f"(another user's, another LIMA_HOME's, or these VMs started elsewhere) or another program holds it. "
              f"Stop it (bash lima/scripts/down.sh where it was started), then run up.sh again.", file=sys.stderr)
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
