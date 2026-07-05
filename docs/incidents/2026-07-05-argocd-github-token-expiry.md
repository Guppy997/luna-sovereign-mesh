# Incident: Expired GitHub Token → Cluster-Wide Argo CD Sync Blindness

**Date:** 2026-07-05 (detected; exact onset unknown)
**Duration:** Unknown start, likely several days — no expiration tracking was in place for the credential
**Severity:** Medium — GitOps auto-sync silently stopped functioning cluster-wide; no workload was ever actually unhealthy
**Status:** Resolved

## Summary

The GitHub Personal Access Token used by Argo CD to authenticate against the `luna-sovereign-mesh` repository expired. Argo CD's repo-server could no longer clone or diff the Git repo, so **every single Application** (17/17) fell into `Sync: Unknown` — not because anything was actually broken, but because Argo CD could no longer tell whether the cluster matched Git. Auto-sync was silently skipped for all applications as a result. The failure was first noticed indirectly: a daily 07:00 ntfy digest job (`cluster-health-digest`) reported "Auffälligkeiten" (anomalies) listing all 17 apps as `Unknown/Healthy` every morning — technically accurate, but the message gave no hint that the actual cause was a single expired credential rather than 17 independent problems.

## Timeline

| Time | Event |
|---|---|
| (unknown) | GitHub PAT used for the `https-init-repo-access` Argo CD repo credential expires |
| Every day, 07:00 | `cluster-health-digest` CronJob sends an ntfy push reporting all 17 Argo CD apps as `Unknown/Healthy` — read on the phone each morning, initially assumed to be routine noise |
| 2026-07-05 | User asks for the recurring morning notification to be investigated |
| 2026-07-05 | `kubectl get applications -n argocd` confirms all 17 apps show `Sync: Unknown`, `Health: Healthy` |
| 2026-07-05 | `argocd-repo-server` logs show the actual cause: `failed to list refs: authentication required: Invalid username or token. Password authentication is not supported for Git operations.` |
| 2026-07-05 | `argocd-application-controller` logs confirm the downstream effect: `Skipping auto-sync: application status is Unknown` for every application |
| 2026-07-05 | Cross-checked: the same expired token was independently found to be embedded in this repo's local `git remote` URL — a `git push` earlier the same day had already failed with `401 Bad credentials` against the GitHub API |
| 2026-07-05 | New GitHub PAT (classic, `repo` scope) generated; patched into the `https-init-repo-access` Secret (`password` field) in the `argocd` namespace |
| 2026-07-05 | `argocd.argoproj.io/refresh=hard` annotation applied to all 17 Applications; within ~30s all returned to `Sync: Synced`, `Health: Healthy` |
| 2026-07-05 | Local git remote updated with the new token; the previously-failed push succeeded |

## Root Cause

The `https-init-repo-access` Secret in the `argocd` namespace stores HTTPS Basic Auth credentials (username + PAT-as-password) that `argocd-repo-server` uses to clone and fetch the GitOps repository. GitHub Personal Access Tokens (classic) can be created with an expiration date; once past it, GitHub rejects all authenticated Git operations with the token, returning the generic error `Invalid username or token. Password authentication is not supported for Git operations.` — the same error GitHub returns for a token that never had `repo` scope at all, which makes the failure mode non-obvious from the error text alone.

Because `argocd-repo-server` could no longer authenticate, every `GenerateManifest`/refs-listing call failed. The `argocd-application-controller` cannot compute a diff against Git without this step, so it correctly (and safely) reports `Sync: Unknown` rather than guessing — and, just as correctly, refuses to auto-sync when it cannot verify what "in sync" would even mean. This is Argo CD behaving exactly as designed under credential failure; the credential itself was the actual defect.

**Health stayed green throughout** because Health is derived purely from live cluster resource state (pod readiness, replica counts, etc.), which never depends on Git access. This is why the incident looked cosmetic rather than urgent — nothing was ever actually down.

## Why the Alert Didn't Point at the Real Cause

The `cluster-health-digest` job (see the [2026-06-20 thermal incident](2026-06-20-thermal-throttle-cascade-crashloop.md) follow-ups, and its own [monitoring-alerts PrometheusRule](../../clusters/dev/apps/monitoring-alerts/manifests/prometheusrule.yaml)) reports per-application sync/health state — a reasonable general-purpose signal. But a single shared credential failing affects every application identically and simultaneously, and the digest has no special case for "all 17 apps flipped to the same abnormal state at once," which is a strong, specific signal that the fault is upstream and shared (a credential, a network path, a shared dependency) rather than 17 unrelated per-app problems. Reading the raw controller/repo-server logs was what actually surfaced the real cause, not the digest itself.

## Resolution

1. Generated a new GitHub PAT (classic, `repo` scope) via github.com/settings/tokens.
2. Patched the `password` field of the `https-init-repo-access` Secret in `argocd`:
   ```bash
   kubectl -n argocd patch secret https-init-repo-access --type=merge \
     -p '{"data":{"password":"<base64-encoded-new-token>"}}'
   ```
3. Forced an immediate re-evaluation of every Application instead of waiting for the next poll interval:
   ```bash
   for app in $(kubectl -n argocd get applications -o jsonpath='{.items[*].metadata.name}'); do
     kubectl -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite
   done
   ```
4. Verified: all 17 applications returned to `Sync: Synced`, `Health: Healthy`.
5. Updated this repository's local `git remote` URL with the same new token (it had been carrying the identical expired one) and pushed the commits that had been failing silently since.

## Lessons Learned

- **A single shared Git credential is a single point of failure for the entire GitOps pipeline** — by design, and an acceptable tradeoff for a one-operator homelab. The gap wasn't the shared credential; it was having **no expiration tracking or renewal reminder** for it.
- **"All N applications show the same abnormal state" is itself a diagnostic signal.** Per-app monitoring is right for catching one app's actual problem, but a fleet-wide identical anomaly should be treated as evidence of a shared upstream cause (credential, DNS, network path) before investigating each app individually.
- **Health and Sync are independent signals, and both matter.** A cluster can look completely fine (Health: Healthy everywhere) while the automation that keeps it that way (GitOps sync) is silently non-functional. A dashboard or digest that only surfaces Health would have hidden this entirely.
- **The generic ntfy digest was technically correct but not actionable.** It told the truth ("17 apps abnormal") without pointing at the cause. A useful improvement without much extra complexity: special-case "all applications share the same Sync status" in the digest script and call it out explicitly, rather than listing all 17 individually every morning.

## Follow-ups

- [x] Rotate the expired GitHub PAT, patch the Argo CD repo Secret, force-refresh all applications — this incident
- [x] Update the local git remote with the same rotated token
- [ ] Track the new token's expiration date (if any) somewhere outside the cluster — a calendar reminder is enough; the failure mode here is forgetting, not tooling
- [ ] Consider a dedicated alert on Argo CD's own repo/git error metrics (`argocd_app_reconcile` / repo-server gRPC error rate is already scraped by kube-prometheus-stack) rather than relying solely on the daily digest to surface this class of failure sooner than "next morning at 07:00"
- [ ] Consider special-casing "all applications share one abnormal Sync/Health value" in `cluster-health-digest` to point at a shared cause instead of listing every app individually
