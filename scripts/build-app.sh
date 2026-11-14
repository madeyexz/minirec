#!/bin/bash
# Builds build/MiniRec.app and build/MiniRec.zip.
# VERSION sets the app version; the default is the one in Resources/Info.plist.
# SIGN_IDENTITY signs with a real certificate; the default is an ad-hoc signature.
# NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID (an App Store Connect API key)
# notarize and staple the app, so macOS opens it without a warning.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MiniRec"

APP=build/MiniRec.app
rm -rf "$APP" build/MiniRec.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiniRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -n "${VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Hardened runtime and a secure timestamp, which notarization needs.
  codesign --force --options runtime --timestamp --entitlements Resources/MiniRec.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

ditto -c -k --keepParent "$APP" build/MiniRec.zip
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit build/MiniRec.zip --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  # Fails unless Apple accepted the submission; `xcrun notarytool log <id>` says why.
  xcrun stapler staple "$APP"
  rm build/MiniRec.zip
  ditto -c -k --keepParent "$APP" build/MiniRec.zip
fi

echo "Built $APP"
