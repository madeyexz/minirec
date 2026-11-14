#!/bin/bash
# Builds build/MiniRec.dmg from build/MiniRec.app: a window where you drag MiniRec to Applications.
# SIGN_IDENTITY signs the image. NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID notarize
# and staple it. The updater uses MiniRec.zip, not this image.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=build/.dmgbuild
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild==1.6.7
fi
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out build/dmg-background.tiff
rm -f build/MiniRec.dmg
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app=build/MiniRec.app -D background=build/dmg-background.tiff \
  MiniRec build/MiniRec.dmg

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" build/MiniRec.dmg
fi
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit build/MiniRec.dmg --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  xcrun stapler staple build/MiniRec.dmg
fi

echo "Built build/MiniRec.dmg"
