# Incident: DNS Cascade During AI-HAT Driver Install: Reboots → MagicDNS SERVFAIL → Cluster-Wide Resolution Failure

**Date:** 2026-07-05
**Duration:** ~16:00–19:35 CEST (full recovery of all layers)
**Severity:** High: host, cluster and remote clients lost DNS for public names; image pulls, Argo CD syncs, homepage widgets and the user's exit-node clients (VS Code / Claude on the MacBook) all failed
**Status:** Resolved, with structural fixes so this class of failure can't recur silently

> Note: this is the *second* incident on the same day; see the
> [expired GitHub token postmortem](2026-07-05-argocd-github-token-expiry.md) for the morning's
> unrelated `Sync: Unknown` episode. The two share a symptom (all apps Unknown) but have
> completely different causes; both are kept separate deliberately.

## Summary

During the Hailo AI-HAT driver installation (kernel headers + DKMS + PCIe driver), the Pi was
rebooted three times in ~35 minutes. After the reboots, Tailscale's MagicDNS resolver on the Pi
began returning SERVFAIL for every non-tailnet name ("`no upstream resolvers set`"). The tailnet
had **no global nameservers configured**, so MagicDNS had nothing to forward public queries to.

The failure then cascaded through every layer that directly or indirectly depended on the host's
DNS state at that moment:

- **containerd** could not resolve `registry-1.docker.io` → `minio` and `beszel` fell into
  `ImagePullBackOff`
- **CoreDNS** had captured a broken host `resolv.conf` at pod start and kept using it → every pod
  lost external resolution (`EAI_AGAIN`), homepage widgets returned 500s
- **Argo CD** could not resolve `github.com` → all 17 Applications fell to `Sync: Unknown`
  (the second time that day, for a different reason)
- **Remote clients** routing through the Pi as exit node with Accept-DNS lost resolution of
  `api.anthropic.com` → the user's Claude sessions died mid-task, which is also why the
  in-flight installation session was cut off
- An emergency hand-edit during the outage left `/etc/resolv.conf` statically pointing at
  `8.8.8.8`, restoring public resolution but silently bypassing Pi-hole/Unbound and breaking
  `*.ts.net` resolution on the host

## Timeline (CEST)

| Time | Event |
|---|---|
| ~15:53 | Hailo driver install in progress (kernel headers, DKMS, PCIe driver `.deb`s) |
| 15:59–16:35 | Three reboots in quick succession (driver/kernel-module bring-up) |
| 16:35 | Last boot; `tailscaled` starts logging `dns: resolver: forward: no upstream resolvers set, returning SERVFAIL` |
| 16:35+ | `minio`/`beszel` → `ImagePullBackOff` (`lookup registry-1.docker.io: Try again`); Argo CD → `lookup github.com … server misbehaving`; homepage widgets → `EAI_AGAIN` 500s |
| ~19:01 | Emergency measure during the (dying) session: `/etc/resolv.conf` statically set to `8.8.8.8`; host regains public DNS, loses `ts.net` and Pi-hole sovereignty |
| 19:08 | New session on the Pi; systematic diagnosis begins |
| 19:17 | CoreDNS identified as still holding the stale resolver config → `rollout restart` → cluster external DNS restored |
| 19:19 | Hard-refresh of all 17 Argo Applications → all `Synced + Healthy` again |
| ~19:25 | Tailnet DNS fixed at the admin console: global nameservers added (Pi-hole `100.113.125.35` primary with *Use with exit node*, Mullvad + Cloudflare fallback), *Override DNS servers* enabled |
| 19:29 | Pi itself: `tailscale set --accept-dns=false` (see resolvconf bug below); stale health warnings cleared with a `tailscaled` restart |
| ~23:15 | Found & fixed the leftover emergency hack: `/etc/resolv.conf` → Pi-hole via LAN IP (`192.168.178.117`) with `8.8.8.8` fallback; CoreDNS restarted once more to pick it up. All layers verified: ts.net ✓ public ✓ cluster-internal ✓ |

## Root Causes (three, stacked)

1. **No global nameservers in the tailnet (primary).** MagicDNS answers `*.ts.net` itself but must
   forward everything else to configured upstreams. None were configured: the setup only worked
   as long as each device kept its own working local DNS path. The reboot churn broke that
   assumption on the Pi, and every exit-node client inherited the failure.
2. **CoreDNS freezes its upstream config at pod start.** k3s's CoreDNS forwards to the host
   `resolv.conf` *as captured when the pod starts*. A CoreDNS pod that boots during a DNS outage
   keeps the broken state until restarted: host recovery does not propagate.
3. **Emergency hand-edits don't get rolled back.** The static `8.8.8.8` fix was correct triage but
   became silent config drift: host queries bypassed Pi-hole/Unbound (sovereignty loss) and
   `*.ts.net` names stopped resolving on the host (Google's resolvers don't know this tailnet's
   names, only MagicDNS or Pi-hole's conditional forward do).

### Contributing bug: tailscaled vs. Ubuntu's resolvconf

With DNS settings now pushed from the tailnet, `tailscaled` tried to manage the host resolver via
`/usr/sbin/resolvconf -a tailscale`, which fails on Ubuntu 24.04 because the interface is named
`tailscale0` ("Failed to resolve interface \"tailscale\": No such device"). Since the Pi should use
Pi-hole directly anyway (it *hosts* it), `--accept-dns=false` is the correct permanent setting
here, not a workaround.

## Resolution: final DNS architecture

```
LAN clients        → Pi-hole (DHCP-assigned)          → Unbound (recursive) / quad100 for ts.net
Tailnet clients    → MagicDNS → Pi-hole (100.113.125.35) primary
                              → Mullvad, Cloudflare (fallback, "Use with exit node" enabled)
Pi host            → /etc/resolv.conf: 192.168.178.117 (Pi-hole via LAN IP), 8.8.8.8 fallback
Cluster (CoreDNS)  → forwards to host resolv.conf → Pi-hole; ts.net via coredns-custom → quad100
```

Deliberate detail: the host points at Pi-hole via its **LAN IP, not 127.0.0.1**: k3s propagates
the host `resolv.conf` into CoreDNS, and a loopback address there would make CoreDNS forward to
*itself* (its `loop` plugin would detect this and crash-loop).

## What Changed (prevention)

- **Tailnet global nameservers configured:** the structural gap. A future MagicDNS hiccup
  degrades to a fallback resolver instead of a full outage for every exit-node client.
- **Blackbox DNS probe + `PiholeDNSDown` alert** (this repo: `monitoring-alerts`): Pi-hole is now
  the single DNS upstream for three networks, so its failure must page via ntfy within minutes
  instead of being discovered through downstream symptoms.
- **Runbook knowledge captured:** after any host-DNS change, `kubectl rollout restart deployment
  coredns -n kube-system`; CoreDNS will not pick it up by itself.
- `--accept-dns=false` persisted on the Pi (it hosts the resolver; it must not consume it via
  tailscale's broken resolvconf path).

## Lessons

1. **Fallbacks have to exist before the outage.** Every layer (tailnet, host, cluster) had exactly
   one DNS path and no second option. All three now have ordered fallbacks.
2. **Triage edits are incidents too.** The `8.8.8.8` hand-edit fixed the moment and quietly cost
   sovereignty + ts.net resolution for hours. If an emergency change can't be rolled back
   immediately, it needs a follow-up task the moment it's made.
3. **Reboot-heavy maintenance (kernel/driver work) should be treated as a change window:** check
   `tailscale status`, cluster DNS and Argo sync state *after* the last reboot, not just whether
   the primary task (the driver) succeeded. The Hailo install itself worked flawlessly throughout:
   everything that broke was collateral in layers nobody was watching.
