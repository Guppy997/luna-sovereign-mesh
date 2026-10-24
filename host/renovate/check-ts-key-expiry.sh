#!/usr/bin/env bash
# Warnt per ntfy, wenn Tailscale-Node-Keys bald ablaufen (< 30 Tage).
# Hintergrund: Key-Expiry ist für raspberrypi-1 (2026-11-30) und open-claw
# (2026-12-02) NICHT deaktiviert — ohne Verlängerung/Disable fallen die
# Nodes an dem Tag stumm aus dem Tailnet. Disable geht nur in der
# Admin-Console (Machines -> ... -> Disable key expiry).
set -euo pipefail

WARN_DAYS=30
NOW=$(date +%s)
NTFY_URL="https://raspberrypi-1.tailddc8f7.ts.net:10003/luna-alerts"

WARNINGS=""

check() {
  local name="$1" expiry="$2"
  [ -z "$expiry" ] || [ "$expiry" = "null" ] && return 0
  local exp_s
  exp_s=$(date -d "$expiry" +%s 2>/dev/null) || return 0
  local days=$(( (exp_s - NOW) / 86400 ))
  if [ "$days" -lt "$WARN_DAYS" ]; then
    WARNINGS="${WARNINGS}${name}: Key läuft in ${days} Tagen ab (${expiry})\n"
  fi
}

STATUS=$(tailscale status --json)
check "raspberrypi-1 (dieser Pi)" "$(echo "$STATUS" | jq -r '.Self.KeyExpiry // empty')"
check "open-claw (Oracle)" "$(echo "$STATUS" | jq -r '.Peer[] | select(.HostName=="open-claw") | .KeyExpiry // empty')"

if [ -n "$WARNINGS" ]; then
  printf '%b\nFix: Tailscale Admin-Console -> Machines -> Disable key expiry' "$WARNINGS" | \
    curl -sf -H "Title: Tailscale-Key-Expiry steht an!" \
      -H "Tags: rotating_light" -H "Priority: high" \
      --data-binary @- "$NTFY_URL" || true
fi
