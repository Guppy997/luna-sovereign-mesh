# Luna Sovereign Mesh

A self-hosted, privacy-first AI infrastructure built on Kubernetes with a strict GitOps-only workflow. All secrets are encrypted before they touch version control — no plaintext credentials, ever.

## What This Project Is

Luna Sovereign Mesh is a personal infrastructure project with two goals:

1. **Run a private AI stack** (OpenClaw + custom PWA frontend) on a Raspberry Pi 5 at home — no data leaving the local network.
2. **Build it the right way** — reproducible, auditable, and secure from day one using the same patterns used in production platform engineering.

The Oracle Cloud ARM64 instance serves as a testing sandbox to validate the GitOps pipeline before deploying to the Pi.

## Architecture Overview

```
GitHub (encrypted GitOps repo)
        │ pull (outbound only)
        ▼
   Argo CD (GitOps operator, auto-sync + self-heal)
        │
        ▼
Kubernetes Cluster (k3s, ARM64)
├── Traefik          — Ingress, reachable from the tailnet only
├── cert-manager     — Certificate management
├── external-secrets — Sync decrypted secrets into the cluster
├── Kyverno          — Policy engine + policy reporter
├── Loki             — Log aggregation
├── kube-prometheus  — Metrics, dashboards & alerting
└── Homepage         — Self-hosted service dashboard (entry point)

Host services (outside Kubernetes)
├── Pi-hole + Unbound — Network-wide DNS filtering + recursive resolver
└── Tailscale         — Zero-trust mesh VPN: the only way in
```

## Security Design

### SOPS + Age for Secret Encryption

All Kubernetes secrets are encrypted with [Mozilla SOPS](https://github.com/getsops/sops) using [Age](https://github.com/FiloSottile/age) as the key provider before being pushed to GitHub.

**Why SOPS + Age over HashiCorp Vault?**

| | SOPS + Age | HashiCorp Vault |
|---|---|---|
| Infrastructure required | None — files are self-contained | Needs a running Vault server |
| GitOps compatibility | Native — encrypted files live in Git | Requires external secret sync |
| Operational overhead | Near-zero | High (HA, unsealing, backups) |
| Cost | Free, open-source | Free tier limited, OSS complex |

For a single-operator homelab, Vault's operational overhead outweighs its benefits. SOPS integrates directly into the GitOps flow: encrypt locally, push ciphertext, Argo CD + external-secrets decrypts at deploy time.

The Age private key is stored offline (not in this repository) and is the single credential required to recover the entire stack.

### What is encrypted

```
clusters/dev/secrets/*.yaml   ← AES256-GCM encrypted, Age-keyed
```

Metadata (Kubernetes resource names, namespaces) remains readable intentionally — only `data` and `stringData` fields are encrypted.

### What is never in Git

- Age private key
- `.env` file (plaintext credentials)
- Unencrypted secret drafts (`*.dec.yaml`, `*.plaintext.yaml`)

### Zero-Trust Network Access

The cluster is not reachable from the internet **or** from the local network — the LAN is treated as untrusted, the same way a corporate network would be in a zero-trust model.

- **Nothing is exposed to the internet.** No router port forwarding, no Tailscale Funnel. Argo CD only *pulls* from GitHub — there is no inbound path.
- **All access goes through the tailnet** (Tailscale, WireGuard-based). Services are reached via MagicDNS hostnames; HTTPS endpoints are published with Tailscale Serve.
- **LAN exposure is reduced to two ports:** DNS (53 — Pi-hole serves the home network) and SSH (22 — key-only, root login disabled) as a break-glass fallback.
- **Enforcement happens at two independent layers:**
  - *Kubernetes:* the Traefik LoadBalancer carries `loadBalancerSourceRanges: [100.64.0.0/10]`, enforced by kube-proxy in the kernel. NodePort allocation is disabled (`allocateLoadBalancerNodePorts: false`) — a deliberate choice, because NodePort traffic bypasses host firewalls entirely.
  - *Host:* UFW with a default-deny inbound policy covers everything that does not run in Kubernetes (SSH, Pi-hole, kubelet, node exporter).
- **Tailscale ACLs follow least privilege:** personal devices may reach the Pi; the tagged cloud node may not — traffic to the cloud sandbox is strictly one-way (Pi → cloud).
- **Split DNS:** Pi-hole forwards the tailnet DNS zone (`*.ts.net`) to MagicDNS, so service hostnames resolve consistently for every device in the house.

## Repository Structure

```
luna-sovereign-mesh/
├── .sops.yaml                  # Encryption rules — which files, which key
├── config.yaml                 # kubara cluster configuration
├── clusters/
│   └── dev/
│       ├── apps/               # Argo CD Application manifests
│       └── secrets/            # SOPS-encrypted Kubernetes secrets
├── infrastructure/             # Base infrastructure configs
└── scripts/
    └── sops-encrypt.sh         # Helper: encrypt a secret file in-place
```

## Toolchain

| Tool | Role | Why this one |
|---|---|---|
| [kubara](https://github.com/kubara-io/kubara) | Cluster scaffolding CLI | Opinionated GitOps-first bootstrap, reduces boilerplate |
| [Argo CD](https://argo-cd.readthedocs.io) | GitOps operator | Industry standard, declarative, Git as single source of truth |
| [SOPS](https://github.com/getsops/sops) | Secret encryption | Native Git integration, no external server needed |
| [Age](https://github.com/FiloSottile/age) | Encryption key provider | Modern, simple, no key server — single private key file |
| [Traefik](https://traefik.io) | Ingress controller | Lightweight, ARM-friendly, host-based routing |
| [Kyverno](https://kyverno.io) | Policy engine | Kubernetes-native, no sidecar proxies, YAML-based policies |
| [k3s](https://k3s.io) | Kubernetes distribution | Minimal footprint, built for ARM and edge devices |
| [Tailscale](https://tailscale.com) | Zero-trust network access | WireGuard mesh, ACLs, MagicDNS — no exposed ports |
| [Pi-hole](https://pi-hole.net) + [Unbound](https://nlnetlabs.nl/projects/unbound/) | DNS layer | Ad blocking + fully recursive resolution, no third-party DNS |

## Target Hardware

| Environment | Hardware | Purpose |
|---|---|---|
| Testing | Oracle Cloud VM (ARM64, free tier) | GitOps pipeline validation |
| Production | Raspberry Pi 5 (8GB) | Private AI inference + self-hosted services |

## Disaster Recovery

The full stack is recoverable from:
1. This GitHub repository (encrypted secrets included)
2. The Age private key (stored offline, separate from the repo)

Recovery steps on a new machine:
```bash
git clone https://github.com/Guppy997/luna-sovereign-mesh.git
# Restore Age private key to:
# ~/.config/sops/age/keys.txt
sops -d clusters/dev/secrets/kubara-env-secret.yaml
```

## Incident Postmortems

Things that broke, why they broke, and what changed as a result — written up
honestly because a single-node homelab is exactly where you learn this:

- [2026-06-12 — Argo CD controller OOMKill crash loop](docs/incidents/2026-06-12-argocd-oom-crashloop.md)
  (1,343 OOM kills in 8 days, undetected; node froze under memory pressure)

## Status

| Phase | Status |
|---|---|
| SOPS + Age encryption setup | Done |
| kubara cluster scaffolding | Done |
| Argo CD bootstrap | Done |
| Core services deployment | Done |
| Raspberry Pi migration | Done |
| Zero-trust network hardening (tailnet-only access) | Done |
| AI inference (Luna) deployment | In Progress |
| PWA Frontend deployment | Pending |
| Kyverno policies from audit to enforce mode | Planned |

## Running Services

All services are reachable exclusively from inside the tailnet, routed by Traefik via host-based rules on the node's MagicDNS name.

| Service | Access | Notes |
|---|---|---|
| Homepage | `http://<node>.<tailnet>.ts.net/` | Dashboard & entry point for all services |
| Grafana | `…/grafana` | Monitoring dashboards |
| Argo CD | `…/argocd` | GitOps operator |
| Alertmanager, Prometheus, Policy Reporter | tailnet ingress | Monitoring & policy backends |
| Pi-hole | Tailscale Serve (HTTPS) | DNS + ad blocking, runs on the host |
| Loki | ClusterIP only | Log aggregation, no external access |
