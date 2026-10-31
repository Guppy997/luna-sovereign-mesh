#!/usr/bin/env bash
# Setzt in FreeKiosk: Sperrmodus, Zurück-Button, Autostart und URL-Whitelist.
# FreeKiosk nimmt Änderungen per adb nur mit dem aktuellen PIN an. Der PIN wird
# unsichtbar abgefragt und landet weder im Shell-Verlauf noch in einer Datei.
set -euo pipefail

# Muster gelten für die ganze URL, * = beliebig. "host:*" erlaubt alle Ports und
# Pfade auf dem Pi, aber keine Fremd-Domain wie "host.evil.com".
FILTER='["raspberrypi-1.tailddc8f7.ts.net:*","lern-pwa.tailddc8f7.ts.net","lern-pwa.tailddc8f7.ts.net/*","fitness-pwa.tailddc8f7.ts.net","fitness-pwa.tailddc8f7.ts.net/*"]'

read -rsp 'FreeKiosk-PIN: ' PIN; echo

adb shell "am start -n com.freekiosk/.MainActivity --es pin '$PIN' \
  --ez kiosk_enabled true \
  --ez webview_back_button_enabled true \
  --es auto_launch true \
  --es auto_relaunch true \
  --ez url_filter_enabled true \
  --es url_filter_mode whitelist \
  --ez url_filter_show_feedback true \
  --es url_filter_list '$FILTER'"

unset PIN
echo "Gesendet. Auf dem Tablet sollte FreeKiosk neu laden."
