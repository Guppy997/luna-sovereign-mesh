#!/bin/bash
# Pi Backup → /mnt/backup
#
# Konsolidiert aus den beiden vorher parallel um 03:00 laufenden Skripten
# (/home/aaron/backup.sh via /etc/cron.d/pi-backup + /usr/local/bin/kubara-backup.sh
# via kubara-backup.timer). Die beiden sicherten affine-storage, vaultwarden und
# beide Postgres-DBs doppelt und kollidierten dabei auf demselben USB-Stick,
# waren aber einzeln jeweils unvollständig. Zusammengelegt 2026-07-26.
#
# Zwei Dinge, die vorher fehlten und hier bewusst drin sind:
#   1. Der Stick ist exFAT → kein POSIX-chmod. Ein `chmod 600` auf den
#      Secret-Dump war wirkungslos, die Datei lag als 0755 da. Alles, was
#      Credentials enthält, wird deshalb mit age verschlüsselt (s. AGE_*).
#   2. Fehlschläge waren stumm: `set -e` brach ab, ohne dass jemand es erfuhr.
#      Jetzt hängt ein ERR-Trap an ntfy.
#
# Seit 2026-10-23 landet NICHTS mehr im Klartext auf dem Stick: jede Quelle wird
# erst in ein root-only Staging-Verzeichnis auf der SSD kopiert (konsistente
# SQLite-Snapshots inklusive) und dann als <name>.tar.age bzw. <db>.sql.age
# abgelegt. Restore:
#   age -d -i <key> lern-pwa.tar.age | tar -x -C <ziel>
# <key> ist der Recovery-Key (offline) oder, auf einem intakten Pi, der SOPS-Key.

set -euo pipefail

BACKUP_ROOT="/mnt/backup"
DATE=$(date +%Y-%m-%d)
DEST="$BACKUP_ROOT/$DATE"
LOG="$BACKUP_ROOT/backup.log"
RETENTION_DAYS=14
K3S_STORAGE="/var/lib/rancher/k3s/storage"
KUBECTL="/usr/local/bin/kubectl"
NTFY="http://10.43.235.81/luna-alerts"   # ntfy ClusterIP (gepinnt, s. project-luna)

# Recovery-Key: Privatteil liegt NICHT auf dem Pi (Aaron hält ihn offline).
# Zusätzlich als Zweit-Empfänger der SOPS-age-Key, damit ein Restore auf einem
# intakten Pi ohne Griff zum Passwortmanager funktioniert.
AGE_RECOVERY="age16ggvcgzy0n6mkdgx2x9rmqmfe8r8gjjgshknkxdv6df9h4c73das7vcwhp"
AGE_SOPS="age1dsnr0ejf7acutf5cqa9nj22a6ga7pdu8ph9dw5ymwnerx2t63uas56sua9"
SOPS_KEY="/home/aaron/.config/sops/age/keys.txt"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

notify() {  # $1=prio $2=title $3=text
  curl -fsS --max-time 15 -H "Priority: $1" -H "Title: $2" -d "$3" "$NTFY" >/dev/null 2>&1 || true
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  log "FEHLER: Abbruch in Zeile $line (exit $rc)"
  notify urgent "Pi-Backup FEHLGESCHLAGEN" "Abbruch in Zeile $line (exit $rc) — siehe $LOG"
  exit "$rc"
}
trap on_error ERR

# age-verschlüsselt von stdin → $1
enc_to() { age -r "$AGE_RECOVERY" -r "$AGE_SOPS" -o "$1"; }

# Staging auf der SSD statt auf dem exFAT-Stick: dort gibt es keine Rechte,
# ein Klartext-Zwischenstand wäre für jeden lesbar. mktemp legt 0700 an.
STAGE_ROOT="/var/tmp/pi-backup-stage"
mkdir -p "$STAGE_ROOT" && chmod 700 "$STAGE_ROOT"
trap 'rm -rf "$STAGE_ROOT"/tmp.*' EXIT

# Staging-Verzeichnis als tar → $DEST/$2.tar.age, danach weg damit.
enc_stage() {  # $1=staging-dir $2=name
  tar -C "$1" -cf - . | enc_to "$DEST/$2.tar.age"
  rm -rf "$1"
}

# PVC-Pfad über kubectl auflösen statt UUID hardcoden: die alten Skripte hatten
# die pvc-<uuid>-Pfade fest eingetragen — nach einem PVC-Neubau hätten sie
# stillschweigend ins Leere gesichert.
pvc_path() {  # $1=namespace $2=pvc-name
  local vol
  vol=$($KUBECTL get pvc -n "$1" "$2" -o jsonpath='{.spec.volumeName}' 2>/dev/null) || return 1
  [ -n "$vol" ] || return 1
  local p="$K3S_STORAGE/${vol}_${1}_${2}"
  [ -d "$p" ] || return 1
  echo "$p"
}

# Konsistenter SQLite-Snapshot statt Dateikopie.
# Alle drei SQLite-DBs hier (vaultwarden, lern-pwa, fitness-pwa) laufen im
# WAL-Modus. Ein rsync/tar kopiert db, -wal und -shm zu drei verschiedenen
# Zeitpunkten — schreibt die App dazwischen, passt der WAL nicht mehr zur
# Basisdatei und der Restore ist im besten Fall veraltet, im schlechtesten
# inkonsistent. `.backup` nutzt die Online-Backup-API von SQLite und liefert
# EINE konsistente Datei, auch während die App schreibt.
backup_sqlite() {  # $1=quell-db $2=ziel-db
  sqlite3 "$1" ".backup '$2'"
  local chk
  chk=$(sqlite3 "$2" 'pragma quick_check;' 2>&1 | head -1)
  if [ "$chk" != "ok" ]; then
    log "  FEHLER: Snapshot $2 defekt (quick_check: $chk)"
    return 1
  fi
}

enc_pvc() {  # $1=namespace $2=pvc $3=name
  local src stage
  if ! src=$(pvc_path "$1" "$2"); then
    log "  WARNUNG: PVC $1/$2 nicht auflösbar — übersprungen"
    notify default "Pi-Backup: PVC fehlt" "$1/$2 nicht gefunden, nicht gesichert"
    return 0
  fi
  # rsync statt direktem tar: tar bricht ab, wenn die App während des Lesens
  # eine Datei ändert, rsync nimmt den Stand, den es sieht.
  stage=$(mktemp -d -p "$STAGE_ROOT")
  rsync -rlt --no-o --no-g --no-perms "$src/" "$stage/"
  enc_stage "$stage" "$3"
}

if ! mountpoint -q "$BACKUP_ROOT"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $BACKUP_ROOT nicht gemountet" >> /var/log/backup-error.log
  notify urgent "Pi-Backup FEHLGESCHLAGEN" "$BACKUP_ROOT ist nicht gemountet"
  exit 1
fi

log "=== Backup gestartet ==="
mkdir -p "$DEST"

# ── Datenbanken ───────────────────────────────────────────────────────────────
# Direkt in age gepiped, es entsteht keine Klartext-Zwischendatei.
log "AFFiNE PostgreSQL dump (verschlüsselt)..."
$KUBECTL exec -n affine postgres-0 -c postgres -- pg_dump -U affine affine \
  | enc_to "$DEST/affine-postgres.sql.age"

log "Plane PostgreSQL dump (verschlüsselt)..."
$KUBECTL exec -n plane postgresql-0 -c postgresql -- pg_dump -U plane plane \
  | enc_to "$DEST/plane-postgres.sql.age"

# ── PVCs ──────────────────────────────────────────────────────────────────────
# affine-storage komplett (Blobs + config/ mit AFFiNEs EC-Private-Key), ~270 MB.
# age schafft auf dem Pi 5 mehrere 100 MB/s, das kostet nur Sekunden.
log "AFFiNE Dateispeicher (verschlüsselt)..."
enc_pvc affine affine-storage affine-storage

log "MinIO / Plane-Uploads (verschlüsselt)..."
enc_pvc plane minio-data minio-data

log "Beaver Habits (verschlüsselt)..."
enc_pvc beaverhabits beaverhabits-data beaverhabits-data

# Vaultwarden enthält rsa_key.pem + Passwort-Hashes → verschlüsselt ablegen.
# db.sqlite3 kommt als konsistenter Snapshot dazu, der Rest (attachments, sends,
# rsa_key.pem) per rsync in ein Staging-Verzeichnis.
log "Vaultwarden (verschlüsselt)..."
if vw=$(pvc_path vaultwarden vaultwarden-data); then
  stage=$(mktemp -d -p "$STAGE_ROOT")
  rsync -rlt --no-o --no-g --no-perms --exclude='db.sqlite3*' "$vw/" "$stage/"
  backup_sqlite "$vw/db.sqlite3" "$stage/db.sqlite3"
  enc_stage "$stage" vaultwarden-data
else
  log "  WARNUNG: PVC vaultwarden/vaultwarden-data nicht auflösbar — übersprungen"
  notify default "Pi-Backup: PVC fehlt" "vaultwarden-data nicht gefunden"
fi

# ── Docker-/Host-Anwendungen ──────────────────────────────────────────────────
# Die drei PWAs folgen demselben Muster: data/ ohne die Live-DB kopieren, dazu
# ein konsistenter SQLite-Snapshot, alles zusammen verschlüsselt.
# (Fitness-PWA fehlte in BEIDEN alten Skripten komplett, ergänzt 2026-07-26.)
backup_pwa() {  # $1=name $2=db-dateiname
  local stage
  log "$1 SQLite (verschlüsselt)..."
  stage=$(mktemp -d -p "$STAGE_ROOT")
  rsync -rlt --no-o --no-g --no-perms --exclude="$2*" "/home/aaron/$1/data/" "$stage/"
  backup_sqlite "/home/aaron/$1/data/$2" "$stage/$2"
  enc_stage "$stage" "$1"
}
backup_pwa lern-pwa lern.sqlite
backup_pwa fitness-pwa fitness.sqlite
backup_pwa ausrichtung ausrichtung.sqlite

log "Home Assistant Config (verschlüsselt)..."
stage=$(mktemp -d -p "$STAGE_ROOT")
rsync -rlt --no-o --no-g --no-perms --exclude='*.log*' --exclude='.storage/*.corrupt*' \
  --exclude='home-assistant_v2.db*' \
  /home/aaron/homeassistant/config/ "$stage/"
# Recorder-DB ebenfalls WAL-Modus (4 MB WAL bei 2 MB Basisdatei)
backup_sqlite /home/aaron/homeassistant/config/home-assistant_v2.db \
  "$stage/home-assistant_v2.db"
enc_stage "$stage" homeassistant

# Pi-hole: kritischster Dienst — DNS-Upstream für LAN, Tailnet UND Cluster
log "Pi-hole Config + Gravity (verschlüsselt)..."
stage=$(mktemp -d -p "$STAGE_ROOT")
rsync -rlt --no-o --no-g --no-perms /etc/pihole/ "$stage/etc-pihole/"
[ -d /etc/dnsmasq.d ] && rsync -rlt --no-o --no-g --no-perms /etc/dnsmasq.d/ "$stage/etc-dnsmasq.d/"
enc_stage "$stage" pihole

# ── Secrets (immer verschlüsselt) ─────────────────────────────────────────────
log "K8s-Secrets (verschlüsselt)..."
$KUBECTL get secrets -A --field-selector type!=kubernetes.io/service-account-token -o yaml \
  | enc_to "$DEST/k8s-secrets.yaml.age"

# SOPS-age-Key: NUR an den Recovery-Key adressiert. An seinen eigenen Public Key
# verschlüsselt wäre er als Recovery-Artefakt wertlos (zum Entschlüsseln bräuchte
# man genau den Key, der drin steckt).
log "SOPS-age-Key (nur an Recovery-Key)..."
if [ -f "$SOPS_KEY" ]; then
  age -r "$AGE_RECOVERY" -o "$DEST/sops-age-key.txt.age" < "$SOPS_KEY"
else
  log "  WARNUNG: $SOPS_KEY nicht gefunden"
  notify default "Pi-Backup: SOPS-Key fehlt" "$SOPS_KEY nicht vorhanden"
fi

# ── Aufräumen ─────────────────────────────────────────────────────────────────
# Erst NACH dem erfolgreichen Lauf: ein Abbruch oben soll nie dazu führen, dass
# alte Stände weg sind und der neue unvollständig ist.
log "Alte Backups aufräumen (>$RETENTION_DAYS Tage)..."
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name "20*" \
  -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true

USED=$(du -sh "$DEST" | cut -f1)
FREE=$(df -h "$BACKUP_ROOT" | awk 'NR==2{print $4}')
log "Backup fertig — Größe: $USED | USB frei: $FREE"
log "=== Backup abgeschlossen ==="
