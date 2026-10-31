# Wall Panel

An old Galaxy Tab A7 (SM-T505, Android 12, last security patch 2024-06) hangs on the wall as a dashboard
and Home Assistant remote. It runs FreeKiosk as Device Owner and is treated as **untrusted**: it sits in
the router's guest Wi-Fi and reaches the Pi only through the tailnet as `tag:wallpanel`.

## What it can reach

| Service | Target | Path |
|---|---|---|
| Homepage | `raspberrypi-1:10012` | `homepage-wallpanel` Service, pinned ClusterIP `10.43.100.12` |
| Home Assistant | `raspberrypi-1:10010` | host port 8123 |
| Pi-hole | `raspberrypi-1:10002` | host port 8081 |
| Beszel | `raspberrypi-1:10013` | `beszel` Service, pinned ClusterIP `10.43.73.18` |
| ntfy | `raspberrypi-1:10003` | `ntfy` Service, pinned ClusterIP |
| Lern-PWA, Fitness-PWA | `lern-pwa:443`, `fitness-pwa:443` | their Tailscale sidecars |

Nothing else, and nothing can reach the tablet: no ACL rule has it as a destination.

## Why the panel never gets a Traefik port

The Traefik ports (10001, 10005–10009) pick the backend with `HeaderRegexp(X-Forwarded-Host, ...)`.
`tailscale serve` overwrites a client-supplied `X-Forwarded-Host`, but builds it from the client's
`Host` header. A client that may reach *one* Traefik port can therefore reach *all* Traefik services:

```bash
H=raspberrypi-1.tailddc8f7.ts.net
curl -s https://$H:10008/ -H "Host: $H:10007" | grep -o '<title>[^<]*'
# <title>AFFiNE, although :10008 is Beszel
```

Tailscale ACLs filter by port, not by path or header. Every service the panel needs gets its own
`tailscale serve` port that points straight at a pinned ClusterIP or host port, never at Traefik.
For personal devices this does not matter, as they may reach every port anyway.

## Tailscale policy

```jsonc
"hosts": {
	"raspberrypi-1": "100.113.125.35",
	"lern-pwa":      "100.116.194.103",
	"fitness-pwa":   "100.74.14.94",
},
"tagOwners": {
	"tag:wallpanel": ["autogroup:admin"],
},
"acls": [
	{
		"action": "accept",
		"src":    ["tag:wallpanel"],
		"dst":    ["raspberrypi-1:10012,10010,10002,10013,10003", "lern-pwa:443", "fitness-pwa:443"],
	},
],
"tests": [
	{
		"src":    "tag:wallpanel",
		"accept": ["raspberrypi-1:10012", "raspberrypi-1:10013", "lern-pwa:443"],
		"deny":   ["raspberrypi-1:10001", "raspberrypi-1:10006", "raspberrypi-1:22"],
	},
],
```

Tagged devices do not expire, so the panel keeps its key. The Pi is still a user device and does
expire: disable key expiry for `raspberrypi-1`, or the panel goes dark with it.

## Secrets on the panel

- **Homepage `href`s reach every browser**, the panel included. They must never carry a token; the
  OpenClaw token was removed for this reason (#26).
- **Widget credentials stay server-side.** Homepage calls the APIs itself and sends only the results.
- The Pi-hole widget reads an app password from the Secret `pihole-homepage-key` (namespace
  `homepage`, created by hand, not in Git). The env var is `optional`, so Homepage starts without it:

```bash
read -rs K; sudo k3s kubectl create secret generic pihole-homepage-key -n homepage --from-literal=key="$K"; unset K
sudo k3s kubectl -n homepage rollout restart deploy/homepage
```

## Tablet hardening

- Preinstalled apps disabled with `pm disable-user --user 0` (Galaxy Store, Bixby, Quick Share, Smart View,
  Edge panels, Google and partner apps, Chrome, camera app). Reversible with `pm enable`.
- Android System WebView updated through the Play Store before the Device Owner was set; FreeKiosk
  renders the pages with it.
- FreeKiosk as Device Owner (`dpm set-device-owner com.freekiosk/.DeviceAdminReceiver`), REST API and
  MQTT off, URL filter in whitelist mode for the tailnet hostnames above.
- Tailscale and FreeKiosk exempt from Doze (`dumpsys deviceidle whitelist +<package>`).
- USB debugging and developer options off once the setup is done.

## Known trade-offs

- **Home Assistant has no per-entity permissions.** The panel's non-admin user can still switch every
  entity, including `switch.ki_server` (Jarvis on/off).
- **Pi-hole has no read-only role.** Logged in on the panel means full Pi-hole admin.
- **ntfy has no authentication** here, so the panel can publish as well as read.
- Android's `com.android.proxyhandler` listens on a TCP port on all interfaces. Client isolation in
  the guest Wi-Fi must stay on.
