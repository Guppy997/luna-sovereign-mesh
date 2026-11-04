#!/usr/bin/env bash
# Startet den Pi sonntags neu, wenn ein Update das verlangt (Kernel, libc …).
#
# unattended-upgrades installiert Kernel-Updates, wirksam werden sie aber erst
# nach einem Neustart. Dessen eigenes Automatic-Reboot würde an jedem Tag neu
# starten; hier passiert es nur über den Timer So 04:30 und erst, wenn
# pi-autodeploy und apt fertig sind. Nach dem Boot meldet boot-report.sh, ob
# alles wieder läuft. Alles ist dabei 3–5 min weg, auch der Exit-Node.
#
#   --dry-run  nur prüfen und anzeigen
set -euo pipefail

NTFY_URL="http://10.43.235.81/luna-alerts"
MARKER=/var/lib/pi-maintenance/reboot-planned
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

notify() {  # $1=title $2=tags $3=priority $4=body
  [ "$DRY_RUN" = 1 ] && { echo "ntfy: $1 | $4"; return 0; }
  printf '%b' "$4" | curl -sf --max-time 15 \
    -H "Title: $1" -H "Tags: $2" -H "Priority: $3" \
    --data-binary @- "$NTFY_URL" >/dev/null || true
}

if [ ! -f /var/run/reboot-required ]; then
  echo "Kein Neustart nötig"
  exit 0
fi
pkgs=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')

# Nicht mitten in einen Deploy oder ein Paket-Update hinein neu starten
for _ in $(seq 1 60); do
  systemctl is-active --quiet pi-autodeploy.service apt-daily-upgrade.service || break
  sleep 30
done
if systemctl is-active --quiet pi-autodeploy.service apt-daily-upgrade.service; then
  notify "Neustart verschoben" "warning" "default" "pi-autodeploy oder apt läuft seit 30 min. Nächster Versuch nächsten Sonntag, oder von Hand: sudo reboot"
  exit 0
fi

notify "Pi startet neu" "arrows_counterclockwise" "low" "Für: ${pkgs:-unbekannt}\nIn ein paar Minuten kommt der Bericht nach dem Boot."
if [ "$DRY_RUN" = 1 ]; then
  echo "würde neu starten (für: ${pkgs:-unbekannt})"
  exit 0
fi
mkdir -p "$(dirname "$MARKER")"
date -Iseconds >"$MARKER"
sleep 5   # ntfy-Meldung rausgehen lassen
systemctl reboot
