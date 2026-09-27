#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="OmniVoice"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
STAGING_DIR="$ROOT_DIR/build/dmg-staging"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: $APP_BUNDLE not found — run Scripts/build_app.sh first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
DMG_PATH="$ROOT_DIR/build/$APP_NAME-$VERSION.dmg"

echo "==> staging DMG contents"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
# A symlink to /Applications alongside the .app is the standard macOS
# drag-to-install convention — Finder shows both side by side when the DMG
# is opened.
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> creating $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

# Same caveat as build_app.sh: the .app inside is ad-hoc signed only, and
# the DMG itself isn't signed/notarized either — fine for handing to
# testers who know to run `xattr -cr` (see Docs/RELEASE_TESTING.md), not a
# real release pipeline.
echo "==> done: $DMG_PATH (unsigned/unnotarized — see Docs/RELEASE_TESTING.md)"
