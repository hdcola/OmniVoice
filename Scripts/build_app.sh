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
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Package.swift links CAudioCpp/llama against third_party/{audio.cpp,llama.cpp}
# with absolute-path -rpath entries (see Package.swift's audioCppLibDir/
# llamaCppLibDir) — those only resolve on this build machine, at this
# checkout path. Copy the actual @rpath dylibs into the bundle and repoint
# everything at a relocatable @executable_path/@loader_path rpath, or the
# app dies at launch on any other machine with "Library not loaded".
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
MAIN_BIN="$MACOS_DIR/$APP_NAME"

rpaths_of() {
  otool -l "$1" | awk '
    /LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset.*/, ""); print }
  '
}

rpath_deps_of() {
  # otool -L's line 1 is always the file's own path (executable) or install
  # name (dylib) — skip it. A dylib (unlike an executable) also re-lists
  # itself as its very first dependency (its LC_ID_DYLIB); exclude that via
  # `otool -D` too, since a dylib's on-disk filename can differ from its
  # install name's basename (e.g. built as libfoo.dylib but installed as
  # @rpath/libfoo.0.dylib) — left in, that self-reference would otherwise
  # get chased as an unresolved dependency.
  local self_id
  self_id="$(otool -D "$1" 2>/dev/null | tail -n 1 || true)"
  otool -L "$1" | awk -v self="$self_id" 'NR > 1 && $1 ~ /^@rpath\// && $1 != self { print $1 }'
}

# @executable_path always means the main executable's directory, regardless
# of which binary declared the rpath; @loader_path means the directory of
# the binary that declared it (for anything already copied into
# Contents/Frameworks, that's Frameworks itself).
resolve_rpath_token() {
  local rp="$1" owner_dir="$2"
  case "$rp" in
    @executable_path*) printf '%s\n' "${rp/@executable_path/$MACOS_DIR}" ;;
    @loader_path*) printf '%s\n' "${rp/@loader_path/$owner_dir}" ;;
    *) printf '%s\n' "$rp" ;;
  esac
}

echo "==> embedding @rpath dylib dependencies into $FRAMEWORKS_DIR"
# Plain indexed arrays + a newline-joined "seen" list only, and every bare
# "${arr[@]}"/"${arr[*]}" below uses a `:0` offset — this runs under
# whatever `bash` is first on PATH, which on a stock macOS install is the
# system bash 3.2: no `mapfile`, no associative arrays, and (unlike modern
# bash) `set -u` treats a bare expansion of an *empty* array as an
# unbound-variable error and aborts the script, not as an empty list.
#
# A dylib built without its own LC_RPATH (common — CMake typically only
# rpath's the final executable, relying on it to resolve every transitively
# linked dylib) can't resolve its own @rpath deps from its own rpaths alone.
# So `search_paths` accumulates every directory we've ever resolved a dylib
# from, seeded with the main executable's rpaths, and every binary's lookup
# falls back to it.
search_paths=()
while IFS= read -r rp; do
  [ -n "$rp" ] && search_paths+=("$(resolve_rpath_token "$rp" "$MACOS_DIR")")
done < <(rpaths_of "$MAIN_BIN")
search_paths+=("$FRAMEWORKS_DIR")

queue=("$MAIN_BIN")
copied_names=$'\n'
while [ "${#queue[@]}" -gt 0 ]; do
  bin="${queue[0]}"
  queue=("${queue[@]:1}")
  owner_dir="$(dirname "$bin")"

  bin_rpaths=()
  while IFS= read -r rp; do
    [ -n "$rp" ] && bin_rpaths+=("$(resolve_rpath_token "$rp" "$owner_dir")")
  done < <(rpaths_of "$bin")

  for dep in $(rpath_deps_of "$bin"); do
    dep_name="${dep#@rpath/}"
    case "$copied_names" in
      *$'\n'"$dep_name"$'\n'*) continue ;;
    esac

    resolved=""
    for rp in "${bin_rpaths[@]:0}" "${search_paths[@]:0}"; do
      if [ -f "$rp/$dep_name" ]; then
        resolved="$rp/$dep_name"
        break
      fi
    done
    if [ -z "$resolved" ]; then
      echo "error: could not resolve $dep referenced by $bin (looked in: ${bin_rpaths[*]:0} ${search_paths[*]:0})" >&2
      exit 1
    fi

    cp "$resolved" "$FRAMEWORKS_DIR/$dep_name"
    copied_names="$copied_names$dep_name"$'\n'
    search_paths+=("$(dirname "$resolved")")
    queue+=("$FRAMEWORKS_DIR/$dep_name")
  done
done

echo "==> rewriting rpaths for relocatability"
# `for rp in $(rpaths_of ...)` word-splits on whitespace — a build/checkout
# path with a space in it (e.g. "~/My Projects/OmniVoice") would silently
# truncate the rpath argument and fail to delete it. Use the same
# `while IFS= read -r` form as the embedding loop above instead.
while IFS= read -r rp; do
  [ -n "$rp" ] && install_name_tool -delete_rpath "$rp" "$MAIN_BIN" 2>/dev/null || true
done < <(rpaths_of "$MAIN_BIN")
# `2>/dev/null || true`: a fresh copy of the swift build product never
# already has this rpath, but stay idempotent (install_name_tool errors
# with "would duplicate path" otherwise) in case that ever changes.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_BIN" 2>/dev/null || true

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
  [ -e "$dylib" ] || continue
  install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
  while IFS= read -r rp; do
    [ -n "$rp" ] && install_name_tool -delete_rpath "$rp" "$dylib" 2>/dev/null || true
  done < <(rpaths_of "$dylib")
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
