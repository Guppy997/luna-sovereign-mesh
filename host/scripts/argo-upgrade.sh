#!/usr/bin/env bash
# Spielt einen gemergten argo-cd-Chart-PR ein. Argo CD verwaltet sich nicht
# selbst: Änderungen an managed-service-catalog/helm/argo-cd wirken erst nach
# `kubara bootstrap` (docs/operations.md). Auf dem Pi von Hand ausführen:
#
#   ~/luna-sovereign-mesh/host/scripts/argo-upgrade.sh
#
# Ablauf: Klon auf main nachziehen, .env gegen die SOPS-Datei prüfen (kubara
# schreibt die Hub-Secrets aus .env neu), Dry-Run, nach Rückfrage der echte
# Lauf, homer-dashboard-Label zurücksetzen, warten bis Argo CD und alle Apps
# wieder grün sind.
#
# kubara druckt das Argo-CD-Passwort im Klartext. Jede kubara-Ausgabe läuft
# deshalb durch mask(): Alle Secret-Werte aus der SOPS-Datei werden durch ***
# ersetzt, dazu alles hinter "password"/"passwort".
set -Eeuo pipefail

REPO=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
SECRET_FILE="$REPO/clusters/dev/secrets/kubara-env-secret.yaml"
CHART="$REPO/managed-service-catalog/helm/argo-cd/Chart.yaml"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
export KUBECONFIG="$HOME/.kube/config"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }

# Beide 0600 und beim Beenden gelöscht: MASKFILE hält die Secret-Werte für
# mask(), OUT kurz die ungefilterte kubara-Ausgabe (wie in bootstrap.sh)
MASKFILE=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$MASKFILE" "$OUT"' EXIT
export MASKFILE

kubara_run() {  # Argumente an kubara bootstrap; gibt kubaras Exit-Code zurück
  local rc=0
  kubara bootstrap luna-sovereign-mesh "$@" >"$OUT" 2>&1 || rc=$?
  return "$rc"
}

mask() {
  perl -e '
    open my $f, "<", $ENV{MASKFILE} or die;
    chomp(my @v = <$f>);
    my @long = sort { length($b) <=> length($a) } grep { length($_) >= 6 } @v;
    my $re = join "|", map { quotemeta } @long;
    while (my $l = <STDIN>) {
      $l =~ s/\e\[[0-9;]*m//g;
      $l =~ s/$re/***/g if $re;
      $l =~ s/(passw\w*["\x27]?\s*[:=]\s*)\S+/$1***/ig;
      print $l;
    }'
}

chart_version() {
  awk '/- name: argo-cd/ {found=1} found && /version:/ {print $2; exit}' "$CHART"
}
running_version() {
  kubectl -n argocd get deploy argocd-server -o jsonpath='{.metadata.labels.helm\.sh/chart}' | sed 's/^argo-cd-//'
}

cd "$REPO"

log "Klon auf main"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "Klon steht nicht auf main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "Uncommittete Änderungen im Klon"
git fetch -q origin main
git merge -q --ff-only origin/main
echo "    $(git log -1 --format='%h %s')"

want=$(chart_version)
have=$(running_version)
echo "    Chart im Repo: $want, im Cluster: $have"
if [ "$want" = "$have" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "    Nichts zu tun (trotzdem ausrollen: FORCE=1 $0)"
  exit 0
fi

log ".env gegen SOPS prüfen"
sops -d --extract '["stringData"]' --output-type json "$SECRET_FILE" \
  | jq -r 'to_entries[] | .value' >"$MASKFILE"
mismatch=$(sops -d --extract '["stringData"]' --output-type json "$SECRET_FILE" \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
  | while IFS= read -r line; do grep -Fxq -- "$line" .env || echo "${line%%=*}"; done)
[ -z "$mismatch" ] || die "In .env fehlen oder weichen ab (nur Schlüssel): $(echo "$mismatch" | tr '\n' ' ')
       Entweder .env an die SOPS-Datei angleichen oder die SOPS-Datei per PR aktualisieren."
echo "    stimmt überein"

log "Dry-Run"
rc=0; kubara_run --dry-run || rc=$?
mask <"$OUT" | tail -25
[ "$rc" -eq 0 ] || die "Dry-Run fehlgeschlagen (exit $rc)"

printf '\nArgo CD %s → %s jetzt ausrollen? [j/N] ' "$have" "$want"
read -r answer
[[ "$answer" =~ ^[jJyY]$ ]] || { echo "Abgebrochen"; exit 0; }

log "kubara bootstrap"
rc=0; kubara_run || rc=$?
mask <"$OUT" | grep -E ' (INF|WRN|ERR) ' | sed 's/^/    /' || true
: >"$OUT"
[ "$rc" -eq 0 ] || die "kubara bootstrap fehlgeschlagen (exit $rc)"

# kubara v0.9 setzt das Label unabhängig von config.yaml (docs/operations.md)
kubectl -n argocd label secret cluster-kubernetes.default.svc homer-dashboard=disabled --overwrite >/dev/null
echo "    homer-dashboard=disabled"

log "Warten auf Argo CD"
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=10m
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis argocd-dex-server; do
  kubectl -n argocd rollout status "deploy/$d" --timeout=10m
done
echo "    läuft jetzt: $(running_version)"

log "Warten, bis alle Apps Synced/Healthy sind (max. 10 min)"
deadline=$(( $(date +%s) + 600 ))
while :; do
  bad=$(kubectl -n argocd get applications.argoproj.io -o json | jq -r '.items[]
    | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
    | "\(.metadata.name): \(.status.sync.status)/\(.status.health.status)"')
  [ -z "$bad" ] && { echo "    alle grün"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { printf '    noch nicht grün:\n%s\n' "$bad"; exit 1; }
  sleep 15
done
