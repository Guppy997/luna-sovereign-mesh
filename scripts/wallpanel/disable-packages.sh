#!/usr/bin/env bash
# Deaktiviert die Apps aus disabled-packages.txt auf dem per USB verbundenen
# Wand-Tablet (pm disable-user, nicht deinstallieren). Rückgängig: enable-all.sh
#
# < /dev/null ist nötig: adb shell liest sonst stdin mit und schluckt den Rest
# der Liste.
set -euo pipefail
cd "$(dirname "$0")"

while read -r p; do
  [ -z "$p" ] && continue
  r=$(adb shell pm disable-user --user 0 "$p" < /dev/null 2>&1 | tr -d '\r' || true)
  case "$r" in *disabled-user*) echo "OK   $p";; *) echo "FAIL $p -> $r";; esac
done < disabled-packages.txt
