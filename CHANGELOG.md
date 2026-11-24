# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The repository has no
versioned releases yet, so changes collect under Unreleased. Earlier changes are recorded in the commit
history and in the [incident postmortems](docs/incidents/).

## [Unreleased]

### Added

- `host/ssh/10-hardening.conf`: SSH with keys only and no root login is now part of the repo; `bootstrap.sh`
  installs it and checks it with `sshd -t` before reloading.
- `docs/security.md`: how the AI assistant gets host access, including the current permanent `NOPASSWD`
  entry, and the planned move to hardware security keys (YubiKey) for SSH, sudo, accounts and the age key.
- Publishing basics: `.env.example` for `kubara bootstrap`, issue forms (bug, idea) with a link to private
  vulnerability reporting, and a pull request template.
- Wall panel: an old Android tablet shows Homepage and Home Assistant in kiosk mode and is treated as an
  untrusted device (`tag:wallpanel`), see [docs/wallpanel.md](docs/wallpanel.md).
- Direct `tailscale serve` entry points that bypass Traefik: `:10012` for Homepage (Service
  `homepage-wallpanel`) and `:10013` for Beszel.
- Pi-hole statistics widget on Homepage. The app password stays server-side in the Secret
  `pihole-homepage-key`.
- Provisioning scripts for the tablet in [scripts/wallpanel/](scripts/wallpanel/).
- Updates without manual work on the host: `pi-autodeploy` deploys the Docker Compose apps after merges
  (green CI only, backup first, rollback if not healthy), a Sunday reboot runs only when an update requires
  it, and ntfy gets a report after every boot and a weekly summary. See
  [docs/operations.md](docs/operations.md#updates-run-on-their-own).
- `host/scripts/argo-upgrade.sh` applies a merged argo-cd chart update with filtered `kubara` output.
- External watchdog: `pi-heartbeat.timer` pings an external service every hour, which sends an e-mail when
  the Pi goes silent. ntfy runs on the Pi itself and cannot report the Pi's own outage. See
  [docs/operations.md](docs/operations.md#external-watchdog).
- `host/updates.sh` installs the update automation on its own; `bootstrap.sh` calls it.

### Changed

- Security docs no longer claim that nothing is reachable from the local network: DNS and key-only SSH are
  open there. The host firewall trusts the tailnet interface; per-device limits come from the Tailscale ACLs.
- README no longer says that no data leaves the local network: the OpenClaw backend runs on a cloud VM,
  reached only through the tailnet.
- The pull request template no longer forbids tailnet names and internal IPs, which are documented on purpose.
- CI pins `actions/checkout` to a commit hash and runs with `TZ=Europe/Berlin`.
- `.gitignore` also excludes keys, certificates, databases and backups.
- README: nine postmortems, port map with 14 ports and 17 services, the Oracle VM hosts OpenClaw (no test
  sandbox any more); copyright entered in `LICENSE`.
- Renovate runs for every own repo with a `renovate.json` (autodiscover) at 01:30 instead of only for this
  repo at 02:30. Minor updates of stateless helper images auto-merge, and Renovate now tracks k3s
  (`K3S_VERSION` in `bootstrap.sh`) and Home Assistant (pinned to 2026.9.4 instead of `stable`).
- unattended-upgrades also updates Docker and runs at 02:15 instead of in the morning.
- Renovate runs a pinned image (version and digest) instead of `latest` and updates itself three days after
  a release at the earliest.
- The Homepage tile for Beszel links to `:10013`, and the `beszel` Service has a pinned ClusterIP.
- Tailscale on the host runs 1.104.4 and is no longer pinned to 1.102.5. Since 1.104 `tailscale serve`
  only answers on `tailscale0`, see [docs/operations.md](docs/operations.md).

### Fixed

- pi-autodeploy deployed only the first app in `host/apps.txt`: `docker compose exec` (the backup before an
  update) read the rest of the list from stdin. The list is now read before the loop.
- Renovate ran out of memory with all repos in one process (Node heap ~384 MB in the 768 MB container). The
  mesh now runs in a process of its own, and the ntfy alert shows the error lines instead of a stack trace.
- Homepage status checks (`siteMonitor`) use internal addresses. Through the serve URLs they fail with
  Tailscale 1.104 and later.

### Removed

- The OpenClaw gateway token in the Homepage link, together with its ExternalSecret. Links reach every
  browser that opens Homepage, the panel included.

### Security

- Traefik ports can be bypassed with a forged `Host` header: `tailscale serve` derives `X-Forwarded-Host`
  from it, and the IngressRoutes match on that header. Restricted clients therefore only get direct ports.
- The Pi-hole web interface now requires a password.
