# Incident: Thermal Throttling → K3s API Freeze → Cascade Pod Crashloop

**Date:** 2026-06-20
**Duration:** ~20 minutes (23:08–23:28 active degradation; recovery in-session)
**Severity:** High — cluster near-freeze; D-Bus collapsed; most pods crash-looped; SSH sessions broken
**Status:** Mitigated (root cause hardware — permanent fix pending)

## Summary

The Raspberry Pi reached 85.6 °C under sustained load, triggering aggressive CPU throttling. The resulting performance degradation caused the K3s API server to miss TLS handshake deadlines, which starved all cluster components of API connectivity simultaneously. The cascade: policy-reporter (231 restarts), kube-state-metrics (224 restarts), kyverno-reports-controller (18 restarts), and several others entered crash loops. The kernel logged repeated RCU stalls; D-Bus collapsed, disconnecting systemd-managed services; SSH sessions dropped. The system did not reboot — uptime was continuous since 2026-06-16 — but was functionally unresponsive for the degradation window.

As a temporary mitigation, Prometheus, Loki, and Kyverno were disabled via cluster-secret label (the same mechanism already used for longhorn, metallb, etc.). This reduced RAM usage by ~1 GB, freed ~1.2 GB of swap, dropped load average from 49 → 0.65, and brought temperature down from 85.6 °C to 68 °C. These services remain off until proper cooling is in place.

## Timeline

| Time | Event |
|---|---|
| 2026-06-20 ~23:00 | System load begins climbing; swap saturation accelerating |
| 2026-06-20 23:08 | First kernel RCU stall logged: `rcu_preempt detected expedited stalls` |
| 2026-06-20 23:13 | `snapd` watchdog timeout (5 min limit exceeded) |
| 2026-06-20 23:19 | SSH session creation fails: `Failed to create session: Connection timed out` |
| 2026-06-20 23:23–23:25 | D-Bus connection terminated across all systemd services (timesyncd, logind, networkd, wpa_supplicant, resolved, avahi, udisks2, polkit) |
| 2026-06-20 23:24 | `ssh_packet_send_debug: Broken pipe` — active SSH sessions drop |
| 2026-06-20 23:26 | Load average: 49.14 / 98.99 / 81.62. RAM: 7.1 GB / 7.8 GB. Swap: 4.0 GB / 4.0 GB (5 MB free). Temp: 85.6 °C |
| 2026-06-20 23:26 | Crash-loop audit: policy-reporter 231 restarts, policy-reporter-kyverno-plugin 379, kube-state-metrics 224 |
| 2026-06-20 23:28 | All crash-looping pods restarted via `kubectl rollout restart`; kyverno-admission-controller pod deleted to reset CrashLoopBackOff backoff |
| 2026-06-20 23:35 | Prometheus, Loki, Kyverno disabled via cluster-secret label flip |
| 2026-06-20 23:51 | All targeted pods terminated and namespaces cleared |
| 2026-06-20 23:51 | Load: 0.65 / 4.26 / 19.44. Swap free: 1.2 GB. Temp: 68.8 °C |

## Root Cause

**Primary: Insufficient cooling for sustained workload.**

The Pi is running a full homelab stack (K3s + ArgoCD + Traefik + cert-manager + Prometheus + Loki + Grafana + Kyverno + Outline + Plane + Vaultwarden + ntfy + Pi-hole + Luna-PWA) without active cooling. At sustained load, the SoC reaches the thermal throttling threshold (80 °C), at which point the CPU frequency is stepped down significantly. At 85 °C the Pi enters emergency throttle territory where performance can be cut by 50 % or more.

**Secondary: Memory pressure compounding thermal effects.**

With ~7.1 GB of 7.8 GB RAM in use and 4 GB swap fully exhausted, every new process competed for swap I/O on the SD card / SSD. High swap I/O under a throttled CPU created a feedback loop: slow I/O → longer per-operation latency → more concurrently waiting processes → higher load → more heat.

**Cascade mechanism:**

```
High temp → CPU throttle → K3s API slow → TLS handshake timeouts
→ All pods lose API connectivity simultaneously
→ Pods crash (exit code 2, context canceled)
→ CrashLoopBackOff backoff timers run, new pods start, consume more RAM
→ More RAM pressure → more swap I/O → more heat
```

The policy-reporter additionally had a SQLite UNIQUE constraint bug that prevented clean recovery even after the API server stabilized, causing its restart count to reach 379.

## Why This Happened Now

The `plane` stack (PostgreSQL, Redis, API, Worker, Beat, Space, Admin, MinIO) was deployed and started actively receiving load in the hours before the incident. This added several hundred MB of additional RSS and meaningfully increased background I/O. Combined with ambient temperature conditions, this pushed the system past the tipping point.

## Mitigation Applied (2026-06-20)

**1. Crash-loop recovery**

All crash-looping pods were restarted with `kubectl rollout restart`. The kyverno-admission-controller pod was force-deleted to reset its CrashLoopBackOff backoff timer — on fresh start it came up cleanly with 0 restarts, confirming the crash was caused by API unavailability during the throttle window, not a persistent bug.

**2. Services temporarily disabled**

The following services were disabled via the cluster-secret label mechanism (same as `longhorn`, `metallb`, `argocd`, `external-dns`):

| Service | Label set to | Approx. RAM freed |
|---|---|---|
| kube-prometheus-stack | `disabled` | ~800 MB |
| loki | `disabled` | ~400 MB |
| kyverno | `disabled` | ~150 MB |
| kyverno-policies | `disabled` | — |
| kyverno-policy-reporter | `disabled` | ~100 MB |

**Total freed: ~1–1.2 GB RAM, ~1.2 GB swap.**

These services will be re-enabled once hardware cooling is in place (see Planned Fix below).

**Re-enable command:**
```bash
sudo k3s kubectl label secret -n argocd cluster-kubernetes.default.svc \
  kube-prometheus-stack=enabled \
  loki=enabled \
  kyverno=enabled \
  kyverno-policies=enabled \
  kyverno-policy-reporter=enabled \
  --overwrite
```

ArgoCD auto-deploys all services within ~2–3 minutes after this command.

## Planned Fix

**Hardware: Proper enclosure with active cooling.**

The Pi requires an enclosure with an active fan and direct heatsink contact on the SoC. Target operating temperature under full load: ≤ 65 °C (current passive: 85 °C under load, 68 °C after service reduction).

Once the enclosure is in place:
1. Re-enable Prometheus, Loki, Kyverno via the command above
2. Monitor temperature under full load for 30 minutes (target < 65 °C)
3. If stable, consider re-adding Prometheus retention back to 7d (was reduced to 1d in a previous incident)

**Software (optional, complementary):**

If temperature remains borderline after hardware fix, the following can be tuned:
- Set memory `requests` and `limits` on Kyverno policy-reporter and kube-state-metrics to cap their per-crash resource acquisition
- Consider scheduling Prometheus scrape intervals less aggressively (e.g., 60 s instead of 30 s)

## Lessons Learned

- **Thermal throttling is invisible in application logs.** The K3s API server doesn't log "I'm slow because the CPU is throttled" — it just starts missing timeouts. RCU stalls in `dmesg` are the only kernel-level signal. Add temperature monitoring to the post-incident checklist.
- **Full swap = the system is already in trouble.** Swap at 100 % means every new allocation is fighting SD/SSD I/O. Any additional load at that point tips into a cascade. Swap saturation should be an alerting threshold, not a discovery after the fact.
- **The cluster-secret label mechanism works well for controlled service reduction.** It is clean, reversible in one command, and integrates with the existing disabled/enabled pattern already used in this repo.
- **policy-reporter's SQLite UNIQUE constraint bug.** The reporter inserts `id=14695981039346656037` (empty ClusterPolicyReport) repeatedly within a single pod lifetime, hitting a UNIQUE constraint on every insert attempt. This is a non-fatal error (the pod continues), but it generates constant log noise and likely contributes to elevated CPU/I/O when the cluster is under load. Worth filing upstream or working around with a periodic DB reset.

## Post-Thermal-Event Checklist

```bash
# 1. Temperature
cat /sys/class/thermal/thermal_zone0/temp | awk '{printf "%.1f°C\n", $1/1000}'
# Target: < 65°C under load (passive), < 55°C idle

# 2. Swap saturation
free -h | grep Swap     # free column should not be near 0

# 3. Any crash-looping pods
sudo k3s kubectl get pods -A | grep -vE "Running|Completed|^NAMESPACE"

# 4. High-restart pods
sudo k3s kubectl get pods -A | awk '$5 > 10 {print $1, $2, $5, "restarts"}'

# 5. Load average
cat /proc/loadavg       # 1-min should be < 4 on a 4-core Pi at normal operation
```

## Follow-ups

- [ ] **Hardware:** Install enclosure with active cooling (fan + heatsink) — primary fix for this incident
- [ ] Re-enable Prometheus, Loki, Kyverno after cooling hardware installed
- [ ] Add temperature to ntfy alert rules once Prometheus is back (alert if temp > 75 °C for > 5 min)
- [ ] Investigate policy-reporter SQLite UNIQUE constraint bug — either patch values or open upstream issue
- [ ] Consider swap usage as an alert threshold in Prometheus (e.g., alert if swap > 80 % for > 10 min)
