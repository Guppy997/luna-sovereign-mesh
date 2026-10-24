# Disaster Recovery

From an empty SD card or SSD to the full stack running again:

1. clone this repository,
2. put the age key in place,
3. plug in the USB backup stick,
4. run `./bootstrap.sh`,
5. run `./restore.sh latest`.

`bootstrap.sh` rebuilds the host and the cluster from this repository; `restore.sh` puts the data back from the stick. Both are idempotent and safe to re-run. Neither prints secret values.

## What you need offline

| What | Why |
|---|---|
| **Recovery key** (age private key for `age16ggv…`, in the password manager / on paper) | Decrypts every backup archive and every file under `clusters/dev/secrets/`. Also decrypts `sops-age-key.txt.age` on the stick, which holds the Pi's own SOPS key. |
| **USB backup stick** (exFAT, UUID `6A36-8E61`) | The only copy of the data: Postgres dumps, PVC contents, the host apps, Home Assistant, Pi-hole. 14 daily versions. |
| **GitHub login with 2FA** (account `Guppy997`) | Cloning the private app repos, the token for Argo CD and Renovate. |
| **Tailscale login with 2FA** | Re-joining the tailnet and creating auth keys for the app sidecars. |
| Raspberry Pi Imager, a computer with an SSH key | Flashing the system. |

## Steps

### 1. Flash the system

Raspberry Pi Imager → **Ubuntu Server 24.04 LTS (64-bit)**. In the settings: hostname `raspberrypi-1`, user `aaron`, your SSH public key, no Wi-Fi (the Pi is on Ethernet; the router hands out its address). Boot and connect over the LAN: `ssh aaron@<ip>`.

### 2. Clean up the tailnet first

In the Tailscale admin console, **remove the old machines** `raspberrypi-1`, `luna-pwa`, `lern-pwa`, `fitness-pwa` and `ausrichtung`. Otherwise the new nodes get a suffix (`raspberrypi-1-1`), and the MagicDNS names used throughout the manifests, Pi-hole and the alert scripts no longer match.

### 3. Clone the repository and restore the age key

```bash
sudo apt-get update && sudo apt-get install -y git age
git clone https://github.com/Guppy997/luna-sovereign-mesh.git ~/luna-sovereign-mesh
mkdir -p ~/.config/sops/age
```

Then either copy the Pi's SOPS key to `~/.config/sops/age/keys.txt`, or recover it from the stick with the recovery key:

```bash
sudo mkdir -p /mnt/backup && sudo mount UUID=6A36-8E61 /mnt/backup
latest=$(ls -1d /mnt/backup/20??-??-?? | sort | tail -1)
age -d -i /path/to/recovery-key.txt "$latest/sops-age-key.txt.age" > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

The recovery key alone also works as `keys.txt`: every SOPS file is encrypted to both keys. Restoring the original key keeps the Pi's identity unchanged for future backups.

### 4. Bootstrap

```bash
cd ~/luna-sovereign-mesh
./bootstrap.sh
```

It stops twice for a login: GitHub (browser or device code) and Tailscale (link). Everything else runs unattended:

- **Packages and tools** at the versions running on 2026-10-24: k3s, Docker, Tailscale (held), sops, yq, kubara, Beszel agent.
- **Host configuration from `host/`:** sysctl, journald, UFW, fstab entry for the stick, cron jobs, DNS watchdog, unattended-upgrades → ntfy.
- **DNS:** Unbound, then Pi-hole with the base config from `host/pihole/pihole.base.toml`.
- **Host apps:** Lern-PWA, Fitness-PWA, Ausrichtung and Home Assistant, started with empty data.
- **Cluster:**
  - all secrets from `clusters/dev/secrets/` via `sops -d | kubectl apply`;
  - Argo CD via `kubara bootstrap`, with `.env` generated from the encrypted `kubara-env-secret.yaml`;
  - the `homer-dashboard` label fix;
  - every `clusters/dev/apps/*-application.yaml`;
  - the `tailscale serve` port map.

`./bootstrap.sh host` and `./bootstrap.sh cluster` run one half only.

### 5. Wait for Argo CD

```bash
kubectl -n argocd get applications
```

All applications should reach `Synced`/`Healthy`. Each app's first start creates its PVC and empty databases; `restore.sh` needs both.

### 6. Restore the data

```bash
./restore.sh latest --dry-run   # decrypts and lists every archive, writes nothing
./restore.sh latest
```

What it does, per part:

| Part | Restores | How |
|---|---|---|
| `affine` | Postgres `affine`, PVC `affine-storage` | pauses the Argo app, scales the app to 0, drops and recreates the database, replaces the PVC contents |
| `plane` | Postgres `plane`, PVC `minio-data` | same |
| `vaultwarden`, `beaverhabits` | their data PVCs | same, without a database |
| `pwas` | `~/lern-pwa/data`, `~/fitness-pwa/data`, `~/ausrichtung/data` | stops the backend, replaces `data/`, starts it |
| `homeassistant` | `~/homeassistant/config` | stops the container, replaces the config |
| `pihole` | `/etc/pihole`, `/etc/dnsmasq.d` | stops FTL, replaces both, starts FTL |

Single parts: `./restore.sh latest pihole pwas`. An older day: `./restore.sh 2026-10-20`. With the recovery key instead of the SOPS key: `AGE_IDENTITY=/path/to/recovery-key.txt ./restore.sh latest`.

### 7. Tailscale sidecars of the host apps

Lern-PWA, Fitness-PWA and Ausrichtung each run a Tailscale sidecar with its own auth key in `~/<app>/.env`. Create a new key in the admin console (tag `tag:pwa-sidecar`), write it as `TS_AUTHKEY=…` into each `.env` (mode 0600), then run `docker compose up -d` in each folder. The Luna PWA sidecar in the cluster uses the key from `clusters/dev/secrets/luna-pwa-luna-pwa-ts-authkey.yaml`. If that key has expired, put a new one in the secret and re-export it:

```bash
kubectl -n luna-pwa create secret generic luna-pwa-ts-authkey --from-file=authkey=/path/to/keyfile \
  --dry-run=client -o yaml | kubectl apply -f -
scripts/export-secret.sh luna-pwa luna-pwa-ts-authkey
```

### 8. Check

- `tailscale serve status` lists ports 10000–10011.
- Homepage at `https://raspberrypi-1.<tailnet>.ts.net:10001` shows every service as up.
- `dig @<pi-ip> example.com` answers from the LAN; the Pi-hole admin works with the old password.
- Vaultwarden, AFFiNE and Plane show the data from the backup.
- The next night's backup (03:00) reports success over ntfy.

## Where everything comes from

| What | Source |
|---|---|
| Cluster configuration | this repository, via Argo CD |
| Cluster secrets | `clusters/dev/secrets/`, SOPS-encrypted to the SOPS key and the recovery key |
| Argo CD itself | `kubara bootstrap` with `config.yaml` and `.env` (from `kubara-env-secret.yaml`) |
| Images of luna-pwa, luna-adapter, MinIO, mc | `ghcr.io/guppy997` (private), pull secret via SOPS. MinIO no longer publishes images on Docker Hub. |
| Other images | their public registries |
| Host packages and configuration | `host/`, applied by `bootstrap.sh` |
| Data | the USB stick, via `restore.sh` |
| Pi-hole blocklists, local DNS, admin password; Home Assistant configuration | the USB stick. They contain personal data, so they are deliberately not in this repository. |

## Not covered, and known limits

- **Not rehearsed end to end.** `bootstrap.sh` and `restore.sh` are checked with `bash -n`, shellcheck and a dry-run against the real stick, but have not yet rebuilt a Pi from scratch. Rehearse on a spare SD card before relying on them.
- **One data copy.** The stick sits next to the Pi. An off-site copy of the encrypted archives is still open.
- **Data written after 03:00 is lost.** The restore drops and recreates the databases.
- **Not in the backup, start empty:** Loki logs, Prometheus metrics, Beszel history, the ntfy message cache. Dashboards and alert rules are in Git.
- **Expiry dates:** the Tailscale node key of `raspberrypi-1` (check `~/renovate/check-ts-key-expiry.sh`), the GitHub token in `kubara-env-secret.yaml`, and the ghcr pull token. An expired token shows up as failed syncs or failed image pulls.
