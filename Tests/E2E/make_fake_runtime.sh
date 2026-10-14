#!/bin/bash
# Lays out a bridge runtime that uses the fake gpmc instead of the real one:
#   <dir>/gpmc_bridge.py             a copy of Bridge/gpmc_bridge.py
#   <dir>/site-packages/gpmc         a copy of Tests/E2E/fake_gpmc (copied, not
#                                    linked, so its ledger never lands in the repo)
#   <dir>/fake_gpmc_scenario.json    written by the caller (optional)
# A debug build of the app then runs against it with
#   PHOTOS_BACKUP_PYTHON=$(command -v python3) PHOTOS_BACKUP_BRIDGE=<dir>/gpmc_bridge.py
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <runtime-dir>" >&2
    exit 64
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
runtime=$1
mkdir -p "$runtime"
cp "$repo/Bridge/gpmc_bridge.py" "$runtime/gpmc_bridge.py"
rm -rf "$runtime/site-packages"
cp -R "$repo/Tests/E2E/fake_gpmc" "$runtime/site-packages"
find "$runtime/site-packages" -name __pycache__ -prune -exec rm -rf {} +
echo "$runtime/gpmc_bridge.py"
