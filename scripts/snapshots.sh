#!/usr/bin/env bash
# Render every section of the app to PNG without Screen Recording permission:
# a debug build, inside a copy of the built bundle whose id ends in
# ".snapshots", so it shares no keychain item, state or settings with the real
# app (and refuses to run otherwise).
#
#   scripts/snapshots.sh <out-dir>
#   SNAPSHOT_AUTH='androidId=...&Token=bogus' scripts/snapshots.sh <out-dir>
#
# SNAPSHOT_AUTH goes through Settings' save path; use a throwaway value.
# Needs build/Photos Backup.app from scripts/build-app.sh for the runtime.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: ${0##*/} <out-dir>}"
SOURCE="$ROOT/build/Photos Backup.app"
[ -d "$SOURCE" ] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }

swift build --package-path "$ROOT" --product PhotosBackup
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Photos Backup Snapshots.app"
ditto "$SOURCE" "$APP"
cp "$(swift build --package-path "$ROOT" --show-bin-path)/PhotosBackup" "$APP/Contents/MacOS/PhotosBackup"
snapshot_bundle_id="io.github.ayush5harma.PhotosBackup.snapshots"
# 2026-10-14: fresh identities prevent README captures from inheriting a prior
# fixture's permissions, account, settings, or media history.
if [ "${SNAPSHOT_UI_ONLY:-0}" = 1 ]; then
  snapshot_bundle_id="io.github.ayush5harma.PhotosBackup.preview-$(uuidgen).snapshots"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $snapshot_bundle_id" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/PhotosBackup" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null

mkdir -p "$OUT"
PHOTOS_BACKUP_SNAPSHOTS="$OUT" PHOTOS_BACKUP_SNAPSHOT_AUTH="${SNAPSHOT_AUTH:-}" \
  PHOTOS_BACKUP_SNAPSHOT_UI_ONLY="${SNAPSHOT_UI_ONLY:-0}" \
  "$APP/Contents/MacOS/PhotosBackup" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 60); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  echo "the app did not finish in 60 s" >&2
  exit 1
fi
ls "$OUT"
