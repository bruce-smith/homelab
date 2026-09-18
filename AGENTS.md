# AGENTS.md — Homelab Repo

## Repo identity

Declarative config for a **3-node NixOS k3s homelab** (node0/1/2) plus two Kubernetes services deployed via Helmfile (Hermes agent + cluster-ops pod).  
**PUBLIC** at `github.com/bruce-smith/homelab` — never commit credentials, internal IPs, or phone numbers.

## File layout (high-level)

```
flake.nix                   # builds node0/node1/node2 NixOS systems
hosts/<node>/               # per-node configuration.nix + hardware-config
modules/                    # shared NixOS modules (k3s, tailscale, ad)
secrets/                    # sops-encrypted (sops-nix consumes at activation)
helm/                       # k3s service definitions
  helmfile.yaml             # release order + hooks (MUST be run FROM this dir)
  charts/hermes/            # local chart: Hermes agent + rclone sidecar
  charts/ops/               # local chart: in-cluster ops toolkit (sshd)
  values/                   # sops-encrypted Secret manifests for presync hooks
  manifests/                # static K8s manifests (homepage-config, ingress, CRDs)
ops/                        # Dockerfile + entrypoint for the cluster-ops image
```

## What requires the main PC (cat126@100.69.174.71 via Tailscale)

- `git push origin main` — HTTPS needs wincredman (interactive desktop); use `schtasks /Create /IT`
- Docker Desktop GUI (start clicks not available from headless SSH) — image builds moved to node0 podman

Everything else works from the cluster or nodes directly.

## Cluster management flow

**Helmfile** — from `C:\Users\cat126\source\repos\homelab\helm\`:
```bat
set PATH=%PATH%;C:\Program Files\Git\bin  (or presync hooks calling `sh` will fail)
helmfile -e default apply -l name=<release>
```
- Presync hooks run **before** helm creates the namespace; hooks that apply namespaced Secrets must create the namespace first.
- Never run two concurrent helmfile applies (OCI chart cache lock causes hangs).
- For pure ConfigMap changes: `kubectl apply -f path && kubectl rollout restart deploy/<name> -n <ns>` (cheaper than helmfile).

**NixOS node rebuilds** (from any node with Nix + this repo):
```bash
nixos-rebuild switch --flake .#node0 --target-host node0@node0
```
- SSH alias `node0` = node0@192.168.3.126 (also `node1` @.166, `node2` @.189).
- Nodes use `linuxPackages_latest` (kernel 7.2.x).
- AD join uses **adcli** (`realm` has no dbus on NixOS).

**sops**:
- `.sops.yaml` creation rules: `helm/values/*.sops.yaml` and `secrets/*.yaml`.
- Write the PLAINTEXT at the final `*.sops.yaml` path then `sops -e -i <path>`. The `-i` flag encrypts in place. Writing to a temp location then moving breaks the creation-rule match.

## Helm template gotcha

Templates are valid Go templating (`{{ .Values.x }}`) which is **not valid YAML**. `write_file`/`patch` refuse to write them. Edit via Python on the PC:
```python
p = r"C:\Users\cat126\source\repos\homelab\helm\charts\<name>\templates\<file>.yaml"
t = open(p).read()
assert t.count(old) == 1
open(p, 'w').write(t.replace(old, new))
```
Verify with `git status <file>` and `helm template <release> ./charts/chart` (git works; helm template catches render errors).

## In-cluster ops pod (no PC needed)

```bash
ssh root@ops.ops.svc.cluster.local kubectl get nodes        # 3 nodes visible
ssh root@ops.ops.svc.cluster.local helmfile -e default list  # all releases
ssh root@ops.ops.svc.cluster.local sops -d path/secret.yaml  # age keys mounted
ssh root@ops.ops.svc.cluster.local nix run ...               # has Nix (nixos-anywhere)
```
The entrypoint is ConfigMap-mounted (`templates/configmap-entrypoint.yaml`); script changes need:
1. Update `ops/entrypoint.sh`
2. Regenerate the ConfigMap template (`ops_entrypoint_cm.py` on the PC)
3. `kubectl apply -f helm/charts/ops/templates/configmap-entrypoint.yaml`
4. `kubectl rollout restart deploy/ops -n ops`

The image builds on **node0 with podman** (fmt: skopeo → docker-archive → `ctr images import`).  
Never use `nixpkgs#helm` (it resolves to ancient 0.9.0); use `nixpkgs#kubernetes-helm`.

## Hermes agent pod (the cluster's AI assistant)

- Namespace `hermes-system`. Longhorn PVCs: `hermes-data` (agent state, 10Gi), `hermes-gdrive` (Drive mirror, 5Gi), `hermes-bisync-state` (bisync listings, 1Gi).
- SSH key for operator access: `/opt/data/.ssh/id_ed25519` — **chmod 600 after every pod restart** (fsGroup resets mode to 0660 and OpenSSH refuses it).
- `HERMES_WRITE_SAFE_ROOT=/opt/data:/mnt/gdrive` — the Drive mirror is writable; bisync syncs both ways.
- Cron timezone: `TZ=America/Chicago` on the container. If a daily job's `next_run_at` drifts to UTC, pause/resume it to recompute.

## Bisync (rclone sidecar)

- Filters live in `/state/filters.txt` (persistent PVC) — **not** `/work/` (emptyDir).
- Legacy root-owned listing files in `/state/bisync/` cause `chmod: operation not permitted` → resync loop. Fix:
  ```bash
  kubectl exec deploy/hermes -c rclone -- rm -f /state/bisync/gdrive_*.* /state/initialised
  ```
  Next loop iteration runs a fresh resync (uid 1000, clean).
- The filters `.md5` hash is written next to the filters file; it survives restarts because it is in `/state`.
