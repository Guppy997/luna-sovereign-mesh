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
