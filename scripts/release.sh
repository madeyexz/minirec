#!/bin/bash
# Publishes a new version that installed copies update to.
# Usage: SIGN_IDENTITY="Apple Development: Name (ID)" scripts/release.sh 0.2.0
# Use the same certificate for every release: MiniRec installs an update only when it is
# signed like the running copy, so macOS also keeps the Screen Recording permission.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/release.sh VERSION}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your signing certificate}"

plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Resources/Info.plist
./scripts/build-app.sh
ditto -c -k --keepParent build/MiniRec.app build/MiniRec.zip

git commit -m "Release $VERSION" Resources/Info.plist
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" build/MiniRec.zip --title "MiniRec $VERSION" --generate-notes
