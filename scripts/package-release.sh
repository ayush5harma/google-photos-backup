#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: package-release.sh <app> <arm64|x86_64> [output-directory]}"
ARCH="${2:?architecture required}"
OUT="${3:-$ROOT/dist}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'unsupported architecture' >&2; exit 2 ;; esac
VERSION="$(cat "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'invalid release version' >&2; exit 2; }
python3 "$ROOT/scripts/verify-app.py" "$APP" "$ARCH"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ZIP="Photos-Backup-$VERSION-macOS-$ARCH.zip"
DMG="Photos-Backup-$VERSION-macOS-$ARCH.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
TEMP="$(mktemp -d)"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then hdiutil detach "$TEMP/mounted" >/dev/null || true; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT
ditto -x -k "$OUT/$ZIP" "$TEMP"
python3 "$ROOT/scripts/verify-app.py" "$TEMP/Photos Backup.app" "$ARCH"

mkdir -p "$TEMP/image" "$TEMP/mounted"
ditto "$TEMP/Photos Backup.app" "$TEMP/image/Photos Backup.app"
ln -s /Applications "$TEMP/image/Applications"
hdiutil create -ov -volname 'Photos Backup' -srcfolder "$TEMP/image" -fs HFS+ -format UDZO "$OUT/$DMG" >/dev/null
hdiutil verify "$OUT/$DMG" >/dev/null
hdiutil attach "$OUT/$DMG" -readonly -nobrowse -mountpoint "$TEMP/mounted" >/dev/null
MOUNTED=1
test "$(readlink "$TEMP/mounted/Applications")" = /Applications
ditto "$TEMP/mounted/Photos Backup.app" "$TEMP/from-dmg/Photos Backup.app"
python3 "$ROOT/scripts/verify-app.py" "$TEMP/from-dmg/Photos Backup.app" "$ARCH"
hdiutil detach "$TEMP/mounted" >/dev/null
MOUNTED=0
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256" && shasum -a 256 "$DMG" > "$DMG.sha256")
printf 'Packaged %s\n' "$OUT/$ZIP" "$OUT/$DMG"
