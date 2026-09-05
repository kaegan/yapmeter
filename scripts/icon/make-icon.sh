#!/bin/bash
# Regenerate the app icon set from AppIcon.svg. The SVG is Yap from
# yapmeter.com (the site's 16-unit sketch, strawberry body, the laughing
# face) on an Apple-shaped squircle. Rasterised with headless Chrome because
# nothing on a stock Mac renders SVG filters; sips does the downscaling.
set -euo pipefail
cd "$(dirname "$0")/../.."

SET=Yapmeter/Assets.xcassets/AppIcon.appiconset
HTML="$(mktemp -t appicon).html"
printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}</style>' > "$HTML"
cat scripts/icon/AppIcon.svg >> "$HTML"

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --hide-scrollbars --default-background-color=00000000 --window-size=1024,1024 \
  --force-device-scale-factor=1 --screenshot="$SET/icon_512x512@2x.png" "file://$HTML" 2>/dev/null

for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$SET/icon_512x512@2x.png" --out "$SET/${spec#*:}.png" >/dev/null
done
rm -f "$HTML"
echo "Wrote $SET"
