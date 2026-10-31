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

### Changed

- The Homepage tile for Beszel links to `:10013`, and the `beszel` Service has a pinned ClusterIP.

### Removed

- The OpenClaw gateway token in the Homepage link, together with its ExternalSecret. Links reach every
  browser that opens Homepage, the panel included.

### Security

- Traefik ports can be bypassed with a forged `Host` header: `tailscale serve` derives `X-Forwarded-Host`
  from it, and the IngressRoutes match on that header. Restricted clients therefore only get direct ports.
- The Pi-hole web interface now requires a password.
