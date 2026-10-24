#!/bin/bash
# DNS-Watchdog: Pi-hole + Unbound automatisch neu starten wenn sie nicht antworten
if ! dig @127.0.0.1 -p 5335 cloudflare.com A +short +time=3 +tries=1 > /dev/null 2>&1; then
  logger -t dns-watchdog "Unbound antwortet nicht — Neustart"
  systemctl restart unbound
  sleep 3
fi
if ! dig @127.0.0.1 cloudflare.com A +short +time=3 +tries=1 > /dev/null 2>&1; then
  logger -t dns-watchdog "Pi-hole antwortet nicht — Neustart"
  systemctl restart pihole-FTL
fi
