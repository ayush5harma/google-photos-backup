#!/usr/bin/env bash
# The iOS app end to end in the simulator, against the fake Google
# (Tests/E2E/fake_google_photos.py), with the app's debug E2E hooks:
#
#   scripts/ios-e2e.sh            (needs Xcode, python3 and ffmpeg)
#
# It creates a throwaway iPhone simulator (deleted at the end), adds six
# generated photos and a short video, grants Photos access, installs the
# Debug build and runs three scenarios, each asserted from the fake's
# GET /_state and its request log, and from the app's own files in the
# simulator container:
#
#   1. first run: every asset uploaded once, with the key the fake issued
#      recorded for it, an album holding them all, the run in events.json;
#      an Activity screenshot is kept in the work folder;
#   2. second launch: nothing new is uploaded;
#   background: one more photo, and a launch that hands the background-task
#      handler a stand-in task from App.init, before any scene (the cold
#      launch a BGProcessingTask makes; the simulator cannot submit a real
#      request): the handler's own run uploads the new photo and the task
#      completes when that run ends;
#   3. fresh app and fresh fake with --fail-batch --rate-limit-first 2:
#      everything still ends committed (single commits after the refused
#      batch, Google's holds waited out).
#
# Nothing reaches Google: the fake binds 127.0.0.1, and the account is a
# synthetic credential built by the app's own GoogleSignIn.credential.
set -euo pipefail
trap 'echo "ios-e2e: failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID=io.github.ayush5harma.PhotosBackup
EMAIL=e2e.account@example.com
ALBUM="E2E Album"
PHOTOS=6
WORK="${IOS_E2E_WORK:-$(mktemp -d)}"
# The third scenario waits out two of Google's holds (RateLimiter: 60 s,
# then 120 s) on top of the uploads.
RUN_TIMEOUT="${IOS_E2E_TIMEOUT:-600}"
mkdir -p "$WORK"
command -v ffmpeg >/dev/null || { echo "ios-e2e: ffmpeg is needed to make the test media" >&2; exit 2; }

UDID=""
SERVER_PID=""
# On a failure, keep what explains it before the simulator goes: the app's
# own records, its log, a screenshot, whether it is still running, and any
# crash report. CI keeps the work folder as an artifact.
diagnose() {
  local out="$WORK/diagnostics" data
  mkdir -p "$out"
  data="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)" || data=""
  if [ -n "$data" ]; then
    cp -R "$data/Library/Application Support/$BUNDLE_ID" "$out/support" 2>/dev/null || true
    cp "$data/Library/Preferences/$BUNDLE_ID.plist" "$out/" 2>/dev/null || true
  fi
  xcrun simctl io "$UDID" screenshot --type=png "$out/screen.png" >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -i "$BUNDLE_ID" > "$out/running.txt" || true
  xcrun simctl spawn "$UDID" log show --last 30m --style compact \
    --predicate "subsystem == \"$BUNDLE_ID\" OR process == \"PhotosBackup\"" > "$out/app.log" 2>&1 || true
  find "$HOME/Library/Logs/DiagnosticReports" -name 'PhotosBackup*' -mmin -60 -exec cp {} "$out/" \; 2>/dev/null || true
  say "diagnostics kept in $out"
}

cleanup() {
  local status=$?
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  if [ -n "$UDID" ] && [ "$status" -ne 0 ]; then diagnose; fi
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

say() { printf 'ios-e2e: %s\n' "$*" >&2; }

APP="$("$ROOT/scripts/build-ios.sh" --simulator)"

# A simulator of our own, on the newest iOS runtime with a regular iPhone.
read -r DEVICE_TYPE RUNTIME < <(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    tail = runtime.rsplit(".", 1)[-1]
    return [int(part) for part in tail.split("-")[1:] if part.isdigit()] if tail.startswith("iOS") else []
for runtime in sorted((r for r in devices if version(r)), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and "Duo" not in d["name"]]
    if phones:
        print(phones[0]["deviceTypeIdentifier"], runtime)
        break
')
UDID="$(xcrun simctl create "Photos Backup E2E" "$DEVICE_TYPE" "$RUNTIME")"
say "simulator $UDID ($RUNTIME), work folder $WORK"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Distinct pictures (each colour hashes differently) and one short video.
mkdir -p "$WORK/media"
colours=(red green blue orange purple teal)
for index in $(seq 0 $((PHOTOS - 1))); do
  ffmpeg -loglevel error -y -f lavfi -i "color=c=${colours[$index]}:s=640x480" -frames:v 1 "$WORK/media/photo-$index.jpg"
done
ffmpeg -loglevel error -y -f lavfi -i "testsrc=duration=1:size=320x240:rate=15" -pix_fmt yuv420p "$WORK/media/clip.mp4"
xcrun simctl addmedia "$UDID" "$WORK"/media/*
EXPECTED=$((PHOTOS + 1))

install_app() {
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID"
}

start_server() {
  local name="$1"; shift
  python3 -I "$ROOT/Tests/E2E/fake_google_photos.py" --port 0 --log "$WORK/$name.jsonl" "$@" > "$WORK/$name.out" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's/^listening on http:\/\/127\.0\.0\.1:\([0-9]*\)$/\1/p' "$WORK/$name.out")"
    [ -n "$PORT" ] && break
    sleep 0.1
  done
  [ -n "$PORT" ] || { say "the fake server did not start"; cat "$WORK/$name.out" >&2; exit 1; }
  say "fake Google ($name) on port $PORT"
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

launch() {
  SIMCTL_CHILD_PHOTOS_BACKUP_GOOGLE_ENDPOINT="http://127.0.0.1:$PORT" \
  SIMCTL_CHILD_PHOTOS_BACKUP_E2E_ACCOUNT="$EMAIL" \
  SIMCTL_CHILD_PHOTOS_BACKUP_E2E_ALBUM="$ALBUM" \
  SIMCTL_CHILD_PHOTOS_BACKUP_E2E_RUN=1 \
  SIMCTL_CHILD_PHOTOS_BACKUP_TAB=activity \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
}

# How many "E2E: Photos access" lines the app has written, and the last one.
access_lines() {
  python3 -I - "$(support_dir)/events.json" "$1" <<'PY' 2>/dev/null || echo 0
import json, sys
events = json.load(open(sys.argv[1]))
events = events["events"] if isinstance(events, dict) else events
lines = [e["message"] for e in events if e.get("message", "").startswith("E2E: Photos access")]
print(len(lines) if sys.argv[2] == "count" else (lines[-1] if lines else ""))
PY
}

# A launch whose hooks run only once the app can read Photos. A fresh
# simulator sometimes drops the first `simctl privacy` grant (iOS 26.2 on
# CI, 2026-11-26); the hook then reports the access it sees and waits for
# nothing, so grant again and relaunch, up to three times.
launch_with_photos() {
  local attempt before waited last
  for attempt in 1 2 3; do
    before="$(access_lines count)"
    launch
    waited=0
    while [ "$waited" -lt 60 ] && [ "$(access_lines count)" -le "$before" ]; do
      sleep 1; waited=$((waited + 1))
    done
    last="$(access_lines last)"
    [ "$last" = "E2E: Photos access authorized" ] && return 0
    say "attempt $attempt: ${last:-no access line after 60 s}; granting Photos again"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl privacy "$UDID" grant photos "$BUNDLE_ID"
    sleep 3
  done
  say "the app never got Photos access"
  exit 1
}

support_dir() {
  echo "$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Library/Application Support/$BUNDLE_ID"
}

# Waits until history.json holds `runs` finished runs.
wait_for_runs() {
  local runs="$1" waited=0
  while [ "$waited" -lt "$RUN_TIMEOUT" ]; do
    if python3 -I - "$(support_dir)/history.json" "$runs" <<'PY' 2>/dev/null; then
import json, sys
history = json.load(open(sys.argv[1]))
runs = history["runs"] if isinstance(history, dict) else history
sys.exit(0 if sum(1 for run in runs if run.get("finishedAt")) >= int(sys.argv[2]) else 1)
PY
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  say "no finished run $runs after ${RUN_TIMEOUT}s"
  exit 1
}

check() {
  curl -fsS "http://127.0.0.1:$PORT/_state" > "$WORK/state-$1.json"
  python3 -I "$ROOT/scripts/tests/ios_e2e_check.py" --scenario "$1" --at-least "$EXPECTED" --album "$ALBUM" \
    --server-state "$WORK/state-$1.json" --server-log "$WORK/$2.jsonl" --support "$(support_dir)"
}

# 1. The first run.
xcrun simctl keychain "$UDID" reset
install_app
start_server first
launch_with_photos
wait_for_runs 1
sleep 2
xcrun simctl io "$UDID" screenshot --type=png "$WORK/activity-after-first-run.png" >/dev/null 2>&1
check first first

# 2. Again: nothing new goes up.
launch_with_photos
wait_for_runs 2
check second first

# Background: a cold launch for the background task, with one new photo.
ffmpeg -loglevel error -y -f lavfi -i "color=c=yellow:s=640x480" -frames:v 1 "$WORK/media/late.jpg"
xcrun simctl addmedia "$UDID" "$WORK/media/late.jpg"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_PHOTOS_BACKUP_GOOGLE_ENDPOINT="http://127.0.0.1:$PORT" \
SIMCTL_CHILD_PHOTOS_BACKUP_E2E_BACKGROUND_TASK=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
wait_for_runs 3
sleep 2
check background first
stop_server

# 3. A fresh app and a fake that refuses batches and starts with two 429s.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID"
xcrun simctl keychain "$UDID" reset
install_app
start_server third --fail-batch --rate-limit-first 2
launch_with_photos
wait_for_runs 1
check third third
stop_server
say "all scenarios passed; Activity screenshot: $WORK/activity-after-first-run.png"
