#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="OmniVoice"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"

echo "==> swift build --configuration release"
swift build --package-path "$ROOT_DIR" --configuration release

echo "==> packaging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc signing only — good enough for local TCC prompts (mic/speech/screen
# recording) to stick to this bundle identity during development. The real
# release pipeline (signing with a Developer ID cert, notarization, stapling)
# is a separate, not-yet-written script — see the project's open items on
# distribution.
echo "==> ad-hoc codesigning (development only, not a release build)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "Run with: open \"$APP_BUNDLE\""
