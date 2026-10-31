# Host files

Everything that lives on the Pi itself rather than in the cluster: packages, DNS, firewall, cron jobs, backup and the Docker Compose apps. Argo CD does not deploy these files. `../bootstrap.sh host` installs all of them (idempotent), so the host can be rebuilt from this repository. The full disaster-recovery walkthrough is in [`docs/disaster-recovery.md`](../docs/disaster-recovery.md).

None of these files contain secrets or personal data:
- `backup.sh` only holds the two age **public** keys it encrypts to.
- Pi-hole's password, local DNS entries and blocklists, and the Home Assistant configuration come from the encrypted backup via `../restore.sh`.

| File | Installed at | Purpose |
|---|---|---|
| `backup.sh` | `~/backup.sh` (symlink) | Nightly backup to the USB stick, everything age-encrypted |
| `pi-backup.cron` | `/etc/cron.d/pi-backup` | Runs `backup.sh` as root at 03:00 |
| `fstab.backup` | appended to `/etc/fstab` | Mounts the backup stick (exFAT, by UUID) at `/mnt/backup` |
| `claude-sudo` | `/usr/local/sbin/claude-sudo` (root, 0755) | Grants the AI assistant passwordless sudo for a limited time only (`sudo claude-sudo 60`, `sudo claude-sudo off`) |
| `k3s/config.yaml` | `/etc/rancher/k3s/config.yaml` | k3s without its bundled Traefik (Traefik comes from Argo CD) |
| `ufw.sh` | run once | Firewall: from the LAN only SSH and DNS, everything else only via the tailnet |
| `sysctl/*.conf` | `/etc/sysctl.d/` | Kernel tuning; IP forwarding for the Tailscale exit node |
| `journald/00-size-limit.conf` | `/etc/systemd/journald.conf.d/` | Caps the journal at 500 MB |
| `unbound/pi-hole.conf` | `/etc/unbound/unbound.conf.d/` | Recursive resolver on 127.0.0.1:5335, Pi-hole's only upstream |
| `pihole/pihole.base.toml` | `/etc/pihole/pihole.toml` (before the installer) | Pi-hole settings that differ from the default: upstream, web ports 8081/8443, headers, MagicDNS forwarding |
| `scripts/dns-watchdog.sh` + `cron/dns-watchdog` | `/usr/local/bin/`, `/etc/cron.d/` | Restarts Unbound or Pi-hole if they stop answering (every 2 min) |
| `scripts/apt-upgrade-notify.sh` + `systemd/apt-daily-upgrade.service.d/10-ntfy.conf` | `~/apt-upgrade-notify.sh` (symlink), drop-in | Reports unattended-upgrades results to ntfy |
| `systemd/beszel-agent.service` | `/etc/systemd/system/` | Beszel monitoring agent (`KEY` is the hub's public key) |
| `renovate/*.sh` | `~/renovate/` (symlinks) | Nightly Renovate run, Tailscale key-expiry warning |
| `cron/crontab-aaron` | user crontab of `aaron` | Host-app backups, Renovate, key-expiry check |
| `apps.txt` | `~/<app>` (git clone) | Lern-PWA, Fitness-PWA, Ausrichtung: each has its own repo and `docker-compose.yml` |
| `apps/homeassistant/docker-compose.yml` | `~/homeassistant/` | Home Assistant (host network) |
| `kubara.env` | merged into `../.env` | The non-secret half of kubara's `.env`; the secret half comes from `clusters/dev/secrets/kubara-env-secret.yaml` |

## Tailscale listens on UDP 41642, not 41641

`/etc/default/tailscaled` sets `PORT="41642"`. On the default port 41641 the Pi never got a direct connection to `open-claw` (Oracle) and all traffic went through the Frankfurt DERP relay. Packet captures on both ends showed that Oracle received the Pi's packets and answered, but the Fritzbox never delivered the replies. Other devices on the LAN also use 41641. A plain UDP hole-punch test on another port worked in both directions, so the Fritzbox can do NAT traversal in general and the problem was limited to that one port. After the change, `tailscale ping open-claw` goes direct (`via 130.61.77.195:41641`, ~10 ms).

```bash
sudo sed -i 's/^PORT=.*/PORT="41642"/' /etc/default/tailscaled
sudo systemctl restart tailscaled
```

`../bootstrap.sh host` sets this as well.

## Restore one item by hand

```bash
age -d -i <age-private-key> /mnt/backup/<YYYY-MM-DD>/lern-pwa.tar.age | tar -x -C /tmp/restore
```

`<age-private-key>` is either the offline recovery key or, on an intact Pi, the SOPS key (`~/.config/sops/age/keys.txt`). Every archive is encrypted to both. For a full restore, use `../restore.sh`.
