#!/usr/bin/env bash
# Aktiviert alle Apps aus disabled-packages.txt wieder.
set -euo pipefail
cd "$(dirname "$0")"

while read -r p; do
  [ -z "$p" ] && continue
  adb shell pm enable "$p" < /dev/null
done < disabled-packages.txt
