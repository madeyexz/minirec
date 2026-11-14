#!/bin/bash
# Builds build/MiniRec.app. Set SIGN_IDENTITY to sign with a real certificate;
# the default is an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MiniRec"

APP=build/MiniRec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiniRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime and a secure timestamp, which notarization needs.
  codesign --force --options runtime --timestamp --entitlements Resources/MiniRec.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
