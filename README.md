# Luna Sovereign Mesh

A self-hosted, privacy-first AI infrastructure built on Kubernetes with a strict GitOps-only workflow. All secrets are encrypted before they touch version control — no plaintext credentials, ever.

> **Short on time?** The [incident postmortems](#incident-postmortems) are the most representative part of this repo — seven write-ups of things that actually broke on a single-node cluster, with the numbers and the fixes. Start with [the Argo CD OOM crash loop](docs/incidents/2026-06-12-argocd-oom-crashloop.md) (1,343 OOM kills nobody noticed) or [the thermal cascade](docs/incidents/2026-06-20-thermal-throttle-cascade-crashloop.md) (85.6 °C → every pod loses the API at once). For the design reasoning instead, go to [docs/security.md](docs/security.md).

## Contents

- [What This Project Is](#what-this-project-is)
- [Architecture Overview](#architecture-overview)
- [Security](#security)
- [Toolchain](#toolchain)
- [Repository Structure](#repository-structure)
- [Target Hardware](#target-hardware)
- [Status](#status)
- [Running Services](#running-services)
- [Incident Postmortems](#incident-postmortems)

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
├── Homepage         — Self-hosted service dashboard (entry point)
│
├── Productivity
│   ├── Plane          — Project management (Jira alternative)
│   ├── Affine         — Knowledge base & docs (Notion alternative)
│   ├── Beaver Habits  — Habit tracker
│   ├── Beszel         — Lightweight server resource dashboard
│   └── Vaultwarden    — Password manager (Bitwarden-compatible)
│
└── AI Stack
    ├── Luna Dashboard — Custom PWA frontend for OpenClaw
    └── OpenClaw       — AI assistant backend (Oracle Cloud, via Tailscale)

Host services (outside Kubernetes)
├── Pi-hole + Unbound — Network-wide DNS filtering + recursive resolver
├── Tailscale         — Zero-trust mesh VPN: the only way in
└── cron (daily 03:00) — USB backup: DBs, secrets, file uploads
                         (credentials age-encrypted, 14-day retention)
```

## Security

Secrets are encrypted at rest with [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age) — no external secret server, ciphertext lives directly in Git. The cluster is unreachable from the internet or the local network; all access goes through a [Tailscale](https://tailscale.com) zero-trust tailnet, enforced at both the Kubernetes (`loadBalancerSourceRanges`) and host (UFW default-deny) layers.

Full design rationale (SOPS vs. Vault tradeoffs, zero-trust network enforcement, disaster recovery, backup strategy) → **[docs/security.md](docs/security.md)**

That "no plaintext credentials" claim is enforced, not just stated: [`.github/workflows/validate.yml`](.github/workflows/validate.yml) fails any pull request that adds an unencrypted file under `secrets/`, or that carries a private key or token anywhere else in the tree. It runs on Renovate's own pull requests too — those are set to auto-merge patch updates, and Argo CD auto-syncs, so this check is the last place a human decision is encoded before a change reaches the running cluster.

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

## Repository Structure

```
luna-sovereign-mesh/
├── .sops.yaml                  # Encryption rules — which files, which key
├── .github/workflows/          # PR validation (see below)
├── config.yaml                 # kubara cluster configuration
├── clusters/
│   └── dev/
│       ├── apps/               # Argo CD Application manifests
│       └── secrets/            # SOPS-encrypted Kubernetes secrets
├── infrastructure/             # Base infrastructure configs
├── docs/                       # Architecture deep-dives & incident postmortems
└── scripts/
    └── sops-encrypt.sh         # Helper: encrypt a secret file in-place
```

## Target Hardware

| Environment | Hardware | Purpose |
|---|---|---|
| Testing | Oracle Cloud VM (ARM64, free tier) | GitOps pipeline validation |
| Production | Raspberry Pi 5 (8GB) | Private AI inference + self-hosted services |

## Status

Production-ready and in active use — core platform (GitOps, zero-trust networking, secrets, monitoring) is done; the AI stack and productivity apps run daily. 170 commits, 17 Argo CD applications, continuously in operation since June 2026 on a single node.

**Recently shipped:**

- **Monitoring gap closed** — node-exporter was deployed but never scraped, so 26 host-level alert rules (CPU, RAM, disk, temperature) had been silently evaluating against no data. Found by auditing alert rules against live targets rather than trusting a green dashboard.
- **Backup consolidation** — three overlapping backup paths merged into one script; credentials encrypted with age before they touch the USB medium; **restore verified end-to-end** for the first time, not just assumed.
- **Housekeeping** — journald capped (was unbounded at 10% of disk), unattended-upgrade reports moved from a non-existent MTA to ntfy, a failing `unbound-resolvconf` unit retired.

**Up next:** off-site copy of the encrypted backup set (currently single-medium), re-raise Prometheus retention now that thermal headroom exists, disable Tailscale node-key expiry before it triggers.

## Running Services

All services are reachable exclusively from inside the tailnet, routed by Traefik via host-based rules on the node's MagicDNS name.

| Service | Port | Notes |
|---|---|---|
| Lern-PWA | `https://…:10000` | Learning tracker, runs on the host (port 8090) |
| Homepage | `https://…:10001` (root) | Dashboard & entry point for all services |
| ArgoCD | `…:10001/argocd` | GitOps operator |
| Pi-hole | `https://…:10002/admin` | DNS + ad blocking, runs on the host |
| ntfy | `https://…:10003` | Self-hosted push notifications, fed by Alertmanager |
| Luna Dashboard | `https://…:10004` | AI assistant frontend (OpenClaw PWA) |
| Plane | `https://…:10005` | Project management (Jira alternative) |
| Vaultwarden | `https://…:10006` | Password manager (Bitwarden-compatible) |
| Affine | `https://…:10007` | Knowledge base & docs (Notion alternative) |
| Beszel | `https://…:10008` | Lightweight server resource monitoring |
| Beaver Habits | `https://…:10009` | Habit tracker |
| Grafana | `…:10001/grafana` | Monitoring dashboards |
| Prometheus | `…:10001/prometheus` | Metrics & alerting |
| Home Assistant | `https://…:10010` | Smart home, runs on the host (port 8123) |
| Fitness-PWA | `https://…:10011` | Gym tracker, runs on the host (port 8091) |

The `tailscale serve` port map is not GitOps-managed — after a state loss, restore it with [`scripts/apply-tailscale-serve.sh`](scripts/apply-tailscale-serve.sh) (source of truth for the mapping).

## Incident Postmortems

Things that broke, why they broke, and what changed as a result — written up
honestly because a single-node homelab is exactly where you learn this:

- [2026-06-12 — Argo CD controller OOMKill crash loop](docs/incidents/2026-06-12-argocd-oom-crashloop.md)
  (1,343 OOM kills in 8 days, undetected; node froze under memory pressure)
- [2026-06-15 — Prometheus retention reduced from 10d to 7d](docs/incidents/2026-06-15-prometheus-retention-tuning.md)
  (proactive tuning after OOM postmortem: ~750Mi RSS against 800Mi limit with no size cap; 3-line GitOps fix, deployed without downtime)
- [2026-06-16 — Forced reboot → kubara network crash & silent state corruption](docs/incidents/2026-06-16-forced-reboot-network-recovery.md)
  (CNI race condition on restart; DNS integration and Pi-hole blocking silently broken; why automated recovery is a deliberate non-goal on single-node hardware)
- [2026-06-20 — Thermal throttling → K3s API freeze → cascade pod crashloop](docs/incidents/2026-06-20-thermal-throttle-cascade-crashloop.md)
  (85.6 °C SoC temp, CPU throttled, all pods lost API connectivity simultaneously; Prometheus/Loki/Kyverno temporarily disabled as mitigation — resolved 2026-06-29)
- [2026-06-29 — Cooling upgrade + resource optimisation](docs/incidents/2026-06-29-cooling-upgrade-resource-optimisation.md)
  (3D-printed enclosure + Noctua A6x25 fan: 85 °C → 43.9 °C; all services re-enabled; Plane and Prometheus memory requests tuned for single-user homelab use)
- [2026-07-05 — Expired GitHub token → cluster-wide Argo CD sync blindness](docs/incidents/2026-07-05-argocd-github-token-expiry.md)
  (all 17 apps stuck on `Sync: Unknown` behind a generic-looking daily alert; root cause was one expired PAT shared by every Application — rotated, all apps resynced within 30s)
- [2026-07-05 — DNS cascade during AI-HAT driver install](docs/incidents/2026-07-05-dns-cascade-hailo-install.md)
  (reboot churn → MagicDNS SERVFAIL with no upstream configured; containerd, CoreDNS, Argo CD and exit-node clients all lost resolution; tailnet nameservers + Pi-hole-first host DNS + blackbox DNS alerting added)

Further reading: [docs/security.md](docs/security.md) covers the "why" behind every security decision in detail.
