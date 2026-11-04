#!/usr/bin/env bash
# Wochenbericht per ntfy, sonntags 18:00: alles rund um Updates in einer
# Nachricht. Den Zustand des Clusters meldet schon der tägliche Health-Digest
# (07:00, clusters/dev/apps/automation), hier steht nur, was dort fehlt:
#   - offene PRs aller eigenen Repos (auch Dependabot bei Wedding-Kids-PWA) und
#     Majors, die im Dependency Dashboard auf ein Häkchen warten
#   - was pi-autodeploy in der Woche deployt, übersprungen oder zurückgerollt hat
#   - Renovate, ausstehender Neustart, apt-Updates
#   - Backup, Platte, RAM, Ablauf des Tailscale-Keys
#
#   --print  nur ausgeben, nicht senden
set -uo pipefail

NTFY_URL="http://10.43.235.81/luna-alerts"
OWNERS=(--owner Guppy997 --owner bola-cat-industry)
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

todo=()   # braucht Aaron
info=()   # nur zur Kenntnis
now=$(date +%s)

# ── GitHub ───────────────────────────────────────────────────────────────────
if prs=$(gh search prs "${OWNERS[@]}" --state open --archived=false --limit 100 \
           --json repository,number,title,createdAt 2>/dev/null); then
  # PRs, die älter als 3 Tage sind: Renovate-Automerge hätte sie sonst längst erledigt
  stale=$(jq -r --argjson now "$now" '.[]
    | select(($now - (.createdAt | fromdateiso8601)) > 3*86400)
    | "\(.repository.name)#\(.number) \(.title[0:70])"' <<<"$prs")
  total=$(jq length <<<"$prs")
  [ -n "$stale" ] && todo+=("PRs, die seit über 3 Tagen offen sind:\n$(sed 's/^/• /' <<<"$stale")")
  [ "$total" -gt 0 ] && [ -z "$stale" ] && info+=("$total offene PRs, alle jünger als 3 Tage")
else
  todo+=("GitHub nicht erreichbar (gh search)")
fi

if dash=$(gh search issues "${OWNERS[@]}" --state open --archived=false --match title \
            "Dependency Dashboard" --json repository,body 2>/dev/null); then
  majors=$(jq -r '.[] | (.body | [scan("- \\[ \\] <!-- approve-branch=")] | length) as $n
                  | select($n > 0) | "\(.repository.name): \($n)"' <<<"$dash")
  [ -n "$majors" ] && info+=("Majors warten auf ein Häkchen im Dependency Dashboard:\n$(sed 's/^/• /' <<<"$majors")")
fi

# ── Pi: Deploys, Renovate, Pakete ────────────────────────────────────────────
deploys=$(journalctl -u pi-autodeploy --since "-7 days" -o cat --no-pager 2>/dev/null \
  | grep -E '^(LIVE|ROLLBACK|SKIP) ' | sort | uniq -c | sed -E 's/^ *1 //; s/^ *([0-9]+) (.*)/\2 (\1×)/')
if [ -n "$deploys" ]; then
  if grep -qE '^(ROLLBACK|SKIP) ' <<<"$deploys"; then
    todo+=("pi-autodeploy:\n$(sed 's/^/• /' <<<"$deploys")")
  else
    info+=("Deployt:\n$(sed 's/^/• /' <<<"$deploys")")
  fi
fi

last_log=$(ls -1t "$HOME"/renovate/logs/renovate-*.log 2>/dev/null | head -1)
if [ -z "$last_log" ] || [ $(( now - $(stat -c %Y "$last_log") )) -gt $(( 2 * 86400 )) ]; then
  todo+=("Renovate ist seit über 2 Tagen nicht gelaufen")
else
  repos=$(grep -c 'Repository finished' "$last_log")
  errors=$(grep -c ' ERROR: ' "$last_log")
  if [ "$errors" -gt 0 ]; then
    todo+=("Renovate: $errors Fehler im letzten Lauf ($last_log)")
  else
    info+=("Renovate: letzter Lauf $(date -r "$last_log" '+%a %H:%M'), $repos Repos")
  fi
fi

[ -f /var/run/reboot-required ] && info+=("Neustart steht an (So 04:30 automatisch): $(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')")
upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1 | tr '\n' ' ')
[ -n "$upgradable" ] && info+=("apt, nicht automatisch: $upgradable")

# ── Backup, Ressourcen, Tailscale ────────────────────────────────────────────
newest=$(ls -1d /mnt/backup/20*/ 2>/dev/null | tail -1)
if [ -z "$newest" ]; then
  todo+=("Kein Backup unter /mnt/backup (Stick gemountet?)")
else
  age=$(( (now - $(date -d "$(basename "$newest")" +%s)) / 86400 ))
  [ "$age" -gt 1 ] && todo+=("Letztes Backup ist $age Tage alt ($(basename "$newest"))")
fi

disk=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$disk" -ge 85 ] && todo+=("Platte zu ${disk}% voll")
mem=$(free -m | awk '/^Mem:/ {print $7}')
info+=("Platte ${disk}% belegt, ${mem} MB RAM frei")

expiry=$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // empty')
if [ -n "$expiry" ]; then
  days=$(( ($(date -d "$expiry" +%s) - now) / 86400 ))
  [ "$days" -lt 30 ] && todo+=("Tailscale-Key des Pi läuft in $days Tagen ab: Admin-Console → Machines → Disable key expiry")
fi

# ── Senden ───────────────────────────────────────────────────────────────────
if [ ${#todo[@]} -eq 0 ]; then
  title="Wochenbericht: nichts zu tun"; tags="white_check_mark"; prio="low"
else
  title="Wochenbericht: ${#todo[@]} Punkt(e) für dich"; tags="clipboard"; prio="default"
fi
body=""
for t in "${todo[@]}"; do body+="$t\n\n"; done
[ ${#info[@]} -gt 0 ] && body+="Zur Info:\n"
for i in "${info[@]}"; do body+="$i\n"; done

if [ "$PRINT" = 1 ]; then
  printf '%s\n\n%b' "$title" "$body"
  exit 0
fi
printf '%b' "$body" | curl -sf --max-time 15 \
  -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
  --data-binary @- "$NTFY_URL" >/dev/null
