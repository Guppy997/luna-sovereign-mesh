# Incident: Forced Reboot → kubara Network Crash & Silent State Corruption

**Date:** 2026-06-16
**Duration:** ~5 hours (failure to detection + manual recovery)
**Severity:** Medium — cluster fully offline during recovery; workloads unavailable; two silent failures persisted undetected after restart
**Status:** Resolved

## Summary

A forced (hard) reboot of the Raspberry Pi caused the k3s CNI network (flannel) to come back in a broken state — several pods could not reach the Kubernetes API server on startup and crash-looped. Beyond the obvious downtime, the reboot introduced two **silent** failures that survived initial recovery checks: the system's DNS integration silently broke (the `/etc/resolv.conf` symlink was overwritten with a plain file), and Pi-hole's ad-blocking was left in a disabled state. Both went unnoticed until a dedicated health check was run.

## Timeline

| Time | Event |
|---|---|
| 2026-06-16 ~17:00 | Forced (hard) reboot triggered — system unresponsive |
| 2026-06-16 ~17:04 | k3s starts; flannel re-initializes; stale VXLAN/iptables state causes network unreachable for API-dependent pods |
| 2026-06-16 ~17:26 | DHCP lease renewal overwrites `/etc/resolv.conf` from symlink to plain file (FritzBox 192.168.178.1 + 8.8.8.8 only) — Tailscale MagicDNS and Pi-hole removed from resolution path |
| 2026-06-16 ~17:00–22:00 | Pi-hole blocking silently in disabled state throughout recovery |
| 2026-06-16 ~22:00 | Manual cluster inspection begins; all 12 Argo CD apps Synced+Healthy, all pods Running |
| 2026-06-16 22:12 | `tailscale status` reveals health warning: *"Tailscale failed to fetch the DNS configuration of your device"* |
| 2026-06-16 22:15 | `/etc/resolv.conf` symlink restored; `systemd-resolved` restarted → `resolv.conf mode` changes from `foreign` to `uplink` |
| 2026-06-16 22:15 | `tailscaled` restarted → health warnings clear; `raspberrypi-1.tailddc8f7.ts.net` resolves correctly from the Pi itself |
| 2026-06-16 22:16 | `pihole status` reveals blocking disabled → `pihole enable` |
| 2026-06-16 22:16 | End-to-end verify: `luna-pwa HTTP 200`, `traefik HTTP 200` |

## Root Cause

The immediate cause was a hard reboot without graceful kubelet/CNI shutdown. k3s and flannel maintain network state (VXLAN tunnels, iptables rules, routing tables) that is partially in-memory. A force-reboot skips the orderly teardown, leaving stale state on restart. Flannel resolved this on its own after a few restart cycles, but it caused an elevated restart count across many pods during the window before the CNI stabilized.

Two additional silent failures were introduced:

**1. `/etc/resolv.conf` overwritten by DHCP**
During the ungraceful reboot sequence, the network stack replaced the `/etc/resolv.conf` symlink with a static plain file. The DHCP-provided content (FritzBox router + 8.8.8.8) excluded both Tailscale MagicDNS (`100.100.100.100`) and Pi-hole (`192.168.178.117`). Consequence: the Pi could no longer resolve `*.tailddc8f7.ts.net` hostnames locally, and Tailscale reported a DNS health warning. Systemd-resolved switched to `resolv.conf mode: foreign` (no longer recognizing ownership of the file), which prevented Tailscale from pushing its DNS configuration.

**2. Pi-hole blocking left disabled**
Pi-hole's blocking state survived the reboot in a disabled position. The exact cause is unclear (possible mid-write flush of the FTL database during ungraceful shutdown), but the effect was that all DNS filtering was silently bypassed for the duration of the recovery window.

## Why There Is No Automated Recovery

In a production multi-node cluster — the environment kubara and k3s are designed for — a single-node failure is handled automatically: the control plane remains up, workloads reschedule to healthy nodes, and CNI state is synchronized from surviving cluster members. A forced reboot of one node is a routine non-event.

On a **single-node homelab Pi**, there is no redundancy. A CNI crash or node failure takes the entire cluster offline simultaneously. Building full automated single-node recovery would require:

- A systemd service that detects and resets stale flannel state on boot
- Ordered startup dependencies ensuring CNI is healthy before kubelet admits workloads
- A post-boot health check restoring `/etc/resolv.conf` and verifying Pi-hole state
- Retry logic and alerting for each of the above

This is a meaningful amount of tooling to write and maintain for a failure mode that occurs only on forced reboots — an edge case in a lab environment. The engineering cost outweighs the benefit. **The accepted tradeoff: manual recovery is a known cost of running enterprise-grade cluster tooling on single-node hardware.** This postmortem serves as the recovery runbook.

## Resolution

1. **CNI network** — No manual intervention required. Flannel re-established its VXLAN tunnels after several restart cycles. Affected pods (kube-state-metrics, policy-reporter, and others that start before the CNI is ready) self-healed once the network became reachable. All 12 Argo CD applications returned to Synced+Healthy without any manual sync.

2. **DNS integration** — Restored `/etc/resolv.conf` as a symlink to `/run/systemd/resolve/resolv.conf` (managed by systemd-resolved, already carrying the correct nameservers: Tailscale MagicDNS `100.100.100.100` → Pi-hole `192.168.178.117`). Restarted `systemd-resolved` (mode changed from `foreign` to `uplink`) and `tailscaled` (health warnings cleared). MagicDNS resolution verified: `raspberrypi-1.tailddc8f7.ts.net → 100.113.125.35`.

3. **Pi-hole blocking** — Re-enabled with `pihole enable`. Verified with `pihole status`.

4. **Prometheus retention** *(proactive, day before incident — commit `65ade6d`)* — Prometheus retention was reduced from 10d to 7d to free working RAM. This was identified as a follow-up from the [2026-06-12 OOM incident](./2026-06-12-argocd-oom-crashloop.md). At the time of this incident, Prometheus RSS was 736Mi against an 800Mi limit — the retention reduction contributed to a stable recovery by avoiding an additional OOM event during the high-restart period post-boot.

## Lessons Learned

- **Hard reboots leave silent damage.** The cluster itself recovering (all pods green, Argo CD synced) is a necessary but not sufficient signal. Stateful host services (Pi-hole, Tailscale DNS) require explicit verification.
- **`/etc/resolv.conf` as a plain file is a red flag.** On this system it should always be a symlink to `/run/systemd/resolve/resolv.conf`. A static file means Tailscale DNS integration is broken, even if the tailnet connection itself looks healthy.
- **Tailscale `status --json` Health field is the right signal.** A zero-warning health array confirms DNS integration is intact; a non-empty array is actionable.
- **Single-node cluster tradeoffs are real.** kubara and k3s are production-grade tools built for multi-node environments. They operate correctly on a Pi — but their failure recovery model assumes cluster redundancy that does not exist here. Documenting failure modes is the right mitigation, not over-engineering around them.
- **The monitoring stack survived.** Prometheus, Alertmanager, ntfy, and Loki were all back within the first minutes of the cluster stabilizing. The observability layer did its job.

## Post-Reboot Checklist

For faster recovery the next time a forced reboot is necessary:

```bash
# 1. DNS integration
ls -la /etc/resolv.conf          # must be a symlink, not a plain file
tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin).get('Health', '✓'))"

# 2. If resolv.conf is a plain file:
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
sudo systemctl restart tailscaled

# 3. Pi-hole
pihole status | grep blocking      # must say "enabled"
# If not: sudo pihole enable

# 4. Cluster
kubectl get pods -A | grep -vE "Running|Completed"   # should be empty
kubectl get applications -n argocd                    # all Synced+Healthy
```

## Follow-ups

- [x] Restore `/etc/resolv.conf` symlink after force reboot (this incident)
- [x] Re-enable Pi-hole blocking after force reboot (this incident)
- [x] Reduce Prometheus retention to free RAM headroom — done 2026-06-15, commit `65ade6d`
- [ ] Consider adding a lightweight systemd `ExecStartPost` hook to the `pihole-FTL` unit that re-enables blocking on start, removing one manual step
