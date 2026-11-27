#!/usr/bin/env python3
"""Turn a function zip into an image without running anything (the sample function of function/).

Stdlib only. Steps:
  composed  : the runtime image's layers (cross-repo mounted, not copied) + one layer
              holding the zip's files under function/  -> the pod's rootfs has /function
  code-only : one layer holding the zip's files at the root, no command, no OS
              -> mounted with volumes[].image
Usage:
  compose_image.py --registry http://127.0.0.1:5100 --zip code.zip --repo fn/t1/f1 --tag v1 \
      --mode composed --runtime runtime/python:3.12-slim
  compose_image.py --registry http://127.0.0.1:5100 --zip code.zip --repo fn/t1/f1-code --tag v1 --mode code-only
Prints MANIFEST_DIGEST=sha256:... on success.
"""
import argparse
import gzip
import hashlib
import io
import json
import stat
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile

MAX_FILES = 20_000
MAX_UNPACKED = 250 * 1024 * 1024

OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
OCI_LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
ACCEPT = ", ".join([OCI_MANIFEST, DOCKER_MANIFEST])


def http(method, url, data=None, headers=None, ok=(200, 201, 202)):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, dict(e.headers), e.read()
        raise SystemExit(f"HTTP {e.code} {method} {url}: {e.read()[:300]!r}")


def sha256(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def zip_to_tar(zip_path, prefix):
    """Check the zip as the upload would, and write its files into a deterministic tar."""
    buf = io.BytesIO()
    files = 0
    unpacked = 0
    with zipfile.ZipFile(zip_path) as z, tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        dirs = set()
        for info in z.infolist():
            name = info.filename
            mode = (info.external_attr >> 16) & 0o177777
            if stat.S_ISLNK(mode):
                raise SystemExit(f"REJECT symlink {name}")
            parts = name.rstrip("/").split("/")
            if name.startswith("/") or ".." in parts or "\\" in name:
                raise SystemExit(f"REJECT path {name}")
            if info.is_dir():
                continue
            files += 1
            if files > MAX_FILES:
                raise SystemExit("REJECT too many files")
            # count real bytes while reading: the size declared in the zip can lie
            data = bytearray()
            with z.open(info) as f:
                while chunk := f.read(1 << 20):
                    unpacked += len(chunk)
                    if unpacked > MAX_UNPACKED:
                        raise SystemExit("REJECT unpacked size")
                    data += chunk
            path = prefix + name
            for i in range(1, len(path.split("/"))):
                d = "/".join(path.split("/")[:i])
                if d and d not in dirs:
                    dirs.add(d)
                    ti = tarfile.TarInfo(d)
                    ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
                    t.addfile(ti)
            ti = tarfile.TarInfo(path)
            ti.size = len(data)
            ti.mode = 0o755 if mode & 0o111 else 0o644
            ti.mtime = 0
            t.addfile(ti, io.BytesIO(bytes(data)))
    return buf.getvalue(), files, unpacked


def push_blob(reg, repo, blob):
    digest = sha256(blob)
    st, _, _ = http("HEAD", f"{reg}/v2/{repo}/blobs/{digest}", ok=(200, 404))
    if st == 200:
        return digest
    _, h, _ = http("POST", f"{reg}/v2/{repo}/blobs/uploads/")
    loc = h["Location"]
    if loc.startswith("/"):
        loc = reg + loc
    sep = "&" if "?" in loc else "?"
    http("PUT", f"{loc}{sep}digest={digest}", data=blob,
         headers={"Content-Type": "application/octet-stream", "Content-Length": str(len(blob))})
    return digest


def mount_blob(reg, repo, digest, src_repo):
    st, _, _ = http("POST", f"{reg}/v2/{repo}/blobs/uploads/?mount={digest}&from={src_repo}")
    if st != 201:
        raise SystemExit(f"cross-repo mount of {digest} from {src_repo} returned {st}, not 201")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--registry", required=True)
    p.add_argument("--zip", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--mode", choices=["composed", "code-only"], required=True)
    p.add_argument("--runtime", help="repo:tag of the runtime image in the same registry (composed)")
    a = p.parse_args()
    reg = a.registry.rstrip("/")

    tar, files, unpacked = zip_to_tar(a.zip, "function/" if a.mode == "composed" else "")
    diff_id = sha256(tar)
    layer = gzip.compress(tar, mtime=0)
    print(f"CODE_LAYER files={files} unpacked={unpacked} tar={len(tar)} gz={len(layer)} diff_id={diff_id}")

    if a.mode == "composed":
        rt_repo, rt_tag = a.runtime.rsplit(":", 1)
        _, h, body = http("GET", f"{reg}/v2/{rt_repo}/manifests/{rt_tag}", headers={"Accept": ACCEPT})
        rt = json.loads(body)
        mt = rt["mediaType"]
        if mt not in (OCI_MANIFEST, DOCKER_MANIFEST):
            raise SystemExit(f"runtime tag must point at a single-platform manifest, got {mt}")
        _, _, cfg_body = http("GET", f"{reg}/v2/{rt_repo}/blobs/{rt['config']['digest']}")
        cfg = json.loads(cfg_body)
        if cfg.get("architecture") != "amd64":
            raise SystemExit(f"runtime is {cfg.get('architecture')}, not amd64")
        for l in rt["layers"]:
            mount_blob(reg, a.repo, l["digest"], rt_repo)
        cfg["rootfs"]["diff_ids"].append(diff_id)
        cfg.setdefault("history", []).append({"created": "1970-01-01T00:00:00Z", "created_by": "titan: function code layer"})
        cfg_blob = json.dumps(cfg, separators=(",", ":")).encode()
        layer_mt = DOCKER_LAYER if mt == DOCKER_MANIFEST else OCI_LAYER
        manifest = {
            "schemaVersion": 2,
            "mediaType": mt,
            "config": {"mediaType": rt["config"]["mediaType"], "digest": sha256(cfg_blob), "size": len(cfg_blob)},
            "layers": rt["layers"] + [{"mediaType": layer_mt, "digest": sha256(layer), "size": len(layer)}],
        }
    else:
        mt = OCI_MANIFEST
        cfg = {"architecture": "amd64", "os": "linux", "config": {},
               "rootfs": {"type": "layers", "diff_ids": [diff_id]},
               "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "titan: function code layer"}]}
        cfg_blob = json.dumps(cfg, separators=(",", ":")).encode()
        manifest = {
            "schemaVersion": 2,
            "mediaType": mt,
            "config": {"mediaType": OCI_CONFIG, "digest": sha256(cfg_blob), "size": len(cfg_blob)},
            "layers": [{"mediaType": OCI_LAYER, "digest": sha256(layer), "size": len(layer)}],
        }

    push_blob(reg, a.repo, layer)
    push_blob(reg, a.repo, cfg_blob)
    m_blob = json.dumps(manifest, separators=(",", ":")).encode()
    http("PUT", f"{reg}/v2/{a.repo}/manifests/{a.tag}", data=m_blob, headers={"Content-Type": mt})
    print(f"MANIFEST_DIGEST={sha256(m_blob)} layers={len(manifest['layers'])} mediaType={mt}")


if __name__ == "__main__":
    sys.exit(main())
