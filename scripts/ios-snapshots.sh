#!/usr/bin/env bash
# Screenshots of the iOS app from fixture mode, for docs/.
#
#   scripts/ios-snapshots.sh <out-dir>
#
# Builds for the simulator, boots an available iPhone simulator (or the one
# in SIMULATOR_UDID), installs the app and launches it once per tab and
# appearance with PHOTOS_BACKUP_SNAPSHOT_FIXTURE=1: made-up data, no Photos
# access, no Keychain, no network, and a throwaway PHOTOS_BACKUP_SANDBOX.
# Writes ios-<tab>-<light|dark>.png. Look at every image before publishing
# it (docs/SCREENSHOTS.md).
set -euo pipefail
trap 'echo "ios-snapshots: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: ios-snapshots.sh <out-dir>}"
BUNDLE_ID=io.github.ayush5harma.PhotosBackup
TABS=(overview albums activity settings)
MAX_WIDTH=1400
# Seconds for a launch to draw its first screen; measured about 1.5 s on an
# iPhone 17 simulator (2026-11-26), with room for a cold first launch.
SETTLE="${SNAPSHOT_SETTLE:-4}"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP="$("$ROOT/scripts/build-ios.sh" --simulator)"

UDID="${SIMULATOR_UDID:-}"
if [ -z "$UDID" ]; then
  # A regular iPhone on the newest iOS runtime that has one. The foldable
  # iPhone Duo (iOS 27.1 simulator, 2026-11-26) is passed over: its outer
  # display is not the shape the published screenshots show.
  UDID="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    tail = runtime.rsplit(".", 1)[-1]
    return [int(part) for part in tail.split("-")[1:] if part.isdigit()] if tail.startswith("iOS") else []
for runtime in sorted((r for r in devices if version(r)), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and "Duo" not in d["name"]]
    if phones:
        print(phones[0]["udid"])
        break
')"
fi
[ -n "$UDID" ] || { echo "ios-snapshots: no available iPhone simulator" >&2; exit 1; }

WAS_BOOTED=0
if xcrun simctl list devices | grep -q "$UDID) (Booted)"; then WAS_BOOTED=1; fi
SANDBOX="$(mktemp -d)"
cleanup() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  if [ "$WAS_BOOTED" = 0 ]; then xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

echo "ios-snapshots: simulator $UDID" >&2
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" "$APP"

for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for tab in "${TABS[@]}"; do
    SIMCTL_CHILD_PHOTOS_BACKUP_SNAPSHOT_FIXTURE=1 \
    SIMCTL_CHILD_PHOTOS_BACKUP_SANDBOX="$SANDBOX" \
    SIMCTL_CHILD_PHOTOS_BACKUP_TAB="$tab" \
      xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
    sleep "$SETTLE"
    IMAGE="$OUT/ios-$tab-$appearance.png"
    xcrun simctl io "$UDID" screenshot --type=png "$IMAGE" >/dev/null 2>&1
    WIDTH="$(sips -g pixelWidth "$IMAGE" | awk '/pixelWidth/ { print $2 }')"
    if [ "$WIDTH" -gt "$MAX_WIDTH" ]; then sips --resampleWidth "$MAX_WIDTH" "$IMAGE" >/dev/null; fi
    echo "$IMAGE"
  done
done
