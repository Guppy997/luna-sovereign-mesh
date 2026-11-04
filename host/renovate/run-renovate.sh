#!/usr/bin/env bash
# Self-hosted Renovate für alle eigenen Repos (Docker, ARM64).
# Läuft per Cron um 01:30 (host/cron/crontab-aaron). Mit dabei ist jedes Repo von
# Guppy997 und bola-cat-industry, das eine renovate.json hat; neue Repos brauchen
# also nur diese Datei. Archivierte Repos und Forks lässt Renovate von selbst aus.
# Die Regeln stehen im Preset github>Guppy997/renovate-config bzw. für dieses Repo
# in renovate.json (PRs am Wochenende, Automerge erst bei grüner CI).
# Token wird zur Laufzeit aus ~/.git-credentials gelesen — nirgendwo dupliziert.
set -euo pipefail

LOG_DIR="$HOME/renovate/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/renovate-$(date +%Y%m%d-%H%M).log"

TOKEN=$(grep github.com "$HOME/.git-credentials" | head -1 | sed 's|https://[^:]*:||; s|@github.com.*||')
if [ -z "$TOKEN" ]; then
  echo "Kein GitHub-Token in ~/.git-credentials gefunden" >&2
  exit 1
fi

set +e
docker run --rm \
  --memory=768m \
  -e RENOVATE_TOKEN="$TOKEN" \
  -e RENOVATE_AUTODISCOVER=true \
  -e RENOVATE_AUTODISCOVER_FILTER="Guppy997/*,bola-cat-industry/*" \
  -e RENOVATE_REQUIRE_CONFIG=required \
  -e RENOVATE_ONBOARDING=false \
  -e RENOVATE_PLATFORM=github \
  -e RENOVATE_GIT_AUTHOR="Renovate Bot <193275228+Guppy997@users.noreply.github.com>" \
  -e LOG_LEVEL=info \
  renovate/renovate:latest >"$LOG_FILE" 2>&1
RC=$?
set -e

# alte Logs aufräumen (letzte 14 behalten)
ls -1t "$LOG_DIR"/renovate-*.log 2>/dev/null | tail -n +15 | xargs -r rm --

if [ $RC -ne 0 ]; then
  # ntfy intern über die gepinnte ClusterIP (tailscale serve ab 1.104 nur über tailscale0)
  tail -c 500 "$LOG_FILE" | curl -sf \
    -H "Title: Renovate-Lauf fehlgeschlagen (exit $RC)" \
    -H "Tags: warning" -H "Priority: high" \
    --data-binary @- \
    "http://10.43.235.81/luna-alerts" || true
fi
exit $RC
