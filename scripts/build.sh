#!/bin/bash
# Generate the Xcode project, build Semaphore, install it to ~/Applications,
# and launch it. Use this for autonomous verification; use Xcode (⌘R) for
# interactive debugging.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
DERIVED_DATA="build/DerivedData"
APP_NAME="Semaphore.app"
INSTALL_DIR="$HOME/Applications"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building ($CONFIGURATION)"
xcodebuild \
  -project Semaphore.xcodeproj \
  -scheme Semaphore \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [ ! -d "$BUILT_APP" ]; then
  echo "Build succeeded but $BUILT_APP not found" >&2
  exit 1
fi

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_APP" "$INSTALL_DIR/$APP_NAME"

echo "==> Launching"
open "$INSTALL_DIR/$APP_NAME"

echo "==> Done. Bundle ID: fyi.kaegan.semaphore"
