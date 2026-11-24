# Incident: Argo CD Controller OOMKill Crash Loop

**Date discovered:** 2026-06-12
**Duration:** 2026-06-04 → 2026-06-12 (8 days, undetected)
**Severity:** High: node-wide overload, system became unresponsive
**Status:** Resolved

## Summary

The Argo CD `application-controller` was OOM-killed by the kernel **1,343 times over 8 days** because its memory limit (600Mi) was below its actual steady-state working set (~650–700Mi). Each kill triggered a full restart and re-sync of all applications, creating constant CPU and memory churn. Combined with the node running at ~88% memory utilization **without any swap**, the page cache was repeatedly evicted under pressure, and the system eventually became so unresponsive that a hard reboot was required.

## Timeline

| Time | Event |
|------|-------|
| 2026-06-04 ~07:43 | First cgroup OOM kill of `argocd-application-controller` (after memory requests were reduced to fit Pi hardware) |
| 2026-06-04 → 06-12 | Controller killed and restarted every ~3–5 minutes; 1,343 OOM kills total, 1,332 container restarts. No alert fired. |
| 2026-06-12 ~23:25 | Last OOM kill before node became unresponsive; RAM fully exhausted, system thrashing |
| 2026-06-12 23:35 | Manual reboot |
| 2026-06-12 23:39 | Investigation: `journalctl -b -1` showed `constraint=CONSTRAINT_MEMCG` kills of `argocd-applicat` at ~654MB RSS against a 600Mi limit |
| 2026-06-12 | Fix committed: controller limit raised to 1Gi; zram swap added as a safety net |

## Root Cause

During an earlier resource-tuning pass (Argo CD's defaults requested 4.5GB, far too much for a Pi 5), the controller's memory **limit was set to 600Mi based on the chart's suggested values rather than observed usage**. With the current number of managed applications, the controller's real working set is ~650–700Mi. The limit was guaranteed to be exceeded on every sync cycle:

```
oom-kill:constraint=CONSTRAINT_MEMCG, ...
Killed process (argocd-applicat) total-vm:2076976kB, anon-rss:610012kB
```

Two factors turned a single misconfigured limit into a node-wide outage:

1. **Crash-loop amplification:** every restart forced a full re-sync of all Argo applications, keeping CPU and the repo-server under constant load (repo-server itself restarted 6 times).
2. **No swap configured:** at ~6.9GB/7.8GB baseline usage, the kernel had no overflow space. Under pressure it could only evict page cache, which caused thrashing and the perceived total freeze.

## Why It Went Undetected for 8 Days

All 1,343 kills were **cgroup-level** (`CONSTRAINT_MEMCG`), not global OOM events: the node stayed "up" and every other workload kept running. kube-prometheus-stack was collecting the relevant metrics the whole time (`kube_pod_container_status_restarts_total` reached 1,332), but **no alert rule was routed anywhere visible**. The monitoring stack watched the incident happen in full detail and told no one.

## Resolution

1. **Raised the controller memory limit** from 600Mi to 1Gi (request 400Mi → 512Mi) in `managed-service-catalog/helm/argo-cd/values.yaml`, deployed via GitOps as usual.
2. **Added zram swap** (compressed in-RAM swap) on the node as a pressure-relief valve, so future memory spikes degrade gracefully instead of freezing the system. k3s tolerates swap by default.
3. **Closed the detection gap with self-hosted push notifications** (2026-06-13): a [ntfy](https://ntfy.sh) server plus the [alertmanager-ntfy](https://github.com/alexbakker/alertmanager-ntfy) bridge now run as a GitOps app (`clusters/dev/apps/ntfy/`). Alertmanager routes every alert except `Watchdog`/`InfoInhibitor` to the ntfy topic `luna-alerts` (firing = urgent priority, resolved = default). The server is exposed tailnet-only via Tailscale Serve on `:10003`, and the Android app connects over WebSocket directly: push delivery without Google FCM, consistent with the zero-trust design. Verified end-to-end with a synthetic alert through the Alertmanager API. A pod crash-looping like this one now reaches a phone within ~1 minute instead of going unnoticed for 8 days.
4. **Added alert visibility to the Homepage dashboard**: the Prometheus tile now uses the homepage `prometheus` widget, which shows the live count of firing alerts on the landing page.

## Lessons Learned

- **Size limits from observed usage, not guesses.** Check actual RSS (`kubectl top pod`, Grafana `container_memory_working_set_bytes`) before setting limits, and leave ~30–50% headroom for components whose footprint scales with cluster contents (the Argo controller grows with app count).
- **A monitoring stack without alert routing is a flight recorder, not a smoke detector.** Restart-count and OOM-kill alerts must reach a human. Follow-up: enable Alertmanager routing for `KubePodCrashLooping` / container OOM events.
- **Memory-constrained nodes need swap.** Even a small zram device prevents "full RAM = frozen system" failure modes on an 8GB single-node cluster.
- **`OOMKilled` with `CONSTRAINT_MEMCG` means the limit is the problem** (or a genuine leak): the node itself may have plenty of free memory. Reading the constraint type in the kernel log immediately narrows the diagnosis.

## Follow-ups

- [x] Alertmanager route for crash-looping pods / OOM kills, done 2026-06-13 via self-hosted ntfy (see Resolution #3)
- [x] Reduce Prometheus retention (10d → 7d) to free ~65MB working RAM, done 2026-06-15, commit `65ade6d`; RSS now 736Mi against 800Mi limit, stable
