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

## Restore one item from a backup

```bash
age -d -i <age-private-key> /mnt/backup/<YYYY-MM-DD>/lern-pwa.tar.age | tar -x -C /tmp/restore
```

`<age-private-key>` is either the offline recovery key or, on an intact Pi, the SOPS key (`~/.config/sops/age/keys.txt`). Every archive is encrypted to both.
