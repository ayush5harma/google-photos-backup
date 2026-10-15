#!/usr/bin/env bash
# Build "Photos Backup.app": the Swift app, a private Python with gpmc, and
# the bridge between them, signed so macOS keeps its Photos and keychain
# grants across rebuilds.
#
#   scripts/build-app.sh                      build into ./build
#   scripts/build-app.sh --install            ...and copy it to /Applications
#   scripts/build-app.sh --identity -         sign ad hoc (grants reset per build)
#   CODESIGN_IDENTITY="Apple Development: ..." scripts/build-app.sh
#
# Needs Xcode (or its Command Line Tools) for swift, and uv for the Python
# runtime: uv installs a relocatable python-build-standalone CPython, which is
# copied into the bundle whole, so the app depends on nothing on the Mac.

set -euo pipefail

# 2026-10-15: CI hosts run newer macOS; artifacts retain the macOS 14 floor.
export MACOSX_DEPLOYMENT_TARGET=14.0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Photos Backup"
BUNDLE_ID="io.github.ayush5harma.PhotosBackup"
VERSION="0.3.0"
PYTHON_VERSION="${PYTHON_VERSION:-3.13}"
OUT="$ROOT/build"
IDENTITY="${CODESIGN_IDENTITY:-auto}"
INSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --identity) shift; IDENTITY="${1:?--identity needs a name or -}" ;;
    --out) shift; OUT="${1:?--out needs a directory}" ;;
    *) echo "usage: ${0##*/} [--install] [--identity <name>|-] [--out <dir>]" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required: $2" >&2; exit 1; }; }
need swift "install Xcode or run xcode-select --install"
need uv "https://docs.astral.sh/uv/"

APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

say "Compiling the app"
swift build --package-path "$ROOT" -c release --product PhotosBackup
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/PhotosBackup"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES/bridge"
cp "$BIN" "$CONTENTS/MacOS/PhotosBackup"

say "Bundling Python $PYTHON_VERSION"
uv python install --quiet "$PYTHON_VERSION"
PY_BIN="$(uv python find --managed-python "$PYTHON_VERSION")"
# .../cpython-3.13-macos-aarch64-none/bin/python3.13 -> the installation root
PY_HOME="$(cd "$(dirname "$(realpath "$PY_BIN")")/.." && pwd)"
ditto "$PY_HOME" "$RESOURCES/python"
PY_LIB="$(ls -d "$RESOURCES"/python/lib/python3.*)"
# What a headless uploader never loads: Tk, the test suite, IDLE, headers.
rm -rf "$PY_LIB"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} "$PY_LIB"/config-3.* \
       "$RESOURCES"/python/{include,share} "$RESOURCES"/python/lib/{tcl*,tk*,itcl*,thread*,libtcl*,libtk*}
rm -rf "$PY_LIB"/site-packages/pip* "$PY_LIB"/lib-dynload/_tkinter.* "$PY_LIB"/lib-dynload/_curses*
find "$RESOURCES/python/bin" -mindepth 1 ! -name 'python3' ! -name 'python3.[0-9]*[0-9]' -exec rm -f {} +
find "$RESOURCES/python" -name __pycache__ -type d -prune -exec rm -rf {} +
PY="$RESOURCES/python/bin/python3"
"$PY" -I -c 'import ssl, sqlite3, json' # the modules gpmc and requests need

say "Installing backup providers"
uv pip install --quiet --python "$PY" --target "$RESOURCES/bridge/site-packages" -r "$ROOT/Bridge/requirements.txt"
cp "$ROOT/Bridge/"*.py "$RESOURCES/bridge/"
# The app runs Python with -B (no __pycache__ writes into a signed bundle),
# so compile now; unchecked-hash pycs stay valid whatever the copy did to mtimes.
"$PY" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$RESOURCES/python/lib" "$RESOURCES/bridge" >/dev/null
echo '{"command":"version"}' | "$PY" -I -B "$RESOURCES/bridge/gpmc_bridge.py" | grep -q '"gpmc":"' \
  || { echo "the bundled bridge cannot find gpmc" >&2; exit 1; }
# The version answer reads package metadata only; import the whole client so
# a dependency with a broken compiled module fails the build, not a backup.
"$PY" -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from gpmc import Client; from pyicloud_ipd import PyiCloudService' "$RESOURCES/bridge/site-packages" \
  || { echo "the bundled bridge cannot import gpmc" >&2; exit 1; }

"$PY" -I -B "$ROOT/scripts/verify-icloud.py" "$PY" "$RESOURCES/bridge/icloud_bridge.py"

say "Packaging the canonical icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$RESOURCES/AppIcon-light.png" light
swift "$ROOT/scripts/make-icon.swift" "$RESOURCES/AppIcon-dark.png" dark
cp "$RESOURCES/AppIcon-light.png" "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  [ $double -le 1024 ] && sips -z $double $double "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>PhotosBackup</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key><string>Photos Backup reads the albums you select and uploads their photos and videos to your Google Photos account.</string>
  <key>NSContactsUsageDescription</key><string>Photos Backup shows contact names in your Messages archive. Names stay on this Mac.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>photosbackup</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# A real identity keeps the designated requirement stable from build to
# build; TCC (Photos access) and the keychain item's ACL both key on it. Ad
# hoc signing works too, but each rebuild then asks for both again.
if [ "$IDENTITY" = auto ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Apple Development|iPhone Developer|Developer ID Application): [^"]+"' | head -n 1 | tr -d '"' || true)"
  IDENTITY="${IDENTITY:--}"
fi
say "Signing with ${IDENTITY/#-/ad hoc}"
# Inside out: every Mach-O in Resources, then the bundle itself.
find "$RESOURCES" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 \
  | while IFS= read -r -d '' file; do
      if file -b "$file" | grep -q Mach-O; then codesign --force --sign "$IDENTITY" "$file" 2>/dev/null; fi
    done
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

say "Built $APP ($(du -sh "$APP" | cut -f1))"
if [ "$INSTALL" -eq 1 ]; then
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  say "Installed /Applications/$APP_NAME.app"
fi
