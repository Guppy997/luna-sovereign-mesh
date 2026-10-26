# Operational Finding: Reverted Loki Upgrade Came Back → Sidecar CrashLoop + a Failed Swappiness Experiment

**Date:** 2026-10-26
**Type:** Alert-driven fix (follow-up to [2026-10-23 memory pressure](./2026-10-23-memory-pressure-plane-process-diet.md))
**PRs:** #18 (trigger), #19 (fix)
**Status:** Resolved

## Summary

Three ntfy alerts arrived within eight minutes: `NodeMemoryMajorPagesFaults` (~1,600 major faults/s), then `KubePodNotReady` and `KubeStatefulSetReplicasMismatch` for `loki-0`. The Loki problem had been diagnosed and reverted two days earlier. A revert does not stop Renovate, though: it reopened the same chart upgrade, and the PR was merged again. The rules sidecar in that chart never becomes healthy on the Pi and served no purpose, so it was switched off instead of reverting a second time.

While debugging the page faults, `vm.swappiness` was raised from 10 to 100 as an experiment. **That made things measurably worse** and was rolled back after 30 minutes. It is documented here because the reasoning behind it sounded right.

## Timeline (CET)

| Time | Event |
|---|---|
| 17:59 | PR #18 (Renovate: Loki chart 18.13.7 → 18.17.1) merged |
| 18:04 | Argo CD auto-sync rolls `loki-0` |
| 18:13 | `NodeMemoryMajorPagesFaults` (1,616/s) |
| 18:21 | `loki-0` NotReady: rules sidecar in liveness CrashLoop |
| 18:36 | Experiment: `vm.swappiness` 10 → 100 (runtime only) |
| ~18:39 | The `loki` container itself now also restarts every ~4 min → pod 0/2 |
| 18:44 | PR #19 merged (sidecar off). Argo shows *Synced* but still renders the old chart |
| 18:50 | Argo **hard refresh** → StatefulSet without sidecar, `loki-0` 1/1, stable since |
| 19:04 | Swappiness experiment rolled back to 10 |

## Root Cause

**Loki: the revert was not sticky.** Chart 18.17.1 bumps the rules sidecar `kiwigrid/k8s-sidecar` from 2.11.2 to 2.14.1. On the Pi the new version produces no log output and never answers `/healthz`, so the liveness probe kills it in a loop (exit 137, not an OOM). It was reverted on 2026-10-24 (`456813f`). Renovate only sees "18.17.1 > 18.13.7" and reopened the PR. The sidecar loads ruler rules from ConfigMaps labelled `loki_rule`, and none exist.

**Memory pressure: churn on an already tight node.** No namespace grew. Working sets at 17:50 and 19:05 are within ±25 MiB, and Loki is 100 MiB *smaller* afterwards. The pressure came from the restart loop (WAL replay, repeated container starts) on a node with only ~1.1 GiB available.

## The Swappiness Experiment (did not work)

Since boot, `/proc/vmstat` showed about 100× more file refaults than anonymous refaults (4.46 × 10⁹ vs 4.7 × 10⁷). The hypothesis: with `swappiness=10` the kernel drops code pages instead of moving idle anonymous memory to cheap zram, so raising swappiness should reduce major faults.

| 10-min rates | Before 18:04 (calm) | Loki crash loop, swappiness 10 | Swappiness 100 |
|---|---|---|---|
| Major faults/s | 120–300 | 600–1,900 | **3,900–5,100** |
| Swap-ins/s | 20–120 | 400–1,300 | **3,500–4,300** |
| PSI full | ~1 % | 5–6 % | **8 %** |

With swappiness 100, almost every major fault became a zram swap-in. The kernel pushed working memory out and immediately had to pull it back. On a node where the working set barely fits, there is no idle anonymous memory to park, so a higher swappiness just moves the thrashing from page cache to zram. After the rollback the rates trended back down (PSI 4 %, swap-ins ~1,900/s at 19:15) while the pages pushed out during the experiment were read back in.

## Fix

```yaml
# customer-service-catalog/helm/luna-sovereign-mesh/loki/values.yaml
loki:
  sidecar:
    rules:
      enabled: false   # chart 18.17.1 stays
```

Alerting (PR #19):

| Alert | Before | After |
|---|---|---|
| `PiSwapHigh` | swap > 50 % for 10m | swap > 85 % for 10m |
| `PiMemoryPressure` (new) | — | PSI full > 10 % for 10m |

As the [2026-10-23 finding](./2026-10-23-memory-pressure-plane-process-diet.md) noted, zram swap percentage is a poor thrashing signal. PSI measures the actual stall time.

**Not changed:** `vm.swappiness` stays at 10. The Argo CD controller limit also stays: at 500–670 MiB it is within its documented steady state, and an undersized limit caused the [2026-06-12 crash loop](./2026-06-12-argocd-oom-crashloop.md).

## Lessons

- **A revert does not stop Renovate.** After reverting a dependency update, either fix the cause or pin the version in `renovate.json` (`allowedVersions`). Otherwise the same PR comes back.
- **Switch off what you do not use.** The rules sidecar ran for four months with nothing to load. Without it, the upgrade would have been a no-op.
- **Argo CD "Synced" can mean "synced to a stale render".** After a values-only change to a multi-source Helm app, verify the live object, and hard-refresh if it does not match.
- **Test kernel tunables against a baseline, not a theory.** The refault ratio made the swappiness change look obvious, and 30 minutes of measurement showed the opposite. Runtime-only `sysctl` first, persist only after the numbers agree.
- **The node has no slack left.** ~1 GiB available at steady state means any restart loop turns into node-wide pressure. The real lever is fewer resident workloads, not kernel tuning.
