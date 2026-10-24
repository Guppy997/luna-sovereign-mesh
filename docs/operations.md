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

`minio/minio` and `minio/mc` return *repository does not exist*. The last cached images were mirrored 1:1 to
the private `ghcr.io/guppy997/minio` and `ghcr.io/guppy997/mc` (same tags), pulled with the `ghcr-pull`
secret from `clusters/dev/secrets/`. That keeps MinIO restorable, but it gets no further updates; a
replacement is still open.

## Postgres 16 → 18 (2026-10-04)

Plane and AFFiNE were migrated by dump/restore onto new PVCs (`*-pg18`); per-table row counts matched.
The old PVCs (`postgresql-data`, `affine-postgres-data`) are still defined as a way back and can be removed
once 18 has run for a while.
