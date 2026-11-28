# function/ — the function cluster on the Ubuntu dev machine

A second, separate Kubernetes cluster on the dev machine, for the OVC Function service: Kata Containers with Firecracker
(`kata-fc`), Knative Serving and net-kourier, a code registry, and the function worker
([OpenViCloud/titan-function-worker](https://github.com/OpenViCloud/titan-function-worker)). The dev control plane knows it
as function cluster `local-function` (`FunctionClusters__0__Id` in `gitops/control-plane/kustomization.yaml`). It is not part of the dev cluster `local`
(`titan-k3s`, `titan-incus`); ArgoCD does not read this directory (it is outside `gitops/` and `base/`), and macOS has no
such cluster: Kata's `fc` shim needs KVM and exists for x86_64 only. Design: [docs/topology.md](../docs/topology.md#function-cluster).

It runs **on the host**, not in a Lima VM: a VM would nest KVM, and the cold start numbers would not be a real machine's.

| | |
|---|---|
| k3s API / kubelet | `:6444` / `:10350` on **every interface** of the host, not only loopback (k3s's default, and this host has no firewall on: `ufw` `ENABLED=no`); nearly every path needs credentials (`/cacerts` of the API answers without). Lima holds `6443`, `10250` on `127.0.0.1`; flannel `host-gw` (Lima holds UDP `8472`). k3s also listens on loopback ports of its own (`6445`, `10010`, `10248`…), none of them Lima's |
| Registry | `127.0.0.1:5100` (loopback only), images as `localhost:5100/<repo>@sha256:…` |
| Kubeconfig | `/etc/rancher/k3s/k3s.yaml`, a cluster-admin credential readable by every user of the host (mode 0644); the k3s installer also links `/usr/local/bin/kubectl` to `k3s`, so a bare `kubectl` with no `KUBECONFIG` talks to this cluster. Never apply with the dev cluster's kubeconfig (`~/.lima/titan-k3s/copied-from-guest/kubeconfig.yaml`) or a default `kubectl` context |
| Data | `/var/lib/fn-cluster` (thin pool 30 GiB + 2 GiB metadata on two sparse files, registry data) |
| Function worker | Namespace `titan-function-system`, one pod on the host's network: it reaches the dev control plane at `http://api.localhost:8080` (Lima forwards `titan-k3s`'s ingress to the host's `127.0.0.1:8080` only, [docs/network.md](../docs/network.md); `hostAliases` pins the name), `/healthz` on `:10390` of every interface. Its token is the control plane's internal token, `INTERNAL_TOKEN` of `secrets.env`; `up.sh` writes it into Secret `function-worker-secrets` through stdin. Image pinned by digest in `manifests/worker/deployment.yaml` (no `pull-images.py`: change the digest by a PR) |
| RAM | about 2 GiB with Knative idle. Lima's two VMs hold 9 of the host's 15 GiB, so `host-memory.sh` must say `OK` (`install.sh` and `up.sh` run it) |

## Run it

```bash
sudo bash function/host/install.sh      # once: thin pool, k3s (--secrets-encryption), kata-deploy (shim fc, devmapper)
bash function/up.sh                     # Knative 1.24.0, net-kourier, RuntimeClass kata-fc, registry, function worker; the local cluster first (secrets.env)
bash function/verify.sh                 # a sample function through the registry and Knative; PASS/FAIL per line
bash function/runtimes-verify.sh <sha>  # the runtime images of OpenViCloud/titan-function-runtimes (python3.15, nodejs26, go) at the full 40-hex commit <sha>, run as Knative Services and CronJobs
```

The last step of `install.sh` runs `systemctl disable k3s`, so k3s does not start at boot (the RAM belongs to the Lima VMs
first); `systemctl is-enabled k3s` says which it is. `sudo systemctl start k3s` brings the cluster back, and the thin pool with
it. `sudo systemctl stop k3s` ends the k3s server only (from the unit's `KillMode=process`: its containers keep running; `stop` itself was not run); `sudo k3s-killall.sh` is k3s's script to end the containers (whether it ends Kata pods, and what RAM it frees, are not measured). Remove everything the install put on the host:

```bash
sudo bash function/host/uninstall.sh
```

## What is where

- `host/install.sh`, `host/uninstall.sh`: the parts that need root.
- `manifests/worker`: the function worker (namespace, RBAC: list nodes, run pods in `titan-function-system`; Deployment).
- `manifests/crds`, `manifests/cluster`: kustomize. Knative and net-kourier are not copied here: the kustomizations download
  their release assets (tag-pinned) and `manifests/pins.txt` holds each file's SHA-256. `tests/test_function_cluster.py` (CI)
  checks it; `up.sh` does not, so a tag moved after the fact changes what `up.sh` applies and only CI turns red. net-kourier names `envoy:v1.37-latest`; the kustomization replaces it with a digest.
- `sample/`: a function (`hello/`), one sample function per runtime image of `titan-function-runtimes` (`runtimes/python`, `runtimes/node`, `runtimes/go`: `runtimes-verify.sh` zips and composes them) and the two stdlib-only scripts that turn a function into an image: `copy_image.py` puts a runtime
  image (amd64) into the registry (anonymous pull from Docker Hub, which rate-limits, or from `ghcr.io`, where the runtime packages are public), `compose_image.py` turns a zip into an image whose layers are the runtime's, mounted from
  its repository (HTTP 201, nothing copied), plus one layer with the zip's files under `/function`.
- `tests/test_function_cluster.py` (CI): render, pins, ports, and the gates of the scripts.

Network it uses: `get.k3s.io` and `github.com` (k3s installer and binary, Knative and net-kourier release assets), `ghcr.io` (kata-deploy chart, job image), `quay.io` (kata-deploy and kubectl images; the kubectl one is `latest`), `gcr.io` (Knative images), `docker.io` (k3s's mirrored system images, Envoy, `registry:2`, and `verify.sh`'s anonymous pull of `python:3.12-slim`), and for `runtimes-verify.sh` `ghcr.io` (the runtime images) and `github.com` (the Go sample is built against the public library at the given commit). Nothing is signed in.
