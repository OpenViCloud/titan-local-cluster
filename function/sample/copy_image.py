#!/usr/bin/env python3
"""Copy one linux/amd64 image from Docker Hub or GHCR into the function cluster's registry, stdlib only.
Usage: copy_image.py library/python:3.12-slim http://127.0.0.1:5100 runtime/python:3.12-slim
       copy_image.py ghcr.io/openvicloud/titan-function-runtimes/python3.15:<sha> http://127.0.0.1:5100 runtime/python3.15:<sha>
Docker Hub (the default) and GHCR are read anonymously; GHCR serves a public package without a login. An index is resolved to
its amd64 manifest, which is pushed as a single-platform manifest (compose_image.py needs that)."""
import json, sys, urllib.request
from compose_image import http, push_blob, sha256

src, reg, dst = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
dst_repo, dst_tag = dst.rsplit(":", 1)
if src.startswith("ghcr.io/"):
    src = src[len("ghcr.io/"):]
    repo, tag = src.rsplit(":", 1)
    tok = json.load(urllib.request.urlopen(f"https://ghcr.io/token?scope=repository:{repo}:pull"))["token"]
    hub = f"https://ghcr.io/v2/{repo}"
else:
    repo, tag = src.rsplit(":", 1)
    tok = json.load(urllib.request.urlopen(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"))["token"]
    hub = f"https://registry-1.docker.io/v2/{repo}"
H = {"Authorization": f"Bearer {tok}"}
ACC = ("application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, "
       "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")
_, _, body = http("GET", f"{hub}/manifests/{tag}", headers={**H, "Accept": ACC})
m = json.loads(body)
if "manifests" in m:
    d = next(x for x in m["manifests"] if x.get("platform", {}).get("architecture") == "amd64"
             and x["platform"].get("os") == "linux")
    _, _, body = http("GET", f"{hub}/manifests/{d['digest']}", headers={**H, "Accept": ACC})
    m = json.loads(body)
for b in [m["config"]] + m["layers"]:
    _, _, blob = http("GET", f"{hub}/blobs/{b['digest']}", headers=H)
    assert sha256(blob) == b["digest"], b["digest"]
    push_blob(reg, dst_repo, blob)
http("PUT", f"{reg}/v2/{dst_repo}/manifests/{dst_tag}", data=body, headers={"Content-Type": m["mediaType"]})
print(f"COPIED {src} -> {dst} manifest={sha256(body)} layers={len(m['layers'])} mediaType={m['mediaType']}")
