#!/usr/bin/env bash
# updates.sh – richtet die Update-Automatik des Hosts ein (docs/operations.md,
# "Updates run on their own"). Idempotent. bootstrap.sh ruft es aus
# configure_host auf; nach Änderungen an Units, Timern oder der crontab reicht:
#
#   ~/luna-sovereign-mesh/host/updates.sh
#
# Als aaron ausführen, die root-Schritte laufen über sudo.
set -euo pipefail

HOST=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
[ "$(id -un)" = aaron ] || { echo "Bitte als aaron ausführen" >&2; exit 1; }

# Renovate (01:30) und Tailscale-Key-Check: Symlinks in den Klon. Die crontab
# kommt als Ganzes aus dem Repo, mit ihr auch die Backups der Host-Apps.
mkdir -p "$HOME/renovate/logs"
ln -sfn "$HOST/renovate/run-renovate.sh" "$HOME/renovate/run-renovate.sh"
ln -sfn "$HOST/renovate/check-ts-key-expiry.sh" "$HOME/renovate/check-ts-key-expiry.sh"
crontab "$HOST/cron/crontab-aaron"
echo "ok: Renovate, crontab"

# Docker per unattended-upgrades, nachts 02:15 statt morgens
sudo install -m 0644 "$HOST/apt/51unattended-docker" /etc/apt/apt.conf.d/51unattended-docker
sudo install -D -m 0644 "$HOST/systemd/apt-daily-upgrade.timer.d/10-nachts.conf" \
  /etc/systemd/system/apt-daily-upgrade.timer.d/10-nachts.conf

# Deploys 04:15, Neustart So 04:30 nur bei Bedarf, Boot- und Wochenbericht,
# Lebenszeichen stündlich. Die Units starten die Skripte direkt aus dem Klon,
# pi-autodeploy zieht ihn jede Nacht nach.
for unit in pi-autodeploy.service pi-autodeploy.timer reboot-if-required.service \
            reboot-if-required.timer boot-report.service weekly-report.service \
            weekly-report.timer pi-heartbeat.service pi-heartbeat.timer; do
  sudo install -m 0644 "$HOST/systemd/$unit" "/etc/systemd/system/$unit"
done
sudo systemctl daemon-reload
# Neustart, damit der laufende Timer das neue OnCalendar sicher übernimmt
sudo systemctl restart apt-daily-upgrade.timer
sudo systemctl enable --now pi-autodeploy.timer reboot-if-required.timer \
  weekly-report.timer pi-heartbeat.timer >/dev/null 2>&1
sudo systemctl enable boot-report.service >/dev/null 2>&1   # läuft ab dem nächsten Boot
echo "ok: Docker-Updates, Autodeploy, Sonntags-Neustart, Berichte, Lebenszeichen"

mkdir -p "$HOME/.config/pi-maintenance"
[ -s "$HOME/.config/pi-maintenance/heartbeat-url" ] \
  || echo "Hinweis: Der externe Wächter hat noch keine Ping-URL (docs/operations.md, \"External watchdog\")"

systemctl list-timers --no-pager apt-daily-upgrade.timer pi-autodeploy.timer \
  reboot-if-required.timer weekly-report.timer pi-heartbeat.timer
