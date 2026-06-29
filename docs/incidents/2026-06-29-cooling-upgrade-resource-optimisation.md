# Resolution: Cooling Upgrade + Resource Optimisation

**Date:** 2026-06-29
**Type:** Hardware upgrade + preventive resource tuning
**Status:** Complete
**Resolves:** [2026-06-20 Thermal Throttle → Cascade Crashloop](2026-06-20-thermal-throttle-cascade-crashloop.md)

## Summary

New 3D-printed enclosure with Noctua A6x25 fan installed. Operating temperature dropped from ~70 °C (loaded, passive cooling) to **43.9 °C** at startup with all services running — a reduction of ~26 °C. All services that were disabled as a temporary mitigation on 2026-06-20 (Prometheus, Loki, Kyverno) were re-enabled. Kubernetes memory requests across Plane and kube-prometheus-stack were tuned for single-user homelab operation, reducing scheduler pressure from 96 % to 90 %.

## Hardware Change

| | Before | After |
|---|---|---|
| Enclosure | Stock Pi case (passive) | Custom 3D-printed enclosure |
| Fan | None / stock Pi fan | Noctua A6x25 (25 mm, high static pressure) |
| Operating temp (loaded) | 70–85 °C | 43.9 °C |
| Thermal headroom to throttle (80 °C) | ~0–10 °C | ~36 °C |

The Noctua A6x25 provides significantly better airflow and static pressure than the standard Pi fan, resulting in aggressive heat dissipation even under sustained Kubernetes workloads.

## Services Re-enabled (2026-06-29)

All services that were label-disabled on 2026-06-20 were re-activated:

```bash
sudo k3s kubectl label secret -n argocd cluster-kubernetes.default.svc \
  kube-prometheus-stack=enabled \
  loki=enabled \
  kyverno=enabled \
  kyverno-policies=enabled \
  kyverno-policy-reporter=enabled \
  --overwrite
```

All apps synced and reached `Synced / Healthy` within ~3 minutes.

## Memory Request Optimisation (Commit 7246f4f, 5b38e78)

The cluster was at 96 % memory requests allocated (7662 Mi / ~7800 Mi), leaving only 138 Mi headroom. This prevented Prometheus from scheduling even though actual RAM usage was only ~82 %. Root cause: Plane and Prometheus had enterprise-sized requests, not calibrated for single-user homelab use.

### Plane (single-user, 3 projects, 19 issues)

| Service | Request before | Request after | Savings |
|---|---|---|---|
| plane-api | 256 Mi | 128 Mi | 128 Mi |
| plane-worker | 256 Mi | 128 Mi | 128 Mi |
| plane-beat | 128 Mi | 64 Mi | 64 Mi |
| plane-web | 256 Mi | 128 Mi | 128 Mi |
| plane-space | 128 Mi | 64 Mi | 64 Mi |
| plane-admin | 128 Mi | 64 Mi | 64 Mi |
| postgresql | 384 Mi | 256 Mi | 128 Mi |
| minio | 128 Mi | 64 Mi | 64 Mi |
| **Total Plane** | **1664 Mi** | **896 Mi** | **768 Mi** |

Limits were reduced proportionally. PostgreSQL limit kept at 1 Gi (database needs burst headroom).

### Prometheus (kube-prometheus-stack)

| Component | Request before | Request after | Savings |
|---|---|---|---|
| prometheus | 256 Mi | 64 Mi | 192 Mi |
| config-reloader | 100 Mi | 32 Mi | 68 Mi |
| **Total** | **356 Mi** | **96 Mi** | **260 Mi** |

Justification: `retention: 1d` and `retentionSize: 256MB` cap actual data at ~50–150 MB. The 256 Mi request was an artefact of the managed-service-catalog default. Limits kept at 512 Mi / 64 Mi.

### Additional Plane tuning

- **Gunicorn workers**: 6 → 3. Each worker is a forked Python process (~30–50 MB RSS each). 3 workers are ample for a single concurrent user; saves ~150 MB of actual RAM.
- **plane-admin (god-mode)**: `replicas: 1` → `replicas: 0`. Admin panel only needed for initial instance configuration; not required in daily operation. Re-enable with `replicas: 1` if user/site management is needed.

### Result

| Metric | Before optimisation | After optimisation |
|---|---|---|
| Memory requests (node) | 7662 Mi (96 %) | ~6986 Mi (90 %) |
| Prometheus status | Pending (no room to schedule) | Running (2/2) |
| Actual RAM used | ~6.4 GB (82 %) | ~6.4 GB (82 %) |

## Current System State (2026-06-29)

```
Temperature:  43.9 °C (idle after reboot with all services)
RAM actual:   ~6.4 GB / 7.8 GB (82%)
RAM requests: ~6986 Mi / ~7800 Mi (90%)
Swap used:    ~662 Mi / 4 GB (16%)
All pods:     Running / Completed — 0 failures
```

## Follow-ups from 2026-06-20 Incident

- [x] Hardware: Install enclosure with active cooling — **done 2026-06-29**
- [x] Re-enable Prometheus, Loki, Kyverno — **done 2026-06-29**
- [ ] Add temperature to ntfy alert rules (alert if temp > 70 °C for > 5 min) — still open
- [ ] Investigate policy-reporter SQLite UNIQUE constraint bug — still open
- [ ] Add swap usage as Prometheus alert threshold (> 80 % for > 10 min) — still open
