#!/usr/bin/env bash
# UFW-Regeln des Pi (Ist-Stand 2026-10-24). Idempotent: ufw überspringt Regeln, die es
# schon gibt. Die Allow-Regeln für SSH kommen vor `ufw enable`, damit eine laufende
# SSH-Sitzung nicht abreißt.
#
# Aus dem LAN sind nur SSH und DNS offen, alles andere nur über das Tailnet.
set -Eeuo pipefail

LAN=192.168.178.0/24
TAILNET=100.64.0.0/10

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# Das Tailnet-Interface ist als Ganzes erlaubt. Die Port-Regeln für $TAILNET darunter
# dokumentieren nur, was gebraucht wird; was ein Gerät erreichen darf, entscheiden die
# Tailscale-ACLs (siehe docs/security.md).
ufw allow in on tailscale0
ufw allow from "$LAN" to any port 22 comment 'SSH lokal'
ufw allow from "$TAILNET" to any port 22 comment 'SSH Tailscale'
ufw allow from "$LAN" to any port 53 comment 'DNS Pi-hole'
ufw allow from "$TAILNET" to any port 8081 comment 'Pi-hole Admin Tailscale'
ufw allow from "$TAILNET" to any port 80 comment 'Traefik HTTP Tailscale'
ufw allow from "$TAILNET" to any port 443 comment 'Traefik HTTPS Tailscale'
ufw allow from "$TAILNET" to any port 6443 comment 'k3s API Tailscale'

# Cluster-interner Verkehr (Pods, Flannel) und Loopback
ufw allow in on cni0
ufw allow in on flannel.1
ufw allow in on lo

ufw --force enable
