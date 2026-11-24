# Security Design

## SOPS + Age for Secret Encryption

All Kubernetes secrets are encrypted with [Mozilla SOPS](https://github.com/getsops/sops) using [Age](https://github.com/FiloSottile/age) as the key provider before being pushed to GitHub.

**Why SOPS + Age over HashiCorp Vault?**

| | SOPS + Age | HashiCorp Vault |
|---|---|---|
| Infrastructure required | None: files are self-contained | Needs a running Vault server |
| GitOps compatibility | Native: encrypted files live in Git | Requires external secret sync |
| Operational overhead | Near-zero | High (HA, unsealing, backups) |
| Cost | Free, open-source | Free tier limited, OSS complex |

For a single-operator homelab, Vault's operational overhead outweighs its benefits. SOPS integrates directly into the GitOps flow: encrypt locally, push ciphertext, Argo CD + external-secrets decrypts at deploy time.

The Age private key is stored offline (not in this repository) and is the single credential required to recover the entire stack.

### What is encrypted

```
clusters/dev/secrets/*.yaml   ← AES256-GCM encrypted, Age-keyed
```

Metadata (Kubernetes resource names, namespaces) remains readable intentionally; only `data` and `stringData` fields are encrypted.

### What is never in Git

- Age private key
- `.env` file (plaintext credentials)
- Unencrypted secret drafts (`*.dec.yaml`, `*.plaintext.yaml`)

## Zero-Trust Network Access

The cluster is not reachable from the internet **or** from the local network; the LAN is treated as untrusted, the same way a corporate network would be in a zero-trust model.

- **Nothing is exposed to the internet.** No router port forwarding, no Tailscale Funnel. Argo CD only *pulls* from GitHub; there is no inbound path.
- **All access goes through the tailnet** (Tailscale, WireGuard-based). Services are reached via MagicDNS hostnames; HTTPS endpoints are published with Tailscale Serve.
- **LAN exposure is reduced to two ports:** DNS (53, Pi-hole serves the home network) and SSH (22, key-only, root login disabled) as a break-glass fallback.
- **Enforcement happens at two independent layers:**
  - *Kubernetes:* the Traefik LoadBalancer carries `loadBalancerSourceRanges: [100.64.0.0/10]`, enforced by kube-proxy in the kernel. NodePort allocation is disabled (`allocateLoadBalancerNodePorts: false`), a deliberate choice, because NodePort traffic bypasses host firewalls entirely.
  - *Host:* UFW with a default-deny inbound policy covers everything that does not run in Kubernetes (SSH, Pi-hole, kubelet, node exporter).
- **Tailscale ACLs follow least privilege:** personal devices may reach the Pi; the tagged cloud node that runs OpenClaw may not. Traffic to it is strictly one-way (Pi → cloud). The wall tablet (`tag:wallpanel`) reaches a handful of direct ports and never a Traefik port, see [wallpanel.md](wallpanel.md).
- **Split DNS:** Pi-hole forwards the tailnet DNS zone (`*.ts.net`) to MagicDNS, so service hostnames resolve consistently for every device in the house.

## Disaster Recovery

The full stack is recoverable from three things:

1. **This repository:** cluster configuration, host configuration (`host/`) and every hand-made Kubernetes secret, SOPS-encrypted under `clusters/dev/secrets/`.
2. **An age private key:** either the Pi's SOPS key or the offline recovery key. Every SOPS file and every backup archive is encrypted to both, so either one is enough.
3. **The USB backup stick:** the data, see [Backup](#backup).

`./bootstrap.sh` rebuilds host and cluster, and `./restore.sh latest` puts the data back. The full walkthrough from an empty SD card, including what to keep offline, is in **[disaster-recovery.md](disaster-recovery.md)**.

## Backup

A daily cron job (`/etc/cron.d/pi-backup`, 03:00) runs [`host/backup.sh`](../host/backup.sh) on the Pi host. It writes one directory per day to a USB stick mounted at `/mnt/backup` (57 GB, auto-mounted via `/etc/fstab`): `/mnt/backup/<YYYY-MM-DD>/`.

**Nothing is stored in plaintext on the stick.** It is exFAT, which has no file permissions, so encryption is the only protection if it is lost or stolen. Each source is first copied to a root-only staging directory on the SSD, including consistent SQLite snapshots (`.backup`), and then written to the stick as an age-encrypted archive. Database dumps are piped straight into age, so no plaintext dump exists even temporarily.

| What | Archive |
|---|---|
| PostgreSQL databases (Plane, AFFiNE) | `<app>-postgres.sql.age` (`pg_dump` via `kubectl exec`) |
| Vaultwarden | `vaultwarden-data.tar.age` (SQLite snapshot + attachments; vault entries are additionally end-to-end encrypted by the Bitwarden clients) |
| AFFiNE file storage and config | `affine-storage.tar.age` |
| MinIO uploads (Plane), Beaver Habits | `minio-data.tar.age`, `beaverhabits-data.tar.age` |
| Lern-PWA, Fitness-PWA, Ausrichtung | `<pwa>.tar.age` (SQLite snapshot + data dir) |
| Home Assistant, Pi-hole | `homeassistant.tar.age`, `pihole.tar.age` |
| All Kubernetes secrets | `k8s-secrets.yaml.age` |
| SOPS age key | `sops-age-key.txt.age`, encrypted to the recovery key **only** |

Every archive except the SOPS key is encrypted to two recipients: the **recovery key**, whose private half is kept offline and never on the Pi, and the **SOPS key**, so an intact Pi can restore without fetching the offline key. Restore steps: [host/README.md](../host/README.md).

Everything is kept for 14 days (`RETENTION_DAYS`). A daily set is about 530 MB and takes about 40 s. Failures are pushed to ntfy.

**Known gap:** the stick sits in the Pi, so fire, theft or a power surge would take both. An off-site copy is still open.

Log: `/mnt/backup/backup.log`

### What is NOT backed up here

Everything in this Git repository is the backup for the cluster configuration: encrypted secrets, manifests, Helm values. The USB stick covers only the runtime state that Git cannot capture (live database contents, uploaded files, secret values).

## On Running Production Tooling on a Single Pi

kubara and k3s are designed for multi-node production clusters. In that environment a forced node reboot is routine: the control plane stays up, workloads reschedule, and CNI state synchronizes from surviving members.

On a single-node Pi there is no redundancy: a CNI crash takes the entire cluster offline. Implementing automated single-node recovery (ordered CNI restart, DNS restoration, health gating) would be significant tooling work for a rare edge case. The accepted tradeoff is manual recovery, documented as a runbook in the [incident postmortems](incidents/).
