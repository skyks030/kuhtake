#!/bin/bash
# Publishes a new version as GitHub release: scripts/release.sh 1.2.0 "Release notes"
# The app's updater downloads the Kuhtake-<version>-macOS.zip asset.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:?Version angeben, z. B. scripts/release.sh 1.1.0 \"Notizen\"}"
NOTES="${2:-Kuhtake $NEW}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Arbeitsverzeichnis ist nicht sauber – bitte erst committen." >&2; exit 1
fi

echo "$NEW" > VERSION
git add VERSION
git commit -m "Release $NEW" >/dev/null || true

scripts/build-app.sh

mkdir -p dist
ZIP="dist/Kuhtake-$NEW-macOS.zip"
DMG="dist/Kuhtake-$NEW.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent build/Kuhtake.app "$ZIP"

STAGE=$(mktemp -d)
cp -R build/Kuhtake.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Kuhtake $NEW" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

git tag "v$NEW"
git push origin HEAD --tags
gh release create "v$NEW" "$ZIP" "$DMG" --title "Kuhtake $NEW" --notes "$NOTES"
echo "✓ Release v$NEW veröffentlicht"
