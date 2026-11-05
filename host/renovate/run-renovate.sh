#!/usr/bin/env bash
# Self-hosted Renovate für alle eigenen Repos (Docker, ARM64).
# Läuft per Cron um 01:30 (host/cron/crontab-aaron). Mit dabei ist jedes Repo von
# Guppy997 und bola-cat-industry, das eine renovate.json hat; neue Repos brauchen
# also nur diese Datei. Archivierte Repos und Forks lässt Renovate von selbst aus.
# Die Regeln stehen im Preset github>Guppy997/renovate-config bzw. für dieses Repo
# in renovate.json (PRs am Wochenende, Automerge erst bei grüner CI).
# Token kommt zur Laufzeit von gh, er wird nirgendwo gespeichert.
#
# Probelauf, der auf GitHub nichts ändert (Ergebnis im Log unter ~/renovate/logs):
#   RENOVATE_DRY_RUN=full ~/renovate/run-renovate.sh
set -euo pipefail

LOG_DIR="$HOME/renovate/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/renovate-$(date +%Y%m%d-%H%M).log"

# Token des gh-Logins: Er sieht alle eigenen Repos (Scope repo, read:org). Der
# ältere Token in ~/.git-credentials sieht neuere private Repos nicht, mit
# Autodiscover fehlten die dann still. Für Updates an .github/workflows braucht
# er zusätzlich den Scope workflow (gh auth refresh -h github.com -s workflow).
TOKEN=$(gh auth token 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "gh ist nicht angemeldet (gh auth login)" >&2
  exit 1
fi

# Version und Digest fest: Das Image läuft mit dem vollen GitHub-Token. Renovate
# aktualisiert die Zeile selbst, aber erst 3 Tage nach einem Release (renovate.json).
# -e RENOVATE_DRY_RUN ohne Wert reicht die Variable nur durch, wenn sie gesetzt ist.
renovate_run() {  # $1=Überschrift im Log, Rest: zusätzliche docker-Optionen
  echo "=== $1 ===" >>"$LOG_FILE"
  shift
  docker run --rm \
    --memory=768m \
    -e RENOVATE_TOKEN="$TOKEN" \
    -e RENOVATE_REQUIRE_CONFIG=required \
    -e RENOVATE_ONBOARDING=false \
    -e RENOVATE_PLATFORM=github \
    -e RENOVATE_GIT_AUTHOR="Renovate Bot <193275228+Guppy997@users.noreply.github.com>" \
    -e RENOVATE_DRY_RUN \
    -e LOG_LEVEL=info \
    "$@" \
    renovate/renovate:44.199.2@sha256:0538f498be1b074e2434f8449cab7b2be30f8c0d0baf3b72814010f19db5bcfb >>"$LOG_FILE" 2>&1
}

# Zwei Läufe mit je eigenem Node-Prozess. Alle Repos in einem Lauf sprengten am
# 2026-11-05 beim Mesh (größtes Repo, kam zuletzt) den Heap (~384 MB bei 768 MB
# Container), allein lief das Mesh wochenlang ohne Probleme.
RC=0
renovate_run "Alle Repos außer luna-sovereign-mesh" \
  -e RENOVATE_AUTODISCOVER=true \
  -e RENOVATE_AUTODISCOVER_FILTER="Guppy997/*,bola-cat-industry/*,!Guppy997/luna-sovereign-mesh" || RC=$?
renovate_run "luna-sovereign-mesh" \
  -e RENOVATE_REPOSITORIES=Guppy997/luna-sovereign-mesh || RC=$?

# alte Logs aufräumen (letzte 14 behalten)
ls -1t "$LOG_DIR"/renovate-*.log 2>/dev/null | tail -n +15 | xargs -r rm --

if [ $RC -ne 0 ]; then
  # Die Fehlerzeilen statt des Log-Endes: Nach einem Absturz steht dort nur ein Stacktrace
  msg=$(grep -E ' (ERROR|FATAL): |FATAL ERROR' "$LOG_FILE" | tail -5 | cut -c1-200)
  [ -n "$msg" ] || msg=$(tail -c 500 "$LOG_FILE")
  # ntfy intern über die gepinnte ClusterIP (tailscale serve ab 1.104 nur über tailscale0)
  printf '%s\n\nLog: %s' "$msg" "$LOG_FILE" | curl -sf \
    -H "Title: Renovate-Lauf fehlgeschlagen (exit $RC)" \
    -H "Tags: warning" -H "Priority: high" \
    --data-binary @- \
    "http://10.43.235.81/luna-alerts" || true
fi
exit $RC
