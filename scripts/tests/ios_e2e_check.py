#!/usr/bin/env python3
"""Assertions for scripts/ios-e2e.sh, one scenario at a time.

Reads the fake Google's GET /_state answer and request log, and the app's
own files (accounts.json, the account's state file, history.json,
events.json) from its simulator container. Prints one line per check and
exits non-zero on the first failure. It names no file, address or key in
its output beyond counts and the album title the script chose.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

UPLOAD_PATH = "/data/upload/uploadmedia/interactive"


def load(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def check(condition: bool, text: str) -> None:
    print(f"  {'ok  ' if condition else 'FAIL'} {text}")
    if not condition:
        sys.exit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True, choices=["first", "second", "third"])
    # The simulator's library comes with sample photos of its own (six on
    # iOS 27.0, 2026-11-26), so the script knows only the ones it added.
    parser.add_argument("--at-least", type=int, required=True, help="assets the script added to the simulator library")
    parser.add_argument("--album", required=True)
    parser.add_argument("--server-state", type=Path, required=True)
    parser.add_argument("--server-log", type=Path, required=True)
    parser.add_argument("--support", type=Path, required=True, help="the app's Application Support folder")
    args = parser.parse_args()

    server = load(args.server_state)
    library: dict[str, str] = server["library"]
    albums: dict[str, dict] = server["albums"]
    log = [json.loads(line) for line in args.server_log.read_text(encoding="utf-8").splitlines() if line.strip()]
    puts = [entry for entry in log if entry.get("method") == "PUT" and entry.get("status") == 200]

    index = load(args.support / "accounts.json")
    accounts = [account for account in index["accounts"] if not account.get("removed")]
    history = load(args.support / "history.json")
    runs = history["runs"] if isinstance(history, dict) else history
    events = load(args.support / "events.json")
    events = events["events"] if isinstance(events, dict) else events

    print(f"scenario {args.scenario}:")
    check(len(accounts) == 1, f"one account signed in ({len(accounts)})")
    state = load(args.support / accounts[0]["stateFile"])
    uploaded: dict[str, dict] = state.get("uploaded", {})
    keys = {record["mediaKey"] for record in uploaded.values()}

    expected = len(uploaded)
    check(expected >= args.at_least, f"the app recorded at least the {args.at_least} added items ({expected})")
    check(len(library) == expected, f"the fake holds as many items as the app recorded ({len(library)})")
    check(keys == set(library.values()), "every recorded key is one the fake issued, and every issued key is recorded")
    check(len(keys) == len(uploaded), "no two assets share a key")

    named = [album for album in albums.values() if album["name"] == args.album]
    check(len(named) == 1, f"one Google album named {args.album!r} ({len(named)})")
    check(set(named[0]["media_keys"]) == keys, f"the album holds all {len(keys)} items ({len(set(named[0]['media_keys']))})")
    mirrored = [mirror for mirror in state.get("mirrors", {}).values() if mirror.get("googleAlbumID") in albums]
    check(len(mirrored) == 1 and len(mirrored[0].get("addedAssetIDs", [])) == expected,
          "the app's record links the album with every asset added")

    finished = [run for run in runs if run.get("finishedAt")]
    latest = finished[0]  # RunHistory keeps the newest first.
    check("completed" in (latest.get("outcome") or {}), f"the latest run completed ({latest.get('outcome')})")
    check(any("Photos run finished" in event["message"] for event in events), "events.json has the finished run")

    if args.scenario in ("first", "third"):
        check(len(puts) == expected, f"each asset's bytes went up once ({len(puts)} uploads)")
        check(latest.get("uploaded") == expected, f"the run counted {expected} uploads ({latest.get('uploaded')})")
    if args.scenario == "second":
        check(len(finished) == 2, f"two runs in the history ({len(finished)})")
        check(len(puts) == expected, f"no bytes went up again ({len(puts)} uploads in all)")
        check(latest.get("uploaded", 0) == 0, f"the second run uploaded nothing ({latest.get('uploaded', 0)})")
    if args.scenario == "third":
        statuses = [entry.get("status") for entry in log]
        check(statuses.count(429) >= 2, f"the fake answered 429 at least twice ({statuses.count(429)})")
        # The fake logs each decoded commit under "body": "batch" and each
        # item's "key". --fail-batch answers every batch without keys, so
        # each item must have been committed alone (commitOne) with a key.
        commits = [entry["body"] for entry in log if isinstance(entry.get("body"), dict) and "items" in entry["body"]]
        refused = [body for body in commits if body.get("batch") and not any(item["key"] for item in body["items"])]
        alone = [body for body in commits if not body.get("batch") and body["items"][0]["key"]]
        check(len(refused) >= 1, f"the fake refused batched commits ({len(refused)})")
        check(len(alone) == expected, f"each item was then committed alone with a key ({len(alone)})")
        held = [event for event in events if "uploads wait" in event["message"] or "slow down" in event["message"]]
        check(len(held) >= 1, "the timeline shows Google's hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
