#!/usr/bin/env bash
# restore.sh – spielt ein Backup vom USB-Stick zurück (Gegenstück zu host/backup.sh).
#
#   ./restore.sh latest                      alles vom neuesten Stand
#   ./restore.sh 2026-10-24                  bestimmter Tag
#   ./restore.sh latest --dry-run            nur prüfen und anzeigen, schreibt nichts
#   ./restore.sh latest pihole pwas          nur einzelne Teile
#
# Teile: affine plane vaultwarden beaverhabits pwas homeassistant pihole (Standard: alle)
#
# Schlüssel: der SOPS-Key (~/.config/sops/age/keys.txt) oder, per AGE_IDENTITY=<datei>,
# der Recovery-Key. backup.sh verschlüsselt jedes Archiv an beide.
#
# Vorgehen je Teil: App stoppen bzw. auf 0 skalieren, Daten ersetzen, Besitzer setzen,
# wieder starten. Argo CD würde runterskalierte Deployments sofort zurückdrehen
# (selfHeal), deshalb wird die jeweilige Application währenddessen per
# skip-reconcile angehalten. Nicht zurückgespielt werden k8s-secrets.yaml.age (die
# Secrets kommen SOPS-verschlüsselt aus dem Repo) und sops-age-key.txt.age (den
# braucht man VOR dem Restore, siehe docs/disaster-recovery.md).
set -Eeuo pipefail

BACKUP_ROOT=/mnt/backup
K3S_STORAGE=/var/lib/rancher/k3s/storage
IDENTITY=${AGE_IDENTITY:-$HOME/.config/sops/age/keys.txt}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
ALL_PARTS=(affine plane vaultwarden beaverhabits pwas homeassistant pihole)

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
plan() { printf '    würde: %s\n' "$*"; }
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO (exit $?)"' ERR

# ── Argumente ────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || die "Aufruf: $0 <YYYY-MM-DD|latest> [--dry-run] [teil ...]"
WHEN=$1
shift
DRY=0
PARTS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    affine|plane|vaultwarden|beaverhabits|pwas|homeassistant|pihole) PARTS+=("$a") ;;
    *) die "Unbekannter Teil: $a (erlaubt: ${ALL_PARTS[*]})" ;;
  esac
done
[ ${#PARTS[@]} -gt 0 ] || PARTS=("${ALL_PARTS[@]}")

mountpoint -q "$BACKUP_ROOT" || die "$BACKUP_ROOT ist nicht gemountet (Stick eingesteckt? sudo mount /mnt/backup)"
if [ "$WHEN" = latest ]; then
  DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' | sort | tail -1)
else
  DIR="$BACKUP_ROOT/$WHEN"
fi
[ -n "$DIR" ] && [ -d "$DIR" ] || die "Kein Backup für '$WHEN' unter $BACKUP_ROOT"
[ -r "$IDENTITY" ] || die "Age-Schlüssel nicht lesbar: $IDENTITY"

docker=(docker)
docker info >/dev/null 2>&1 || docker=(sudo docker)

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────
dec() { age -d -i "$IDENTITY" "$DIR/$1"; }

need() {  # $1=archiv
  [ -f "$DIR/$1" ] || die "Archiv fehlt: $DIR/$1"
}

# Prüft ein Archiv, ohne etwas zu schreiben: entschlüsselbar und lesbar?
verify() {  # $1=archiv
  need "$1"
  local size n
  size=$(du -h "$DIR/$1" | cut -f1)
  if [[ "$1" == *.sql.age ]]; then
    n=$(dec "$1" | grep -c -E '^(CREATE|COPY|ALTER) ' || true)
    [ "$n" -gt 0 ] || die "$1: kein gültiger SQL-Dump"
    ok "$1 ($size): $n CREATE/COPY/ALTER-Anweisungen"
  else
    n=$(dec "$1" | tar -tf - | wc -l)
    ok "$1 ($size): $n Einträge"
  fi
}

# Wie pvc_path() in host/backup.sh
pvc_path() {  # $1=namespace $2=pvc-name
  local vol p
  vol=$(kubectl get pvc -n "$1" "$2" -o jsonpath='{.spec.volumeName}' 2>/dev/null) || return 1
  [ -n "$vol" ] || return 1
  p="$K3S_STORAGE/${vol}_${1}_${2}"
  sudo test -d "$p" || return 1
  echo "$p"
}

# Häufigster Besitzer der vorhandenen Dateien (die App hat sie angelegt), sonst der
# des Ordners selbst. Das Backup speichert keine Besitzer (rsync --no-o/--no-g).
owner_of() {  # $1=pfad
  local o
  o=$(sudo find "$1" -mindepth 1 -printf '%u:%g\n' 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
  [ -n "$o" ] || o=$(sudo stat -c '%u:%g' "$1")
  echo "$o"
}

# Inhalt eines Ordners durch ein tar-Archiv ersetzen
replace_dir() {  # $1=ziel $2=archiv $3=besitzer
  sudo find "$1" -mindepth 1 -delete
  dec "$2" | sudo tar -x -C "$1" --no-same-owner
  # Nur den Inhalt umstellen: der Ordner selbst behält Besitzer und setgid-Bit
  sudo find "$1" -mindepth 1 -exec chown -h "$3" {} +
  sudo find "$1" \( -name '*.sqlite-wal' -o -name '*.sqlite-shm' -o -name '*.sqlite3-wal' -o -name '*.sqlite3-shm' \) -delete
}

argo_pause() {
  kubectl -n argocd annotate application "luna-sovereign-mesh-$1" argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null
}
argo_resume() {
  kubectl -n argocd annotate application "luna-sovereign-mesh-$1" argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
  kubectl -n argocd annotate application "luna-sovereign-mesh-$1" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

# Alle Deployments/StatefulSets eines Namespace außer den Datenbanken auf 0;
# merkt sich die Replicas in SCALED[]
SCALED=()
scale_down() {  # $1=namespace $2=regex der Workloads, die laufen bleiben
  local w r
  while read -r w r; do
    [[ "$w" =~ $2 ]] && continue
    SCALED+=("$1 $w $r")
    kubectl -n "$1" scale "$w" --replicas=0 >/dev/null
  done < <(kubectl -n "$1" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas}{"\n"}{end}' | sed 's#^Deployment/#deployment/#; s#^StatefulSet/#statefulset/#')
  # Nur laufende/startende Pods zählen; fertige Job-Pods (z. B. minio-init) bleiben stehen
  local i n
  for i in $(seq 1 60); do
    n=$(kubectl -n "$1" get pods --no-headers --field-selector=status.phase!=Succeeded,status.phase!=Failed 2>/dev/null \
      | awk '{print $1}' | grep -cvE "$2" || true)
    [ "$n" -eq 0 ] && return 0
    sleep 3
  done
  die "Pods in $1 sind nach 3 min noch nicht beendet"
}
scale_up() {  # $1=namespace
  local e ns w r
  for e in "${SCALED[@]}"; do
    read -r ns w r <<<"$e"
    [ "$ns" = "$1" ] && kubectl -n "$ns" scale "$w" --replicas="$r" >/dev/null
  done
}

restore_pg() {  # $1=ns $2=pod $3=container $4=user/db $5=archiv
  kubectl -n "$1" exec "$2" -c "$3" -- psql -U "$4" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "DROP DATABASE IF EXISTS \"$4\" WITH (FORCE);" -c "CREATE DATABASE \"$4\" OWNER \"$4\";" >/dev/null
  dec "$5" | kubectl -n "$1" exec -i "$2" -c "$3" -- psql -U "$4" -d "$4" -v ON_ERROR_STOP=1 -q >/dev/null
  ok "Datenbank $1/$4 aus $5"
}

restore_pvc() {  # $1=ns $2=pvc $3=archiv
  local p o
  p=$(pvc_path "$1" "$2") || die "PVC $1/$2 nicht gefunden. Hat Argo CD die App schon ausgerollt?"
  o=$(owner_of "$p")
  replace_dir "$p" "$3" "$o"
  ok "PVC $1/$2 aus $3 (Besitzer $o)"
}

# ── Teile ────────────────────────────────────────────────────────────────────
# Je Namespace: Argo anhalten, Apps runter, DB/PVCs ersetzen, Apps hoch, Argo weiter.
part_k8s() {  # $1=app/namespace $2=regex-bleibt-an $3=pg-pod $4=pg-container $5=pg-user/db $6=sql-archiv  dann Paare pvc archiv
  local app=$1 keep=$2 pgpod=$3 pgc=$4 pgdb=$5 sql=$6
  shift 6
  log "$app"
  if [ -n "$sql" ]; then verify "$sql"; fi
  local args=("$@") i
  for ((i = 0; i < ${#args[@]}; i += 2)); do verify "${args[i+1]}"; done
  if [ "$DRY" = 1 ]; then
    plan "Argo-App luna-sovereign-mesh-$app anhalten, in $app alles außer /$keep/ auf 0 skalieren"
    if [ -n "$sql" ]; then plan "Datenbank $pgdb neu anlegen und aus $sql füllen"; fi
    for ((i = 0; i < ${#args[@]}; i += 2)); do plan "PVC $app/${args[i]} leeren und aus ${args[i+1]} füllen"; done
    plan "wieder hochskalieren, Argo-App fortsetzen"
    return
  fi
  argo_pause "$app"
  trap 'argo_resume "'"$app"'"; die "Abbruch in Zeile $LINENO (exit $?)"' ERR
  scale_down "$app" "$keep"
  if [ -n "$sql" ]; then restore_pg "$app" "$pgpod" "$pgc" "$pgdb" "$sql"; fi
  for ((i = 0; i < ${#args[@]}; i += 2)); do restore_pvc "$app" "${args[i]}" "${args[i+1]}"; done
  scale_up "$app"
  argo_resume "$app"
  trap 'die "Abbruch in Zeile $LINENO (exit $?)"' ERR
  ok "$app läuft wieder"
}

part_pwas() {
  local app pwa_db
  for app in lern-pwa fitness-pwa ausrichtung; do
    log "$app"
    verify "$app.tar.age"
    if [ "$DRY" = 1 ]; then
      plan "Backend stoppen, ~/$app/data ersetzen, Backend starten"
      continue
    fi
    [ -d "$HOME/$app/data" ] || die "$HOME/$app/data fehlt (erst bootstrap.sh)"
    (cd "$HOME/$app" && "${docker[@]}" compose stop backend >/dev/null)
    replace_dir "$HOME/$app/data" "$app.tar.age" "$(owner_of "$HOME/$app/data")"
    (cd "$HOME/$app" && "${docker[@]}" compose start backend >/dev/null)
    pwa_db=$(sudo find "$HOME/$app/data" -maxdepth 1 -name '*.sqlite' | head -1)
    ok "$app ($(sudo sqlite3 "$pwa_db" 'pragma quick_check;' 2>&1 | head -1))"
  done
}

part_homeassistant() {
  log "homeassistant"
  verify homeassistant.tar.age
  if [ "$DRY" = 1 ]; then
    plan "Container stoppen, ~/homeassistant/config ersetzen, Container starten"
    return
  fi
  [ -d "$HOME/homeassistant/config" ] || die "$HOME/homeassistant/config fehlt (erst bootstrap.sh)"
  (cd "$HOME/homeassistant" && "${docker[@]}" compose stop >/dev/null)
  replace_dir "$HOME/homeassistant/config" homeassistant.tar.age "$(owner_of "$HOME/homeassistant/config")"
  (cd "$HOME/homeassistant" && "${docker[@]}" compose start >/dev/null)
  ok "homeassistant"
}

part_pihole() {
  log "pihole"
  verify pihole.tar.age
  if [ "$DRY" = 1 ]; then
    plan "pihole-FTL stoppen, /etc/pihole und /etc/dnsmasq.d ersetzen, FTL starten"
    return
  fi
  command -v pihole >/dev/null || die "Pi-hole ist nicht installiert (erst bootstrap.sh)"
  local tmp
  tmp=$(sudo mktemp -d)
  dec pihole.tar.age | sudo tar -x -C "$tmp" --no-same-owner
  sudo systemctl stop pihole-FTL
  sudo rsync -a --delete "$tmp/etc-pihole/" /etc/pihole/
  if sudo test -d "$tmp/etc-dnsmasq.d"; then
    sudo rsync -a --delete "$tmp/etc-dnsmasq.d/" /etc/dnsmasq.d/
  fi
  sudo chown -R pihole:pihole /etc/pihole
  sudo rm -rf "$tmp"
  sudo systemctl start pihole-FTL
  ok "pihole ($(dig @127.0.0.1 +short +time=3 +tries=1 example.com A >/dev/null 2>&1 && echo "DNS antwortet" || echo "DNS antwortet NOCH NICHT"))"
}

# ── Ablauf ───────────────────────────────────────────────────────────────────
log "Backup $(basename "$DIR")$([ "$DRY" = 1 ] && echo " (Dry-Run, es wird nichts geschrieben)")"
for p in "${PARTS[@]}"; do
  case "$p" in
    affine)       part_k8s affine 'postgres|redis' postgres-0 postgres affine affine-postgres.sql.age \
                    affine-storage affine-storage.tar.age ;;
    plane)        part_k8s plane 'postgresql|redis|rabbitmq|valkey' postgresql-0 postgresql plane plane-postgres.sql.age \
                    minio-data minio-data.tar.age ;;
    vaultwarden)  part_k8s vaultwarden '^$' '' '' '' '' vaultwarden-data vaultwarden-data.tar.age ;;
    beaverhabits) part_k8s beaverhabits '^$' '' '' '' '' beaverhabits-data beaverhabits-data.tar.age ;;
    pwas)         part_pwas ;;
    homeassistant) part_homeassistant ;;
    pihole)       part_pihole ;;
  esac
done
log "Fertig$([ "$DRY" = 1 ] && echo " (Dry-Run)")"
