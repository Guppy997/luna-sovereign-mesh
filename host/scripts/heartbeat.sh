#!/usr/bin/env bash
# Stündliches Lebenszeichen an einen externen Wächter (healthchecks.io o. ä.).
# ntfy läuft auf dem Pi selbst: Fällt der Pi aus (Strom, Netz, Platte), kommt
# keine Meldung mehr, und Stille sieht aus wie "alles in Ordnung". Bleibt das
# Lebenszeichen aus, schreibt der Wächter dagegen eine Mail.
#
# Gesendet wird nur der Ping, keine Daten. Antwortet ntfy nicht, geht statt des
# Pings ein Fehlersignal (/fail) raus, denn dann kommt auch sonst nichts an.
#
# Die Ping-URL liegt nicht im Repo (wer sie kennt, kann für den Pi pingen),
# sondern in ~/.config/pi-maintenance/heartbeat-url. Ohne die Datei tut das
# Skript nichts, weekly-report.sh erinnert daran. Einrichtung: docs/operations.md.
set -uo pipefail

URL_FILE="$HOME/.config/pi-maintenance/heartbeat-url"
# Intern über die gepinnte ClusterIP, wie alle Host-Skripte
NTFY_HEALTH="http://10.43.235.81/v1/health"

[ -s "$URL_FILE" ] || exit 0
url=$(head -1 "$URL_FILE")

if curl -sf --max-time 5 "$NTFY_HEALTH" | grep -q '"healthy":true'; then
  curl -fsS --max-time 10 --retry 3 -o /dev/null "$url"
else
  curl -fsS --max-time 10 --retry 3 -o /dev/null --data-raw "ntfy auf dem Pi antwortet nicht" "$url/fail"
fi
