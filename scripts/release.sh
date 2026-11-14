#!/bin/bash
# Publishes a new version that installed copies update to.
# Usage: SIGN_IDENTITY="Developer ID Application: Name (TEAM)" NOTARY_PROFILE=minirec scripts/release.sh 0.4.0
# MiniRec installs an update only when the same Apple developer team signed it.
# NOTARY_PROFILE is a keychain profile made with `xcrun notarytool store-credentials`.
# With it, the app is notarized and stapled, so macOS opens it without a warning.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/release.sh VERSION}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your signing certificate}"

plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Resources/Info.plist
./scripts/build-app.sh
ditto -c -k --keepParent build/MiniRec.app build/MiniRec.zip
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit build/MiniRec.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/MiniRec.app
  rm build/MiniRec.zip
  ditto -c -k --keepParent build/MiniRec.app build/MiniRec.zip
fi

git commit -m "Release $VERSION" Resources/Info.plist
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" build/MiniRec.zip --title "MiniRec $VERSION" --generate-notes
