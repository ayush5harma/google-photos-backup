#!/bin/bash
# Several Google accounts through the real app model, engine and bridge,
# against the fake gpmc (Tests/E2E/fake_gpmc), with no Photos library and no
# running app: MultiAccountRunTests, which `swift test` alone skips.
#
#   scripts/verify-accounts.sh
#
# Everything the test writes is in a scratch directory: PHOTOS_BACKUP_SANDBOX
# moves the support directory, the settings suite and the keychain service,
# all named after the xctest tool rather than the app, so the app's own
# history, settings and Google credential are never read or written. The
# scratch directory, its keychain items and its settings suite are removed
# at the end.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/photos-backup-accounts.XXXXXX")
cleanup() {
    rm -rf "$scratch"
    # Each per-account item of the scratch service, then the settings suite.
    for _ in $(seq 1 20); do
        security delete-generic-password -s "com.apple.dt.xctest.tool.auth-data.sandbox" >/dev/null 2>&1 || break
    done
    defaults delete com.apple.dt.xctest.tool.sandbox >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$repo/Tests/E2E/make_fake_runtime.sh" "$scratch/runtime" >/dev/null
mkdir -p "$scratch/sandbox"
cd "$repo"
PHOTOS_BACKUP_SANDBOX="$scratch/sandbox" \
PHOTOS_BACKUP_PYTHON="$(command -v python3)" \
PHOTOS_BACKUP_BRIDGE="$scratch/runtime/gpmc_bridge.py" \
    swift test --filter MultiAccountRunTests "$@"
