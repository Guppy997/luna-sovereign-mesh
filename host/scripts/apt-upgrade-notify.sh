#!/usr/bin/env bash
# Meldet das Ergebnis von unattended-upgrades per ntfy.
#
# Hintergrund: unattended-upgrades kann nur per Mail berichten und warf deshalb
# täglich "No /usr/bin/mail or /usr/sbin/sendmail" in den Log — es gibt auf dem
# Pi bewusst keinen MTA. Statt einen MTA nachzurüsten meldet dieses Skript über
# denselben ntfy-Topic wie die übrigen Alerts (s. check-ts-key-expiry.sh).
#
# Aufruf per ExecStopPost aus apt-daily-upgrade.service, läuft also direkt
# nachdem der tägliche Upgrade-Lauf fertig ist — kein Rätselraten über die
# randomisierte Timer-Startzeit.
set -euo pipefail

# Intern über die gepinnte ClusterIP: tailscale serve nimmt ab 1.104 nur noch
# Verbindungen über tailscale0 an, vom Host selbst kommt man dort nicht hin.
NTFY_URL="http://10.43.235.81/luna-alerts"
UU_LOG="/var/log/unattended-upgrades/unattended-upgrades.log"

notify() {  # $1=title $2=tags $3=priority $4=body
  printf '%b' "$4" | curl -sf --max-time 15 \
    -H "Title: $1" -H "Tags: $2" -H "Priority: $3" \
    --data-binary @- "$NTFY_URL" >/dev/null || true
}

# Nur den zuletzt gestarteten Lauf betrachten, nicht den ganzen Tag: uu laeuft
# mehrmals taeglich (apt-daily-upgrade plus manuelle Aufrufe), und der Hook
# feuert nach genau einem davon. Ueber den ganzen Tag zu greppen wuerde Meldungen
# aelterer Laeufe erneut verschicken.
run_log=$(tac "$UU_LOG" 2>/dev/null | sed -n '1,/Starting unattended upgrades script/p' | tac || true)
[ -n "$run_log" ] || exit 0

pkgs=$(printf '%s\n' "$run_log" | sed -n 's/.*Packages that will be upgraded: //p' | tail -1)
installed=$(printf '%s\n' "$run_log" | grep -c "All upgrades installed" || true)
failed=$(printf '%s\n' "$run_log" | grep -ciE "ERROR|Exception" || true)

# Der Mail-Fehler ist mit dieser Umstellung weg; falls doch noch etwas anderes
# ERROR-artiges auftaucht, soll es sichtbar sein.
if [ "$failed" -gt 0 ]; then
  body=$(printf '%s\n' "$run_log" | grep -iE "ERROR|Exception" | tail -5)
  notify "Unattended-Upgrades: Fehler" "warning" "high" "$body"
  exit 0
fi

# Kein Upgrade nötig -> still bleiben, sonst gibt es täglich eine Nullmeldung.
[ -n "$pkgs" ] || exit 0

body="Installiert: $pkgs"
tags="package"
prio="default"

if [ -f /var/run/reboot-required ]; then
  # reboot-required.pkgs fehlt gelegentlich, obwohl das Flag gesetzt ist.
  # Ohne das || true wuerde pipefail hier den ganzen Lauf abbrechen — also
  # ausgerechnet dann, wenn die Meldung am wichtigsten ist.
  rb=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ' || true)
  body="$body\n\nNEUSTART ERFORDERLICH\nAusloeser: ${rb:-unbekannt}"
  tags="package,rotating_light"
  prio="high"
fi

[ "$installed" -gt 0 ] || body="$body\n\n(Achtung: kein 'All upgrades installed' im Log)"

notify "Unattended-Upgrades auf dem Pi" "$tags" "$prio" "$body"
