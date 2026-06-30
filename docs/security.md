# Security Design

## SOPS + Age for Secret Encryption

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

## Zero-Trust Network Access

The cluster is not reachable from the internet **or** from the local network — the LAN is treated as untrusted, the same way a corporate network would be in a zero-trust model.

- **Nothing is exposed to the internet.** No router port forwarding, no Tailscale Funnel. Argo CD only *pulls* from GitHub — there is no inbound path.
- **All access goes through the tailnet** (Tailscale, WireGuard-based). Services are reached via MagicDNS hostnames; HTTPS endpoints are published with Tailscale Serve.
- **LAN exposure is reduced to two ports:** DNS (53 — Pi-hole serves the home network) and SSH (22 — key-only, root login disabled) as a break-glass fallback.
- **Enforcement happens at two independent layers:**
  - *Kubernetes:* the Traefik LoadBalancer carries `loadBalancerSourceRanges: [100.64.0.0/10]`, enforced by kube-proxy in the kernel. NodePort allocation is disabled (`allocateLoadBalancerNodePorts: false`) — a deliberate choice, because NodePort traffic bypasses host firewalls entirely.
  - *Host:* UFW with a default-deny inbound policy covers everything that does not run in Kubernetes (SSH, Pi-hole, kubelet, node exporter).
- **Tailscale ACLs follow least privilege:** personal devices may reach the Pi; the tagged cloud node may not — traffic to the cloud sandbox is strictly one-way (Pi → cloud).
- **Split DNS:** Pi-hole forwards the tailnet DNS zone (`*.ts.net`) to MagicDNS, so service hostnames resolve consistently for every device in the house.

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

## Backup

A daily systemd timer runs at 03:00 on the Pi host and writes to a USB stick mounted at `/mnt/backup` (57 GB exFAT, auto-mounted via `/etc/fstab`).

| What | How | Kept |
|---|---|---|
| All Kubernetes secrets | `kubectl get secrets -A -o yaml` | 90 days |
| PostgreSQL databases | `pg_dump` via `kubectl exec` (plane + affine) | 90 days |
| Vaultwarden data | Direct copy from k3s PV (`db.sqlite3` + attachments) | 90 days |
| MinIO file uploads (Plane) | Direct copy from k3s PV | 90 days |
| Affine blob storage | Direct copy from k3s PV | 90 days |
| Beaver Habits data | Direct copy from k3s PV | 90 days |

Each daily snapshot is ~10 MB. At 90-day retention the USB stick holds roughly 900 MB of backup data.

Script: `/usr/local/bin/kubara-backup.sh` — Log: `/mnt/backup/kubara-backup/backup.log`

### What is NOT backed up here

Everything in this Git repository is the backup for the cluster configuration — encrypted secrets, manifests, Helm values. The USB stick covers only the runtime state that Git cannot capture (live database contents, uploaded files, secret values).

## On Running Production Tooling on a Single Pi

kubara and k3s are designed for multi-node production clusters. In that environment a forced node reboot is routine: the control plane stays up, workloads reschedule, and CNI state synchronizes from surviving members.

On a single-node Pi there is no redundancy — a CNI crash takes the entire cluster offline. Implementing automated single-node recovery (ordered CNI restart, DNS restoration, health gating) would be significant tooling work for a rare edge case. The accepted tradeoff is manual recovery, documented as a runbook in the [incident postmortems](incidents/).
