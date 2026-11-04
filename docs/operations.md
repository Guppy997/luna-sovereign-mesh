# Operations Notes

Things that are not obvious from the manifests and have each cost time at least once.

## Application manifests are applied by hand

The `clusters/dev/apps/*-application.yaml` files are not synced by an app-of-apps. A change to one of
them only takes effect after

```bash
kubectl apply -f clusters/dev/apps/<name>-application.yaml
```

The manifests *inside* `clusters/dev/apps/<name>/manifests/` are synced by Argo CD as usual. Drift between
the live Applications and Git can be checked with
`kubectl diff --server-side -f clusters/dev/apps/<name>-application.yaml`.

## Catalog apps only re-render on changes under `managed-service-catalog/`

The ApplicationSet template sets `argocd.argoproj.io/manifest-generate-paths: ".;.."` relative to the
managed chart. A commit that only touches `customer-service-catalog/` does not trigger a new render. Argo CD
reports the new revision as *Synced* while still running the old manifests. After a values-only change:

```bash
kubectl -n argocd annotate application luna-sovereign-mesh-<name> argocd.argoproj.io/refresh=hard --overwrite
```

## `kubara bootstrap` re-enables `homer-dashboard`

Argo CD itself is rolled out with `kubara bootstrap luna-sovereign-mesh` (always run `--dry-run` first). kubara
v0.9 sets the cluster label `homer-dashboard=enabled` regardless of `config.yaml`. Afterwards:

```bash
kubectl -n argocd label secret cluster-kubernetes.default.svc homer-dashboard=disabled --overwrite
```

## Kyverno policies stay on `ClusterPolicy`

`kyverno-policies` 3.9+ installs CEL `ValidatingPolicy` objects by default, and `policyExclude` does not apply
to them. Without `policyType: ClusterPolicy` (customer values), Alloy and node-exporter (hostPath, host ports)
and k3s ServiceLB (sysctls) are rejected at admission. Moving the exclusions to `vpolExcludeByPolicy` is open.

## MinIO images are no longer on Docker Hub

`minio/minio` and `minio/mc` return *repository does not exist*. Both run with `imagePullPolicy: IfNotPresent`
from the image cached on the node. If the node's image store is lost, MinIO will not start again — a new
image source or a replacement is needed.

## Postgres 16 → 18 (2026-10-04)

Plane and AFFiNE were migrated by dump/restore onto new PVCs (`*-pg18`); per-table row counts matched.
The old PVCs (`postgresql-data`, `affine-postgres-data`) are still defined as a way back and can be removed
once 18 has run for a while.

## `tailscale serve` only answers on `tailscale0` (since 1.104)

Since Tailscale 1.104, `tailscale serve` on Linux binds its listeners to the `tailscale0` interface
(`ss -ltn` shows `100.113.125.35%tailscale0:100xx`). A request that reaches the tailnet IP any other way is
refused: from the Pi itself, from a pod, from a Docker container on the host. Devices in the tailnet do not
notice anything.

Nothing on the Pi or in the cluster may therefore call a serve URL (`https://raspberrypi-1…:100xx`). Use an
internal address instead: Homepage's `siteMonitor` checks use cluster DNS names or the host's LAN IP, and the
host scripts send to ntfy through its pinned ClusterIP `http://10.43.235.81`. Settings that only build links
for the browser (`WEB_URL`, `DOMAIN`, `externalUrl`, `root_url`, Homepage `href`) can keep the serve URL.

An automatic update to 1.104.1 on 2026-10-20 broke exactly these calls and was rolled back the same day; the
host stayed pinned to 1.102.5 until 2026-10-31. Tailscale documents `TS_SERVE_ALLOW_ALL_INTERFACES` to bring
back the old behaviour. It is not used here, because it would open serve on every interface again.

Check that nothing inside still depends on a serve URL:

```bash
kubectl exec -n homepage deploy/homepage -- node -e \
  'fetch("https://raspberrypi-1.tailddc8f7.ts.net:10008/").then(r=>console.log(r.status)).catch(e=>console.log(e.cause.code))'
# ECONNREFUSED is expected
```

## Updates run on their own

What happens at night (Europe/Berlin):

| Time | What | Where |
|---|---|---|
| 01:30 | Renovate checks every own repo that has a `renovate.json`, opens PRs (weekends) and merges those its rules allow once all checks are green | `host/renovate/run-renovate.sh` |
| 02:15 | unattended-upgrades: Ubuntu security updates and Docker | `host/apt/`, timer drop-in |
| 03:00–03:50 | Backups (USB stick, then the host apps' SQLite files) | `host/backup.sh`, crontab |
| 04:15 | pi-autodeploy: host apps, this clone, `~/luna-pwa`, Home Assistant | `host/scripts/pi-autodeploy.sh` |
| Sun 04:30 | Reboot, only if `/var/run/reboot-required` exists | `host/scripts/reboot-if-required.sh` |
| 07:00 | Cluster health digest | `clusters/dev/apps/automation` |
| Sun 18:00 | Weekly report: stale PRs, majors waiting, deploys, backups, key expiry | `host/scripts/weekly-report.sh` |

Renovate merges at 01:30, so an update that breaks a cluster app shows up in the 07:00 digest the same morning.

**Merges on its own:** in the app repos everything the shared preset
[`Guppy997/renovate-config`](https://github.com/Guppy997/renovate-config) allows (patch, minor and digests
behind green CI, npm releases only after three days; a repo without CI never auto-merges). Here: patch
updates of charts and manifests, and minor updates of the stateless helper images listed in `renovate.json`.

**Stays a manual step:**
- Majors: tick the box in the repo's *Dependency Dashboard* issue, then review the PR.
- Argo CD: after merging an `argo-cd` chart PR, run `host/scripts/argo-upgrade.sh` on the Pi (see
  "`kubara bootstrap` re-enables `homer-dashboard`" above; the script resets the label).
- k3s: Renovate bumps `K3S_VERSION` in `bootstrap.sh`; the PR contains the install command.
- Home Assistant: merge the PR after reading the breaking changes; pi-autodeploy applies it at 04:15.
- Wedding-Kids-PWA (production, not on this Pi) keeps Dependabot security PRs and manual deploys.

### pi-autodeploy

For each app in `host/apps.txt`, pi-autodeploy only deploys when the clone is clean and on `main` and all
check runs of the new commit are green. It runs the app's own backup first, then `docker compose build
--pull` and `up -d`, and waits until `backend` and `frontend` are healthy. Otherwise it resets to the old
commit, rebuilds, and reports via ntfy. A commit that failed is remembered in
`~/.local/state/pi-autodeploy/<app>.failed` and not retried; the next commit on `main` is.

Local commits on the Pi are never overwritten: a dirty clone, another branch, or commits that are not on
GitHub make it skip that clone and send a warning.

```bash
~/luna-sovereign-mesh/host/scripts/pi-autodeploy.sh --dry-run
journalctl -u pi-autodeploy --since -7d -o cat

# Test the rollback path: move one app a commit back, deploy with a forced failure, clean up
git -C ~/ausrichtung reset --hard HEAD~1
~/luna-sovereign-mesh/host/scripts/pi-autodeploy.sh --simulate-fail ausrichtung
rm ~/.local/state/pi-autodeploy/ausrichtung.failed
~/luna-sovereign-mesh/host/scripts/pi-autodeploy.sh
```
