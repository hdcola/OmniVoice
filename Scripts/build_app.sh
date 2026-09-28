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

# Package.swift links CAudioCpp/llama against third_party/{audio.cpp,llama.cpp}
# with absolute-path -rpath entries (see Package.swift's audioCppLibDir/
# llamaCppLibDir) — those only resolve on this build machine, at this
# checkout path. Copy the actual @rpath dylibs into the bundle and repoint
# everything at a relocatable @executable_path/@loader_path rpath, or the
# app dies at launch on any other machine with "Library not loaded".
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
MAIN_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

rpaths_of() {
  otool -l "$1" | awk '
    /LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset.*/, ""); print }
  '
}

rpath_deps_of() {
  # Skip line 1: the binary's own path (executable) or install name (dylib).
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^@rpath/'
}

echo "==> embedding @rpath dylib dependencies into $FRAMEWORKS_DIR"
# Plain indexed arrays + a newline-joined "seen" list only — this runs under
# whatever `bash` is first on PATH, which on a stock macOS install is the
# system bash 3.2 (no `mapfile`, no associative arrays).
queue=("$MAIN_BIN")
copied_names=$'\n'
while [ "${#queue[@]}" -gt 0 ]; do
  bin="${queue[0]}"
  queue=("${queue[@]:1}")

  bin_rpaths=()
  while IFS= read -r rp; do
    [ -n "$rp" ] && bin_rpaths+=("$rp")
  done < <(rpaths_of "$bin")

  for dep in $(rpath_deps_of "$bin"); do
    dep_name="${dep#@rpath/}"
    case "$copied_names" in
      *$'\n'"$dep_name"$'\n'*) continue ;;
    esac

    resolved=""
    for rp in "${bin_rpaths[@]}"; do
      if [ -f "$rp/$dep_name" ]; then
        resolved="$rp/$dep_name"
        break
      fi
    done
    if [ -z "$resolved" ]; then
      echo "error: could not resolve $dep referenced by $bin (looked in: ${bin_rpaths[*]})" >&2
      exit 1
    fi

    cp "$resolved" "$FRAMEWORKS_DIR/$dep_name"
    copied_names="$copied_names$dep_name"$'\n'
    queue+=("$FRAMEWORKS_DIR/$dep_name")
  done
done

echo "==> rewriting rpaths for relocatability"
for rp in $(rpaths_of "$MAIN_BIN"); do
  install_name_tool -delete_rpath "$rp" "$MAIN_BIN" 2>/dev/null || true
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_BIN"

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
  [ -e "$dylib" ] || continue
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
  for rp in $(rpaths_of "$dylib"); do
    install_name_tool -delete_rpath "$rp" "$dylib" 2>/dev/null || true
  done
  install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
done

# Ad-hoc signing only — good enough for local TCC prompts (mic/speech/screen
# recording) to stick to this bundle identity during development. The real
# release pipeline (signing with a Developer ID cert, notarization, stapling)
# is a separate, not-yet-written script — see the project's open items on
# distribution.
echo "==> ad-hoc codesigning (development only, not a release build)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo "Run with: open \"$APP_BUNDLE\""
