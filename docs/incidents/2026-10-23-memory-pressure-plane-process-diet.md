# Operational Finding: Memory Pressure Alert → Plane Process Diet

**Date:** 2026-10-23
**Type:** Alert-driven resource tuning (follow-up to [2026-06-29 resource optimisation](./2026-06-29-cooling-upgrade-resource-optimisation.md))
**Commit:** `f868a92` (PR #43)
**Status:** Resolved

## Summary

A `NodeMemoryMajorPagesFaults` warning fired for 50 minutes and was routed to ntfy. Nothing crashed, but the node had about 1 GiB of RAM available and was paging heavily. A per-namespace breakdown showed Plane using ~700 MiB, and ~40 % of that came from duplicate Python processes rather than actual work. Two one-line changes cut Plane to ~430 MiB without losing any functionality. A host-level cleanup in the same session freed 50 GB of disk.

## Observation

```
NodeMemoryMajorPagesFaults   warning   13:52 – 14:42 (resolved on its own)
```

| Metric | Value |
|---|---|
| RAM available | ~1,010 MiB of 7.8 GiB |
| zram swap used | 2.6 GiB (≈ 620 MiB of physical RAM after zstd compression) |
| Memory PSI `some avg10` | ~18 % |

Working set by namespace (top 6):

| Namespace | Working set |
|---|---|
| kube-prometheus-stack | 792 MiB |
| **plane** | **701 MiB** |
| argocd | 570 MiB |
| affine | 479 MiB |
| loki | 323 MiB |
| kyverno | 232 MiB |

## Root Cause

Plane was already tuned in June (Gunicorn 6 → 2 workers, Celery `--concurrency=1`, beat/space/admin scaled to 0). Process listings inside the pods showed where the rest of the memory went:

| Pod | Processes | RSS each |
|---|---|---|
| `plane-api` | Gunicorn master + **2** Uvicorn workers | ~140 MiB |
| `plane-worker` | Celery main + **1 forked prefork child** | ~155 MiB |

Every Python worker loads the full Django app, so each extra process costs a full copy. On a single-user instance:

- **One Uvicorn worker is enough.** It is async, so concurrent requests from one user do not need a second process.
- **The prefork child adds nothing at `concurrency=1`.** The main process only supervises the single child that actually runs the tasks. The `solo` pool runs the tasks in the main process with the same throughput.

## Fix

```yaml
# clusters/dev/apps/plane/manifests/plane-api.yaml  (ConfigMap plane-env)
GUNICORN_WORKERS: "2"   →   "1"

# clusters/dev/apps/plane/manifests/plane-worker.yaml
celery -A plane worker -l info --concurrency=1   →   --pool=solo
```

Deployed via Argo CD. One thing to watch for: **a ConfigMap change does not restart the pods that read it**, so `plane-api` kept running with 2 workers until a `kubectl rollout restart`. `plane-worker` restarted on its own because its pod spec changed.

**Memory limits were deliberately left unchanged.** A limit caps usage but does not reduce it. Lowering it would only turn normal peaks into OOM kills, the failure mode from [2026-06-12](./2026-06-12-argocd-oom-crashloop.md).

## Result

| | Before | After |
|---|---|---|
| `plane-api` | 288 MiB | ~150 MiB (steady state) |
| `plane-worker` | 207 MiB | 158 MiB |
| Plane total | ~700 MiB | ~430 MiB |
| Node RAM available | 1,010 MiB | 1,410 MiB* |

\*Includes ~100 MiB from removing an unused editor extension on the host in the same session.

UI and API returned 200 after the rollout. In its first 6.5 minutes, the solo worker processed 26 background tasks (recent-visit tracking, soft deletes, instance traces) with an empty queue and no errors (`celery inspect stats`, `redis-cli llen celery` = 0).

## Same Session: Disk Cleanup (host-level, not GitOps)

A setup audit in July had flagged the containerd store as large. It turned out to be mostly images no longer referenced by any pod, including leftovers from removed apps:

| Action | Freed |
|---|---|
| `k3s crictl rmi --prune` (239 → 59 images) | ~29 GB |
| Docker build cache + unused images (PWA builds) | ~23 GB |
| Stale editor server versions, journald vacuum, apt cache | ~3 GB |
| **Root filesystem** | **84 GB (75 %) → 34 GB (31 %)** |

## Lessons

- **Count processes, not just pods.** `kubectl top` shows one number per pod; `ps` inside the container showed that half of it was duplication.
- **Prefork defaults assume a multi-user server.** On a single-user node, `solo` pools and single async workers are a cheap win.
- **ConfigMap changes need an explicit rollout.** A checksum annotation on the pod template (or Reloader) would make this automatic. Not added yet, because env changes to Plane are rare.
- **zram swap is not disk swap.** 2.6 GiB of "swap" cost ~620 MiB of physical RAM. The useful signals are available memory and PSI, not the swap percentage.
