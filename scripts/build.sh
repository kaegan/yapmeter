#!/bin/bash
# Generate the Xcode project, build Yapmeter, install it to ~/Applications,
# and launch it. Use this for autonomous verification; use Xcode (⌘R) for
# interactive debugging.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
DERIVED_DATA="build/DerivedData"
APP_NAME="Yapmeter.app"
INSTALL_DIR="$HOME/Applications"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building ($CONFIGURATION)"
xcodebuild \
  -project Yapmeter.xcodeproj \
  -scheme Yapmeter \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [ ! -d "$BUILT_APP" ]; then
  echo "Build succeeded but $BUILT_APP not found" >&2
  exit 1
fi

# Quit the running copy before replacing its bundle. Replacing the bundle
# under a live process leaves it unable to prove its identity to macOS, so
# Sparkle's next install fails with "an error occurred while launching the
# installer" (YAP-72). The pgrep guard matters: `tell application ... to
# quit` launches the app if nothing is running.
if pgrep -xq Yapmeter; then
  echo "==> Quitting the running Yapmeter"
  osascript -e 'tell application id "fyi.kaegan.yapmeter" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -xq Yapmeter || break
    sleep 0.25
  done
  if pgrep -xq Yapmeter; then
    echo "    Still running after 5s, killing it"
    pkill -x Yapmeter || true
    sleep 1
  fi
fi

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_APP" "$INSTALL_DIR/$APP_NAME"

echo "==> Launching"
open "$INSTALL_DIR/$APP_NAME"

echo "==> Done. Bundle ID: fyi.kaegan.yapmeter"
