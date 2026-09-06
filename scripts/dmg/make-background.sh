#!/bin/bash
# Rasterise background.svg into the Finder background the installer DMG
# uses. Finder wants one TIFF holding a 1x and a 2x image so the window is
# sharp on both kinds of display; headless Chrome renders the SVG (same
# reason as scripts/icon/make-icon.sh: nothing on a stock Mac does), and
# tiffutil stitches the pair together.
set -euo pipefail
cd "$(dirname "$0")"

HTML="$(mktemp -t dmgbg).html"
printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}</style>' > "$HTML"
cat background.svg >> "$HTML"

for scale in 1 2; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
    --hide-scrollbars --window-size=660,400 --force-device-scale-factor="$scale" \
    --screenshot="background@${scale}x.png" "file://$HTML" 2>/dev/null
done
tiffutil -cathidpicheck background@1x.png background@2x.png -out background.tiff
rm -f "$HTML" background@1x.png background@2x.png
echo "Wrote scripts/dmg/background.tiff"
