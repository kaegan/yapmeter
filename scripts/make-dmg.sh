#!/bin/bash
# Build the installer disk image: the app on the left, an Applications
# shortcut on the right, the background from scripts/dmg pointing between
# them. The layout lives in the volume's .DS_Store, which dmgbuild writes
# directly; driving Finder over AppleScript needs a logged-in session and
# an automation grant, neither of which a CI runner or a sandboxed shell has.
#
#   scripts/make-dmg.sh path/to/Yapmeter.app path/to/Yapmeter.dmg
#
# Needs dmgbuild: `pipx install dmgbuild` (or `pip3 install dmgbuild`).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: make-dmg.sh <app> <out.dmg>}"
OUT="${2:?usage: make-dmg.sh <app> <out.dmg>}"

if command -v dmgbuild >/dev/null; then
  DMGBUILD=(dmgbuild)
elif python3 -c 'import dmgbuild' 2>/dev/null; then
  DMGBUILD=(python3 -m dmgbuild)
else
  echo "dmgbuild is not installed: pipx install dmgbuild" >&2
  exit 1
fi

rm -f "$OUT"
"${DMGBUILD[@]}" -s scripts/dmg/settings.py -D app="$APP" Yapmeter "$OUT"
echo "Wrote $OUT"
