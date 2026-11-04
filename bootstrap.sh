#!/usr/bin/env bash
# bootstrap.sh – bringt einen frisch installierten Pi auf den Stand dieses Repos.
#
#   ./bootstrap.sh            Host und Cluster
#   ./bootstrap.sh host       nur Host (Pakete, Dienste, Configs, Host-Apps)
#   ./bootstrap.sh cluster    nur Cluster (Secrets, Argo CD, Applications)
#
# Idempotent: Jeder Schritt prüft erst, ob er schon erledigt ist; ein zweiter Lauf
# ändert nichts mehr. Voraussetzungen und Gesamtablauf: docs/disaster-recovery.md.
# Danach die Daten mit ./restore.sh latest zurückspielen.
#
# Gibt nie Secret-Werte aus. Secrets laufen nur von `sops -d` direkt in kubectl oder
# in Dateien mit Modus 0600; die kubara-Ausgabe wird gefiltert, weil kubara das
# Argo-CD-Passwort im Klartext druckt.
set -Eeuo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOST="$REPO/host"
SECRETS="$REPO/clusters/dev/secrets"
AGE_KEY="$HOME/.config/sops/age/keys.txt"
export SOPS_AGE_KEY_FILE="$AGE_KEY"
export KUBECONFIG="$HOME/.kube/config"

# Versionen = Ist-Stand des Pi am 2026-10-24
K3S_VERSION="v1.35.9+k3s1"
# Tailscale nicht gepinnt: aktuelle stable-Version, danach Auto-Update (setup_tailscale)
SOPS_VERSION="v3.13.1"
YQ_VERSION="v4.54.1"
KUBARA_VERSION="0.9.0"
BESZEL_VERSION="0.21.0"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    \033[33mHINWEIS:\033[0m %s\n' "$*"; }
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Abbruch in Zeile $LINENO (exit $?)"' ERR

# shellcheck source=/dev/null
codename() { (. /etc/os-release && echo "$VERSION_CODENAME"); }

install_bin() {  # $1=ziel $2=url
  local tmp
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" "$2"
  sudo install -m 0755 "$tmp" "$1"
  rm -f "$tmp"
}

# ── Vorprüfung ───────────────────────────────────────────────────────────────
preflight() {
  log "Vorprüfung"
  [ "$(id -un)" = aaron ] || die "Bitte als User aaron ausführen (Cron, Skripte und Symlinks erwarten /home/aaron)"
  [ "$(uname -m)" = aarch64 ] || die "Gedacht für den Raspberry Pi 5 (arm64), gefunden: $(uname -m)"
  sudo -v || die "sudo-Rechte nötig"
  [ -r "$AGE_KEY" ] || die "Age-Key fehlt: $AGE_KEY (docs/disaster-recovery.md, Schritt 3)"
  chmod 600 "$AGE_KEY"
  ok "Age-Key vorhanden"
}

# ── Pakete und Werkzeuge ─────────────────────────────────────────────────────
install_packages() {
  log "Pakete"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates gnupg git jq dnsutils sqlite3 rsync age unbound ufw sysstat gh python3-yaml >/dev/null
  ok "apt-Pakete"

  if ! command -v docker >/dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(codename) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  fi
  id -nG | grep -qw docker || sudo usermod -aG docker aaron
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$(codename).noarmor.gpg" \
      | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$(codename).tailscale-keyring.list" \
      | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale >/dev/null
  fi
  # Ein alter Hold aus der Zeit des 1.102-Pins würde das Auto-Update blockieren
  sudo apt-mark unhold tailscale >/dev/null 2>&1 || true
  ok "Tailscale $(tailscale version | head -1)"

  [ "$(sops --version 2>/dev/null | awk 'NR==1{print $2}')" = "${SOPS_VERSION#v}" ] \
    || install_bin /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/$SOPS_VERSION/sops-$SOPS_VERSION.linux.arm64"
  ok "sops $SOPS_VERSION"

  [ "$(yq --version 2>/dev/null | awk '{print $NF}')" = "$YQ_VERSION" ] \
    || install_bin /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_arm64"
  ok "yq $YQ_VERSION"

  if [ "$(dpkg-query -W -f='${Version}' kubara 2>/dev/null)" != "$KUBARA_VERSION" ]; then
    local deb
    deb=$(mktemp --suffix=.deb)
    curl -fsSL -o "$deb" "https://github.com/kubara-io/kubara/releases/download/v$KUBARA_VERSION/kubara_${KUBARA_VERSION}_linux_arm64.deb"
    sudo apt-get install -y -qq "$deb" >/dev/null
    rm -f "$deb"
  fi
  ok "kubara $KUBARA_VERSION"

  if [ "$(/usr/local/bin/beszel-agent -v 2>/dev/null | awk '{print $NF}')" != "$BESZEL_VERSION" ]; then
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "https://github.com/henrygd/beszel/releases/download/v$BESZEL_VERSION/beszel-agent_linux_arm64.tar.gz" | tar -xz -C "$tmp"
    sudo install -m 0755 "$tmp/beszel-agent" /usr/local/bin/beszel-agent
    rm -rf "$tmp"
  fi
  ok "beszel-agent $BESZEL_VERSION"

  sudo install -D -m 0644 "$HOST/k3s/config.yaml" /etc/rancher/k3s/config.yaml
  if [ "$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')" != "$K3S_VERSION" ]; then
    curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
  fi
  mkdir -p "$HOME/.kube"
  sudo install -o aaron -g aaron -m 0600 /etc/rancher/k3s/k3s.yaml "$KUBECONFIG"
  ok "k3s $K3S_VERSION"

  sops -d "$SECRETS/kubara-env-secret.yaml" >/dev/null \
    || die "Secrets lassen sich mit $AGE_KEY nicht entschlüsseln (falscher Key?)"
  ok "SOPS-Secrets entschlüsselbar"
}

# ── GitHub-Zugang (private Repos klonen, Renovate) ───────────────────────────
setup_github() {
  log "GitHub-Zugang"
  if ! gh auth status >/dev/null 2>&1; then
    warn "Bitte bei GitHub anmelden (Browser oder Gerätecode, mit 2FA):"
    gh auth login --hostname github.com --git-protocol https --web
  fi
  git config --global credential.helper store
  git config --global user.name "Aaron Penalver Höfler"
  git config --global user.email "193275228+Guppy997@users.noreply.github.com"
  if [ ! -s "$HOME/.git-credentials" ]; then
    # Token direkt in die Datei, nie auf die Konsole
    (umask 077 && printf 'https://Guppy997:%s@github.com\n' "$(gh auth token)" > "$HOME/.git-credentials")
  fi
  ok "gh angemeldet, ~/.git-credentials vorhanden"
}

# ── Host-Konfiguration ───────────────────────────────────────────────────────
configure_host() {
  log "Host-Konfiguration"
  sudo install -m 0644 "$HOST"/sysctl/*.conf /etc/sysctl.d/
  sudo sysctl --system >/dev/null
  sudo install -D -m 0644 "$HOST/journald/00-size-limit.conf" /etc/systemd/journald.conf.d/00-size-limit.conf
  sudo systemctl restart systemd-journald
  ok "sysctl, journald"

  ln -sfn "$HOST/scripts/apt-upgrade-notify.sh" "$HOME/apt-upgrade-notify.sh"
  sudo install -D -m 0644 "$HOST/systemd/apt-daily-upgrade.service.d/10-ntfy.conf" \
    /etc/systemd/system/apt-daily-upgrade.service.d/10-ntfy.conf
  sudo install -m 0644 "$HOST/systemd/beszel-agent.service" /etc/systemd/system/beszel-agent.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now beszel-agent >/dev/null 2>&1
  ok "Unattended-Upgrades → ntfy, Beszel-Agent"

  ln -sfn "$HOST/backup.sh" "$HOME/backup.sh"
  sudo install -m 0644 "$HOST/pi-backup.cron" /etc/cron.d/pi-backup
  sudo install -m 0755 "$HOST/scripts/dns-watchdog.sh" /usr/local/bin/dns-watchdog.sh
  sudo install -m 0644 "$HOST/cron/dns-watchdog" /etc/cron.d/dns-watchdog
  sudo install -o root -g root -m 0755 "$HOST/claude-sudo" /usr/local/sbin/claude-sudo
  mkdir -p "$HOME/renovate/logs"
  ln -sfn "$HOST/renovate/run-renovate.sh" "$HOME/renovate/run-renovate.sh"
  ln -sfn "$HOST/renovate/check-ts-key-expiry.sh" "$HOME/renovate/check-ts-key-expiry.sh"
  crontab "$HOST/cron/crontab-aaron"
  ok "Backup, Cron, DNS-Watchdog, Renovate, claude-sudo"

  # Updates ohne Handarbeit: Docker per unattended-upgrades (nachts 02:15),
  # Host-Apps nach Merges deployen (04:15), Neustart So 04:30 nur bei Bedarf,
  # Bericht nach jedem Boot und sonntags 18:00. Die Units starten die Skripte
  # direkt aus diesem Klon, pi-autodeploy zieht ihn jede Nacht nach.
  sudo install -m 0644 "$HOST/apt/51unattended-docker" /etc/apt/apt.conf.d/51unattended-docker
  sudo install -D -m 0644 "$HOST/systemd/apt-daily-upgrade.timer.d/10-nachts.conf" \
    /etc/systemd/system/apt-daily-upgrade.timer.d/10-nachts.conf
  local unit
  for unit in pi-autodeploy.service pi-autodeploy.timer reboot-if-required.service \
              reboot-if-required.timer boot-report.service weekly-report.service weekly-report.timer; do
    sudo install -m 0644 "$HOST/systemd/$unit" "/etc/systemd/system/$unit"
  done
  sudo systemctl daemon-reload
  sudo systemctl enable --now pi-autodeploy.timer reboot-if-required.timer weekly-report.timer >/dev/null 2>&1
  sudo systemctl enable boot-report.service >/dev/null 2>&1   # läuft ab dem nächsten Boot
  ok "Autodeploy, Sonntags-Neustart, Boot- und Wochenbericht, Docker-Updates"

  sudo mkdir -p /mnt/backup
  # Die Quelle ist für aaron lesbar, nur das Schreiben braucht root
  # shellcheck disable=SC2024
  grep -q '[[:space:]]/mnt/backup[[:space:]]' /etc/fstab || sudo tee -a /etc/fstab < "$HOST/fstab.backup" >/dev/null
  if mountpoint -q /mnt/backup || sudo mount /mnt/backup 2>/dev/null; then
    ok "Backup-Stick unter /mnt/backup"
  else
    warn "Backup-Stick nicht gemountet. Eingesteckt? Für restore.sh wird er gebraucht."
  fi

  sudo bash "$HOST/ufw.sh" >/dev/null
  ok "UFW aktiv (LAN nur SSH/DNS, sonst nur Tailnet)"
}

# ── DNS: Unbound + Pi-hole ───────────────────────────────────────────────────
setup_dns() {
  log "DNS: Unbound und Pi-hole"
  sudo install -m 0644 "$HOST/unbound/pi-hole.conf" /etc/unbound/unbound.conf.d/pi-hole.conf
  [ -s /var/lib/unbound/root.hints ] \
    || sudo curl -fsSL -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root
  sudo systemctl enable unbound >/dev/null 2>&1
  sudo systemctl restart unbound
  ok "Unbound auf 127.0.0.1:5335"

  if ! command -v pihole >/dev/null; then
    # Der unbeaufsichtigte Installer übernimmt eine vorhandene pihole.toml und
    # schaltet den Stub-Listener von systemd-resolved selbst ab.
    sudo install -D -m 0644 "$HOST/pihole/pihole.base.toml" /etc/pihole/pihole.toml
    curl -sSL https://install.pi-hole.net | sudo PIHOLE_SKIP_OS_CHECK=true bash /dev/stdin --unattended
  fi
  ok "Pi-hole $(pihole version 2>/dev/null | grep -oE 'FTL version is v[0-9.]+' | awk '{print $NF}') (Listen, Hosts, Passwort kommen per restore.sh)"
}

# ── Tailscale ────────────────────────────────────────────────────────────────
setup_tailscale() {
  log "Tailscale"
  # UDP 41642 statt 41641: Auf 41641 kommt keine Direktverbindung zu open-claw
  # zustande, alles läuft dann übers DERP-Relay (siehe host/README.md).
  if ! grep -qx 'PORT="41642"' /etc/default/tailscaled; then
    sudo sed -i 's/^PORT=.*/PORT="41642"/' /etc/default/tailscaled
    grep -qx 'PORT="41642"' /etc/default/tailscaled \
      || echo 'PORT="41642"' | sudo tee -a /etc/default/tailscaled >/dev/null
    sudo systemctl restart tailscaled
  fi
  if ! tailscale status >/dev/null 2>&1; then
    warn "Tailscale ist noch nicht angemeldet. Den angezeigten Link im Browser öffnen:"
    sudo tailscale up --advertise-exit-node --accept-dns=true
  fi
  # Auto-Update an. Seit 1.104 nimmt tailscale serve nur noch Verbindungen über
  # tailscale0 an; Host und Cluster sprechen deshalb interne Adressen an, nicht
  # die serve-URLs (docs/operations.md).
  sudo tailscale set --auto-update=true >/dev/null 2>&1 || true
  ok "Tailscale: $(tailscale status --json | jq -r '.Self.DNSName')"
}

# ── Host-Apps (Docker Compose) ───────────────────────────────────────────────
setup_host_apps() {
  log "Host-Apps"
  local docker=(docker)
  docker info >/dev/null 2>&1 || docker=(sudo docker)   # Gruppe greift erst nach neuer Anmeldung

  local dir url
  while read -r dir url; do
    [[ -z "$dir" || "$dir" == \#* ]] && continue
    [ -d "$HOME/$dir/.git" ] || git clone -q "$url" "$HOME/$dir"
    mkdir -p "$HOME/$dir/data"
    if [ -f "$HOME/$dir/.env" ]; then
      (cd "$HOME/$dir" && "${docker[@]}" compose up -d --build >/dev/null)
      ok "$dir"
    else
      (cd "$HOME/$dir" && "${docker[@]}" compose up -d --build backend frontend >/dev/null)
      warn "$dir läuft ohne Tailscale-Sidecar: neuen Auth-Key in ~/$dir/.env (TS_AUTHKEY=…), dann 'docker compose up -d'"
    fi
  done < "$HOST/apps.txt"

  mkdir -p "$HOME/homeassistant/config"
  install -m 0644 "$HOST/apps/homeassistant/docker-compose.yml" "$HOME/homeassistant/docker-compose.yml"
  (cd "$HOME/homeassistant" && "${docker[@]}" compose up -d >/dev/null)
  ok "homeassistant (Konfiguration kommt per restore.sh)"
}

# ── Cluster ──────────────────────────────────────────────────────────────────
# kubara liest .env (godotenv, KEY=value ohne Anführungszeichen). Die Secret-Werte
# kommen aus der SOPS-Datei, der Rest aus host/kubara.env.
write_kubara_env() {
  local env="$REPO/.env"
  if [ -s "$env" ]; then
    ok ".env für kubara vorhanden"
    return
  fi
  (
    umask 077
    { sops -d "$SECRETS/kubara-env-secret.yaml" | yq -r '.stringData | to_entries | .[] | .key + "=" + .value'
      cat "$HOST/kubara.env"
    } > "$env"
  )
  ok ".env für kubara erzeugt (0600, in .gitignore)"
}

run_kubara() {
  local out rc=0
  out=$(mktemp)   # 0600; enthält kurz die kubara-Ausgabe mit Passwort
  (cd "$REPO" && kubara bootstrap luna-sovereign-mesh) >"$out" 2>&1 || rc=$?
  sed -E 's/\x1b\[[0-9;]*m//g' "$out" | grep -viE 'passw' | grep -E ' (INF|WRN|ERR) ' | sed 's/^/    /' || true
  rm -f "$out"
  [ "$rc" -eq 0 ] || die "kubara bootstrap fehlgeschlagen (exit $rc)"
}

setup_cluster() {
  log "Cluster: Secrets aus SOPS"
  kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
  local f ns
  for f in "$SECRETS"/*.yaml; do
    [ "$(basename "$f")" = kubara-env-secret.yaml ] && continue   # nur Quelle für .env
    ns=$(yq -r '.metadata.namespace' "$f")
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    sops -d "$f" | kubectl apply -f - >/dev/null
    ok "$(basename "$f" .yaml)"
  done

  log "Argo CD (kubara)"
  write_kubara_env
  if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1 && [ "${FORCE_KUBARA:-0}" != 1 ]; then
    ok "Argo CD läuft schon (neu ausrollen: FORCE_KUBARA=1 ./bootstrap.sh cluster)"
  else
    run_kubara
  fi
  # kubara v0.9 setzt das Label unabhängig von config.yaml (docs/operations.md)
  kubectl -n argocd label secret cluster-kubernetes.default.svc homer-dashboard=disabled --overwrite >/dev/null
  ok "homer-dashboard-Label"

  log "Applications"
  for f in "$REPO"/clusters/dev/apps/*-application.yaml; do
    kubectl apply -f "$f" >/dev/null
    ok "$(basename "$f" -application.yaml)"
  done

  log "Tailscale Serve"
  bash "$REPO/scripts/apply-tailscale-serve.sh" >/dev/null
  ok "Ports 10000–10011"
}

next_steps() {
  log "Fertig. Nächste Schritte"
  cat <<'EOF'
    1. Warten, bis Argo CD alles synchronisiert hat:
         kubectl -n argocd get applications
    2. Daten zurückspielen (erst prüfen, dann echt):
         ./restore.sh latest --dry-run
         ./restore.sh latest
    3. Tailscale-Auth-Keys für die Sidecars der Host-Apps neu erzeugen und in
       ~/<app>/.env eintragen (TS_AUTHKEY=…), dann dort 'docker compose up -d'.
    4. Für die Docker-Gruppe einmal ab- und wieder anmelden.
    Details: docs/disaster-recovery.md
EOF
}

main() {
  local what=${1:-all}
  preflight
  case "$what" in
    all)     install_packages; setup_github; configure_host; setup_dns; setup_tailscale; setup_host_apps; setup_cluster ;;
    host)    install_packages; setup_github; configure_host; setup_dns; setup_tailscale; setup_host_apps ;;
    cluster) setup_cluster ;;
    *)       die "Unbekannter Teil: $what (all|host|cluster)" ;;
  esac
  next_steps
}

main "$@"
