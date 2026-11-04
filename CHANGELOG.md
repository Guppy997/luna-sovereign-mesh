# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The repository has no
versioned releases yet, so changes collect under Unreleased. Earlier changes are recorded in the commit
history and in the [incident postmortems](docs/incidents/).

## [Unreleased]

### Added

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

### Changed

- Renovate runs for every own repo with a `renovate.json` (autodiscover) at 01:30 instead of only for this
  repo at 02:30. Minor updates of stateless helper images auto-merge, and Renovate now tracks k3s
  (`K3S_VERSION` in `bootstrap.sh`) and Home Assistant (pinned to 2026.9.4 instead of `stable`).
- unattended-upgrades also updates Docker and runs at 02:15 instead of in the morning.
- The Homepage tile for Beszel links to `:10013`, and the `beszel` Service has a pinned ClusterIP.
- Tailscale on the host runs 1.104.4 and is no longer pinned to 1.102.5. Since 1.104 `tailscale serve`
  only answers on `tailscale0`, see [docs/operations.md](docs/operations.md).

### Fixed

- Homepage status checks (`siteMonitor`) use internal addresses. Through the serve URLs they fail with
  Tailscale 1.104 and later.

### Removed

- The OpenClaw gateway token in the Homepage link, together with its ExternalSecret. Links reach every
  browser that opens Homepage, the panel included.

### Security

- Traefik ports can be bypassed with a forged `Host` header: `tailscale serve` derives `X-Forwarded-Host`
  from it, and the IngressRoutes match on that header. Restricted clients therefore only get direct ports.
- The Pi-hole web interface now requires a password.
