#!/usr/bin/env bash
# Meldet nach jedem Boot per ntfy, ob alles wieder läuft: Argo-CD-Apps, die
# Docker-Container der Host-Apps, Home Assistant und Tailscale. k3s braucht nach
# einem Kaltstart auf dem Pi einige Minuten, bis alle Pods stehen; das Skript
# wartet deshalb bis zu 15 min. Ein Neustart ohne Marker von
# reboot-if-required.sh wird als ungeplant gemeldet (Stromausfall, Absturz).
set -uo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NTFY_URL="http://10.43.235.81/luna-alerts"
MARKER=/var/lib/pi-maintenance/reboot-planned
DEADLINE=$(( $(date +%s) + 900 ))

problems() {
  local argo docker ts
  argo=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
             | "\(.metadata.name | sub("^luna-sovereign-mesh-"; "")): \(.status.sync.status)/\(.status.health.status)"') \
    || argo="Argo CD nicht erreichbar"
  [ -n "$argo" ] && printf 'Argo CD:\n%s\n' "$argo"
  docker=$(docker ps -a --format '{{.Names}} {{.Status}}' | grep -vE ' Up .*\(healthy\)$| Up [^(]*$' || true)
  [ -n "$docker" ] && printf 'Docker:\n%s\n' "$docker"
  curl -sf -o /dev/null --max-time 5 http://127.0.0.1:8123/manifest.json || echo "Home Assistant antwortet nicht"
  ts=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unbekannt"')
  [ "$ts" = Running ] || echo "Tailscale: $ts"
}

while :; do
  report=$(problems)
  [ -z "$report" ] && break
  [ "$(date +%s)" -ge "$DEADLINE" ] && break
  sleep 30
done

if [ -f "$MARKER" ]; then
  how="geplanter Neustart"
  rm -f "$MARKER"
else
  how="UNGEPLANTER Neustart (Stromausfall oder Absturz?)"
fi
kernel=$(uname -r)
boot_secs=$(( $(date +%s) - $(date -d "$(uptime -s)" +%s) ))

if [ -z "$report" ]; then
  title="Pi ist wieder da"; tags="white_check_mark"; prio="low"
  body="$how, Kernel $kernel\nNach $((boot_secs / 60)) min alles grün: Argo CD, Host-Apps, Home Assistant, Tailscale."
else
  title="Pi nach Neustart nicht ganz gesund"; tags="warning"; prio="high"
  body="$how, Kernel $kernel\nNach $((boot_secs / 60)) min noch offen:\n$report"
fi
# ntfy läuft selbst im Cluster; falls es noch startet, ein paar Mal versuchen
for _ in 1 2 3 4 5 6; do
  printf '%b' "$body" | curl -sf --max-time 15 \
    -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
    --data-binary @- "$NTFY_URL" >/dev/null && exit 0
  sleep 30
done
echo "ntfy nicht erreichbar. Bericht: $title / $body"
