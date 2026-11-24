# Operational Finding: Prometheus Retention Reduced from 10d to 7d

**Date:** 2026-06-15
**Type:** Proactive resource tuning (follow-up from [2026-06-12 OOM incident](./2026-06-12-argocd-oom-crashloop.md))
**Commit:** `65ade6d`
**Status:** Resolved

## Summary

After the Argo CD OOM crash loop incident on 2026-06-12, a follow-up review of all memory consumers identified Prometheus as the next largest risk. With a 10-day retention window and no size cap, Prometheus was consuming ~750Mi RSS against an 800Mi limit, leaving only ~50Mi of headroom. A targeted reduction of the retention window from 10d to 7d freed meaningful headroom while preserving enough history for trend analysis and alerting.

## Observation

```
kubectl top pod -n kube-prometheus-stack
prometheus-kube-prometheus-stack-prometheus-0   66m   736Mi
```

| Setting (before) | Value |
|---|---|
| Retention | `10d` |
| Retention size cap | not set |
| Memory limit | `800Mi` |
| Observed RSS | ~736–750Mi |
| Headroom | ~50Mi (~6%) |

With `retentionSize` unset, Prometheus grows until the time-based retention expires blocks. On a node already running at 79% RAM utilization, this left the Prometheus pod one traffic spike away from hitting its limit, the same failure mode that took down the Argo CD controller the week before.

## Why 7d and Not Less

7 days retains:
- A full week of metric history, enough to spot weekly patterns (e.g. morning briefing cron, weekly maintenance windows)
- Enough data for Grafana dashboards to show meaningful trends
- Alert history going back far enough to correlate with incidents

Dropping below 5 days would start to lose useful context for operational reviews. 7d is the minimum useful retention for this setup.

## Fix

Single-line change in `customer-service-catalog/helm/luna-sovereign-mesh/kube-prometheus-stack/values.yaml`:

```yaml
# before
retention: 10d

# after
retention: 7d
```

Deployed via Argo CD (GitOps), no manual rollout required. Prometheus compacted and evicted the oldest blocks within the next compaction cycle.

## Result

RSS stabilized at ~736Mi, unchanged immediately (old blocks compact over time), but the steady-state ceiling dropped by approximately 65Mi once blocks older than 7d were evicted. The pod remained within its 800Mi limit through the 2026-06-16 forced-reboot recovery period, which involved elevated restart counts across the cluster.

## Lesson

**Set `retentionSize` as a hard ceiling, not just `retention` as a time window.** A time-based retention alone does not prevent temporary bloat if ingest spikes. For a memory-constrained node:

```yaml
retention: 7d
retentionSize: 750MB   # hard cap, triggers block deletion before the time window
```

This is the recommended next step, not yet applied because `750MB` alone may be too conservative depending on current ingest volume. Verify with Grafana before committing.
