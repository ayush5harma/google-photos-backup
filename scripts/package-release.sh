#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: package-release.sh <app> <arm64|x86_64> [output-directory]}"
ARCH="${2:?architecture required}"
OUT="${3:-$ROOT/dist}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'unsupported architecture' >&2; exit 2 ;; esac
python3 "$ROOT/scripts/verify-app.py" "$APP" "$ARCH"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ZIP="Photos-Backup-0.3.0-macOS-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
ditto -x -k "$OUT/$ZIP" "$TEMP"
python3 "$ROOT/scripts/verify-app.py" "$TEMP/Photos Backup.app" "$ARCH"
(cd "$OUT" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
printf 'Packaged %s\n' "$OUT/$ZIP"
