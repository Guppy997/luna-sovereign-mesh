# Host files

Files that live on the Pi itself rather than in the cluster. Argo CD does not deploy them; they are versioned here so the full setup can be rebuilt from this repository.

| File | Installed at | Purpose |
|---|---|---|
| `backup.sh` | `/home/aaron/backup.sh` (symlink to this file) | Nightly backup to the USB stick, everything age-encrypted |
| `pi-backup.cron` | `/etc/cron.d/pi-backup` | Runs `backup.sh` as root at 03:00 |
| `claude-sudo` | `/usr/local/sbin/claude-sudo` (root, 0755) | Grants the AI assistant passwordless sudo for a limited time only (`sudo claude-sudo 60`, `sudo claude-sudo off`) |

None of these files contain secrets. `backup.sh` only holds the two age **public** keys it encrypts to.

## Install on a fresh Pi

```bash
ln -sf ~/luna-sovereign-mesh/host/backup.sh ~/backup.sh
sudo install -m 0644 host/pi-backup.cron /etc/cron.d/pi-backup
sudo install -o root -g root -m 0755 host/claude-sudo /usr/local/sbin/claude-sudo
```

## Tailscale listens on UDP 41642, not 41641

`/etc/default/tailscaled` sets `PORT="41642"`. On the default port 41641 the Pi never got a direct connection to `open-claw` (Oracle) and all traffic went through the Frankfurt DERP relay. Packet captures on both ends showed that Oracle received the Pi's packets and answered, but the Fritzbox never delivered the replies. Other devices on the LAN also use 41641. A plain UDP hole-punch test on another port worked in both directions, so the Fritzbox can do NAT traversal in general and the problem was limited to that one port. After the change, `tailscale ping open-claw` goes direct (`via 130.61.77.195:41641`, ~10 ms).

```bash
sudo sed -i 's/^PORT=.*/PORT="41642"/' /etc/default/tailscaled
sudo systemctl restart tailscaled
```

## Restore one item from a backup

```bash
age -d -i <age-private-key> /mnt/backup/<YYYY-MM-DD>/lern-pwa.tar.age | tar -x -C /tmp/restore
```

`<age-private-key>` is either the offline recovery key or, on an intact Pi, the SOPS key (`~/.config/sops/age/keys.txt`). Every archive is encrypted to both.
