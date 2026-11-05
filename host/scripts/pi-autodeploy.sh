#!/usr/bin/env bash
# Deployt die Host-Apps (Docker Compose) nach jedem Merge auf main selbst und
# zieht die Klone von luna-sovereign-mesh und luna-pwa nach.
#
# Pro App aus host/apps.txt: nur bei sauberem Working Tree auf main und nur, wenn
# alle Checks des neuen Commits auf GitHub grün sind. Dann Backup, fast-forward,
# Build mit --pull, warten bis backend und frontend healthy sind. Klappt das
# nicht, geht die App auf den alten Commit zurück und ntfy meldet sich. Einen
# fehlgeschlagenen Commit merkt sich das Skript, damit es nicht jede Nacht
# denselben Fehler wiederholt. Ein neuer Commit auf main wird wieder versucht.
#
# Home Assistant: Ändert sich host/apps/homeassistant/docker-compose.yml im
# Mesh-Klon (Renovate-PR für die HA-Version), wird die Datei nach ~/homeassistant
# kopiert und HA neu gestartet. Ohne Rollback, weil HA beim Start seine Config
# migriert; scheitert der Start, meldet ntfy das mit hoher Priorität.
#
# Läuft per systemd-Timer täglich um 04:15, nach den App-Backups (03:30–03:50).
#   --dry-run              nur anzeigen, was passieren würde
#   --simulate-fail <app>  Health-Check von <app> als fehlgeschlagen werten (Rollback testen)
#
# Ausgabezeilen mit LIVE / ROLLBACK / SKIP / SYNC liest weekly-report.sh aus dem
# Journal (journalctl -u pi-autodeploy).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
HOST_DIR=$(dirname "$SCRIPT_DIR")
MESH_DIR=$(dirname "$HOST_DIR")
STATE_DIR="$HOME/.local/state/pi-autodeploy"
HEALTH_TIMEOUT=300
# HA migriert beim ersten Start nach einem Update Datenbank und Config, das dauert
HA_TIMEOUT=600
# Intern über die gepinnte ClusterIP: tailscale serve nimmt ab 1.104 nur noch
# Verbindungen über tailscale0 an, vom Host selbst kommt man dort nicht hin.
NTFY_URL="http://10.43.235.81/luna-alerts"

DRY_RUN=0
SIMULATE_FAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --simulate-fail) SIMULATE_FAIL="${2:?App fehlt}"; shift ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "Läuft schon"; exit 0; }

notify() {  # $1=title $2=tags $3=priority $4=body
  [ "$DRY_RUN" = 1 ] && { echo "ntfy: $1 | $4" >&2; return 0; }
  printf '%b' "$4" | curl -sf --max-time 15 \
    -H "Title: $1" -H "Tags: $2" -H "Priority: $3" \
    --data-binary @- "$NTFY_URL" >/dev/null || true
}

run() {  # Befehl ausführen, bei --dry-run nur anzeigen
  if [ "$DRY_RUN" = 1 ]; then echo "  würde: $*"; else "$@"; fi
}

# Immer über den gh-Login holen: Die Klone haben unterschiedliche Credential-
# Helper (store, gh oder gar keinen), und der Token in ~/.git-credentials sieht
# neuere private Repos nicht.
git_fetch() {  # $1=dir
  git -C "$1" -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch -q origin main
}

repo_slug() {  # https://github.com/Guppy997/lern-pwa.git → Guppy997/lern-pwa
  git -C "$1" remote get-url origin | sed -E 's#^(https://|git@)github\.com[/:]##; s#\.git$##'
}

# Klon nur dann anfassen, wenn er sauber auf main steht. Gibt 1 zurück, wenn
# nicht, und meldet den Grund (lokale Arbeit soll nie überschrieben werden).
clean_on_main() {  # $1=dir $2=name
  local branch
  branch=$(git -C "$1" rev-parse --abbrev-ref HEAD)
  if [ "$branch" != main ]; then
    echo "SKIP $2: Branch $branch statt main"
    notify "Autodeploy: $2 übersprungen" "warning" "default" "Der Klon auf dem Pi steht auf $branch statt main."
    return 1
  fi
  if [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; then
    echo "SKIP $2: uncommittete Änderungen"
    notify "Autodeploy: $2 übersprungen" "warning" "default" "Im Klon auf dem Pi gibt es uncommittete Änderungen:\n$(git -C "$1" status --short --untracked-files=no | head -5)"
    return 1
  fi
}

# success = alle Check-Runs fertig und grün, pending = noch nicht fertig,
# failed = mindestens einer rot, none = gar keine Checks (dann kein Deploy)
checks_state() {  # $1=repo-slug $2=sha
  gh api "repos/$1/commits/$2/check-runs?per_page=100" --jq '
    .check_runs as $r
    | if ($r | length) == 0 then "none"
      elif any($r[]; .status != "completed") then "pending"
      elif all($r[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "success"
      else "failed" end'
}

# backend und frontend müssen healthy sein. "unhealthy" setzt Docker erst nach
# mehreren fehlgeschlagenen Checks, das ist also kein Zwischenzustand.
wait_healthy() {  # $1=dir $2=name
  [ "$DRY_RUN" = 1 ] && return 0
  [ "$SIMULATE_FAIL" = "$2" ] && { echo "  simuliere fehlgeschlagenen Health-Check"; return 1; }
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT )) states
  while [ "$(date +%s)" -lt "$deadline" ]; do
    states=$(cd "$1" && docker compose ps --format '{{.Service}}={{.Health}}' backend frontend) || states=""
    if ! grep -qv '=healthy$' <<<"$states" && [ "$(grep -c '=healthy$' <<<"$states")" -eq 2 ]; then
      return 0
    fi
    grep -q '=unhealthy$' <<<"$states" && break
    sleep 10
  done
  echo "  Zustand: $(tr '\n' ' ' <<<"$states")"
  return 1
}

build_and_start() {  # $1=dir
  (cd "$1" && run docker compose build --pull --quiet backend frontend && run docker compose up -d --quiet-pull)
}

deploy_app() {  # $1=name
  local name="$1" dir="$HOME/$1" slug old new state
  [ -d "$dir/.git" ] || { echo "SKIP $name: $dir fehlt"; return 0; }
  clean_on_main "$dir" "$name" || return 0

  git_fetch "$dir" || { echo "SKIP $name: git fetch fehlgeschlagen"; return 0; }
  old=$(git -C "$dir" rev-parse HEAD)
  new=$(git -C "$dir" rev-parse origin/main)
  [ "$old" = "$new" ] && { echo "$name: aktuell (${old:0:7})"; return 0; }
  if ! git -C "$dir" merge-base --is-ancestor "$old" "$new"; then
    echo "SKIP $name: lokale Commits, die nicht auf GitHub sind"
    notify "Autodeploy: $name übersprungen" "warning" "default" "Der Klon auf dem Pi hat Commits, die nicht auf GitHub sind. Erst pushen."
    return 0
  fi
  if [ "$(cat "$STATE_DIR/$name.failed" 2>/dev/null)" = "$new" ]; then
    echo "SKIP $name: ${new:0:7} ist schon einmal gescheitert"
    return 0
  fi

  slug=$(repo_slug "$dir")
  state=$(checks_state "$slug" "$new") || state=error
  case "$state" in
    success) ;;
    error) echo "SKIP $name: GitHub-API nicht erreichbar"; return 0 ;;
    pending) echo "SKIP $name: Checks für ${new:0:7} laufen noch"; return 0 ;;
    none)
      echo "SKIP $name: ${new:0:7} hat keine Checks"
      notify "Autodeploy: $name übersprungen" "warning" "default" "${new:0:7} hat auf GitHub keine Checks. Ohne grüne CI wird nicht deployt."
      return 0 ;;
    *)
      echo "SKIP $name: Checks für ${new:0:7} sind rot"
      notify "Autodeploy: $name übersprungen" "warning" "default" "Die CI für ${new:0:7} ist rot, live bleibt ${old:0:7}.\nhttps://github.com/$slug/commit/$new"
      return 0 ;;
  esac

  echo "$name: ${old:0:7} → ${new:0:7} ($(git -C "$dir" log -1 --format=%s "$new"))"
  # Dasselbe Backup wie der nächtliche Cron, direkt vor der Änderung
  if ! (cd "$dir" && run docker compose exec -T backend node src/backup.js); then
    echo "SKIP $name: Backup fehlgeschlagen"
    notify "Autodeploy: $name nicht deployt" "warning" "high" "Das Backup vor dem Update ist fehlgeschlagen, live bleibt ${old:0:7}."
    return 0
  fi

  local log
  log=$(mktemp)
  if run git -C "$dir" merge -q --ff-only "$new" \
     && build_and_start "$dir" >"$log" 2>&1 \
     && wait_healthy "$dir" "$name"; then
    rm -f "$log"
    [ "$DRY_RUN" = 1 ] || rm -f "$STATE_DIR/$name.failed"
    echo "LIVE $name ${old:0:7} → ${new:0:7}"
    notify "$name ist aktualisiert" "white_check_mark" "low" "${old:0:7} → ${new:0:7}\n$(git -C "$dir" log --format='• %s' "$old..$new" | head -8)"
    return 0
  fi

  echo "ROLLBACK $name ${new:0:7} → ${old:0:7}"
  local tail_log
  tail_log=$(tail -c 600 "$log"; cd "$dir" && docker compose logs --tail 15 backend frontend 2>&1 | tail -c 600)
  rm -f "$log"
  run git -C "$dir" reset -q --hard "$old"
  if build_and_start "$dir" >/dev/null 2>&1 && wait_healthy "$dir" "rollback-$name"; then
    [ "$DRY_RUN" = 1 ] || echo "$new" >"$STATE_DIR/$name.failed"
    notify "$name: Update zurückgerollt" "rotating_light" "high" "${new:0:7} wurde nicht healthy, live ist wieder ${old:0:7}.\nDer Commit wird nicht erneut versucht, erst der nächste.\n\n$tail_log"
  else
    notify "$name ist down" "rotating_light" "urgent" "Update auf ${new:0:7} gescheitert und der Rollback auf ${old:0:7} auch.\nPrüfen: cd ~/$name && docker compose ps\n\n$tail_log"
  fi
}

# Klone, aus denen nichts deployt wird, nur nachziehen: Im Mesh-Klon liegen
# backup.sh (Symlink) und die Host-Skripte, und kubara bootstrap läuft dort.
# Gibt den alten Commit auf stdout aus, damit der Aufrufer Änderungen sieht.
sync_clone() {  # $1=dir $2=name
  local dir="$1" name="$2" old new
  [ -d "$dir/.git" ] || return 0
  clean_on_main "$dir" "$name" >&2 || return 1
  git_fetch "$dir" || { echo "SKIP $name: git fetch fehlgeschlagen" >&2; return 1; }
  old=$(git -C "$dir" rev-parse HEAD)
  new=$(git -C "$dir" rev-parse origin/main)
  if [ "$old" != "$new" ]; then
    if ! git -C "$dir" merge-base --is-ancestor "$old" "$new"; then
      echo "SKIP $name: lokale Commits, die nicht auf GitHub sind" >&2
      notify "Autodeploy: $name nicht nachgezogen" "warning" "default" "Der Klon auf dem Pi hat Commits, die nicht auf GitHub sind. Erst pushen."
      return 1
    fi
    run git -C "$dir" merge -q --ff-only "$new" >&2
    echo "SYNC $name ${old:0:7} → ${new:0:7}" >&2
  fi
  echo "$old"
}

update_homeassistant() {  # $1=alter Mesh-Commit
  local src="$HOST_DIR/apps/homeassistant/docker-compose.yml" dst="$HOME/homeassistant/docker-compose.yml"
  [ -f "$dst" ] || return 0
  cmp -s "$src" "$dst" && return 0
  local subject
  subject=$(git -C "$MESH_DIR" log -1 --format=%s "$1".. -- "$src")
  echo "homeassistant: Compose-Datei geändert${subject:+ ($subject)}"
  run install -m 0644 "$src" "$dst"
  (cd "$HOME/homeassistant" && run docker compose up -d --quiet-pull) >/dev/null 2>&1 || true
  [ "$DRY_RUN" = 1 ] && return 0
  local deadline=$(( $(date +%s) + HA_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:8123/manifest.json; then
      echo "LIVE homeassistant $(grep -oE 'home-assistant:[^ ]+' "$dst")"
      notify "Home Assistant ist aktualisiert" "white_check_mark" "low" "$(grep -oE 'home-assistant:[^ ]+' "$dst")"
      return 0
    fi
    sleep 10
  done
  echo "ROLLBACK homeassistant: antwortet nicht (kein automatischer Rollback)"
  notify "Home Assistant antwortet nicht" "rotating_light" "high" "Nach dem Update auf $(grep -oE 'home-assistant:[^ ]+' "$dst") antwortet :8123 seit 10 min nicht.\nLogs: docker logs --tail 50 homeassistant\nZurück: Version in host/apps/homeassistant/docker-compose.yml per Revert-PR, oder von Hand in ~/homeassistant/docker-compose.yml."
}

[ "$DRY_RUN" = 1 ] && echo "(dry-run, es wird nichts geändert)"

# Erst die Liste lesen, dann deployen: docker compose exec (Backup) liest stdin
# und hat in einer while-read-Schleife den Rest von apps.txt verschluckt. Am
# 2026-11-05 wurde deshalb nur die erste App deployt.
mapfile -t apps < <(awk '!/^[[:space:]]*(#|$)/ {print $1}' "$HOST_DIR/apps.txt")
for app in "${apps[@]}"; do
  deploy_app "$app" </dev/null
done

sync_clone "$HOME/luna-pwa" luna-pwa >/dev/null || true
# Bash liest das Skript stückweise; git ersetzt Dateien über neue Inodes, das
# laufende Skript liest also weiter die alte Fassung. Trotzdem als Letztes.
if mesh_old=$(sync_clone "$MESH_DIR" luna-sovereign-mesh); then
  update_homeassistant "$mesh_old"
fi

if [ "$DRY_RUN" = 0 ]; then
  docker image prune -f >/dev/null
  docker builder prune -f --filter until=168h >/dev/null
fi
