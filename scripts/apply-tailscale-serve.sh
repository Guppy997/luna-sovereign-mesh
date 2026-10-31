#!/usr/bin/env bash
# Stellt die komplette Tailscale-Serve-Konfiguration des Pi her (idempotent).
#
# Hintergrund: `tailscale serve` lebt nur im tailscaled-State, nicht in Git.
# Am 2026-07-14 fehlten die Einträge 10001/10005/10006/10007 (vermutlich bei
# den AppFlowy-Experimenten am 05./06.07. mit entfernt) — Homepage, Plane,
# Vaultwarden und Affine waren dadurch unerreichbar. Dieses Skript ist die
# Source of Truth; nach Änderungen hier auch die Tabelle im README pflegen.
#
# Traefik-Ports (10001, 10005-10009) routen per X-Forwarded-Host-Matcher in
# den IngressRoutes — siehe traefik/values.yaml (ClusterIP gepinnt).
# Den Header leitet tailscale serve aus dem Host-Header des Clients ab: Über
# JEDEN Traefik-Port erreicht man mit gefälschtem Host alle Traefik-Dienste.
# Eingeschränkte Clients (Wand-Tablet) bekommen deshalb nur direkte Ports,
# siehe docs/wallpanel.md.
set -euo pipefail

TRAEFIK=http://10.43.53.234:80 # gepinnte ClusterIP, siehe traefik/values.yaml

declare -A SERVE=(
  [10000]=http://127.0.0.1:8090  # Lern-PWA (Host)
  [10001]=$TRAEFIK               # Homepage / ArgoCD / Grafana / Prometheus / Alertmanager
  [10002]=http://127.0.0.1:8081  # Pi-hole (Host)
  [10003]=http://10.43.235.81:80 # ntfy (gepinnte ClusterIP)
  [10004]=http://10.43.132.118:80 # Luna Dashboard (gepinnte ClusterIP)
  [10005]=$TRAEFIK               # Plane
  [10006]=$TRAEFIK               # Vaultwarden
  [10007]=$TRAEFIK               # Affine
  [10008]=$TRAEFIK               # Beszel
  [10009]=$TRAEFIK               # Beaver Habits
  [10010]=http://127.0.0.1:8123  # Home Assistant (Host)
  [10011]=http://127.0.0.1:8091  # Fitness-PWA (Host)
  [10012]=http://10.43.100.12:3000 # Homepage direkt ohne Traefik, fürs Wand-Tablet (gepinnte ClusterIP)
  [10013]=http://10.43.73.18:8090 # Beszel direkt ohne Traefik, fürs Wand-Tablet (gepinnte ClusterIP)
)

for port in "${!SERVE[@]}"; do
  echo "serve :${port} -> ${SERVE[$port]}"
  sudo tailscale serve --bg --https="$port" "${SERVE[$port]}"
done

echo
tailscale serve status
