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
        │
        ▼
   Argo CD (GitOps operator)
        │
        ▼
Kubernetes Cluster (ARM64)
├── Traefik          — Ingress & TLS termination
├── cert-manager     — Automatic Let's Encrypt certificates
├── external-secrets — Sync SOPS-decrypted secrets into the cluster
├── Kyverno          — Policy enforcement (admission control)
├── Loki             — Log aggregation
├── kube-prometheus  — Metrics & alerting
├── oauth2-proxy     — SSO layer for internal services
└── homer-dashboard  — Self-hosted service dashboard
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
| [Traefik](https://traefik.io) | Ingress controller | Lightweight, ARM-friendly, automatic TLS via cert-manager |
| [Kyverno](https://kyverno.io) | Policy engine | Kubernetes-native, no sidecar proxies, YAML-based policies |
| [k3s](https://k3s.io) | Kubernetes distribution | Minimal footprint, built for ARM and edge devices |

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

## Status

| Phase | Status |
|---|---|
| SOPS + Age encryption setup | Done |
| kubara cluster scaffolding | Done |
| Argo CD bootstrap | Done |
| Core services deployment | Done |
| Raspberry Pi migration | Done |
| AI inference (Luna) deployment | In Progress |
| PWA Frontend deployment | Pending |

## Running Services

| Service | Access | Notes |
|---|---|---|
| Argo CD | `http://<pi-ip>:30681/argocd` | GitOps operator |
| Grafana | `http://<pi-ip>:32518` | Monitoring dashboards |
| Pi-hole | `http://<pi-ip>:8081/admin` | DNS + ad blocking |
| Prometheus | ClusterIP only | Metrics backend |
| Loki | ClusterIP only | Log aggregation |
| Traefik | Port 80/443 | Ingress controller |
