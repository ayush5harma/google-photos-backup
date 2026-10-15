#!/usr/bin/env python3
"""Watch gpmc metadata only. No dependency installation or upstream code execution."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

STABLE = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:\.post(\d+))?\Z")
MARKER = re.compile(r"<!-- gpmc-upstream-version:([0-9.]+(?:post[0-9]+)?) -->")
PIN_PATTERNS = {
    "Bridge/requirements.txt": r"(?m)^gpmc==([^\s#]+)\s*$",
    "Android/app/build.gradle.kts": r'install\("gpmc==([^"\s]+)"\)',
    "Android/app/src/main/python/android_bridge.py": r'metadata\.version\("gpmc"\) != "([^"\s]+)"',
    "scripts/verify-windows.ps1": r"\.gpmc -ne '([^'\s]+)'",
}


def stable_version(value: str) -> tuple[int, int, int, int] | None:
    """gpmc uses three-part versions; ignore prerelease/dev/unknown tags."""
    match = STABLE.fullmatch(value) if isinstance(value, str) else None
    return tuple(int(part) for part in match.groups()[:3]) + (int(match[4]) if match[4] is not None else -1,) if match else None


def canonical_version(value: str) -> str:
    parsed = stable_version(value)
    if parsed is None:
        raise ValueError("Expected a stable three-part gpmc version")
    major, minor, patch, post = parsed
    return f"{major}.{minor}.{patch}" + (f".post{post}" if post >= 0 else "")


def read_pins(root: Path) -> dict[str, str]:
    pins = {}
    for relative, pattern in PIN_PATTERNS.items():
        matches = re.findall(pattern, (root / relative).read_text())
        if len(matches) != 1 or stable_version(matches[0]) is None:
            raise ValueError(f"Expected exactly one stable gpmc pin in {relative}")
        pins[relative] = canonical_version(matches[0])
    return pins


def discover_versions(pypi: dict, releases: list[dict]) -> dict[str, set[str]]:
    versions: dict[str, set[str]] = {}
    for version, files in pypi["releases"].items():
        if stable_version(version) is not None and any(not file.get("yanked", False) for file in files):
            versions.setdefault(canonical_version(version), set()).add("PyPI")
    for release in releases:
        tag = release.get("tag_name", "")
        if not release.get("draft") and not release.get("prerelease") and stable_version(tag) is not None:
            versions.setdefault(canonical_version(tag), set()).add("GitHub")
    return versions


def pending_versions(versions: dict[str, set[str]], pins: dict[str, str], issues: list[dict]) -> list[str]:
    floor = min(stable_version(value) for value in pins.values())
    acknowledged = {
        version
        for issue in issues
        if "pull_request" not in issue
        for version in MARKER.findall(issue.get("body") or "")
    }
    return sorted(
        (version for version in versions if stable_version(version) > floor and version not in acknowledged),
        key=stable_version,
    )


def issue_body(version: str, sources: set[str], pins: dict[str, str]) -> str:
    rows = "\n".join(f"| `{path}` | `{pin}` |" for path, pin in pins.items())
    observed = ", ".join(sorted(sources))
    return f"""<!-- gpmc-upstream-version:{version} -->
A new stable **gpmc {version}** version was observed in {observed}. At least one platform pin or compatibility check is older.

- [PyPI version](https://pypi.org/project/gpmc/{version}/)
- [Upstream releases](https://github.com/xob0t/gpmc/releases)

| Pin / compatibility check | Current version |
|---|---|
{rows}

Review the upstream changes and any Dependabot PR before updating. Desktop packaging shares `Bridge/requirements.txt`; Android embeds its own pip pin and has a version-specific signal compatibility guard. Keep the Windows verification expectation in sync too.

- [ ] Review upstream authentication, upload, storage attribution and protocol changes.
- [ ] Update all affected pins, compatibility code and verification expectations together.
- [ ] Run bridge tests, desktop packaging checks and Android tests/builds.
- [ ] Confirm real sign-in/upload behavior when relevant; metadata alone cannot verify it.

This watcher fetched metadata only and did not install or execute the new package. It does not update or merge dependencies automatically. Closing this issue acknowledges this version and prevents future duplicates, even if the update is deferred.
"""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a repository token through an unexpected redirect.
        return None


class MetadataClient:
    def __init__(self, token: str | None):
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, url: str, payload: dict | None = None) -> Any:
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc not in {"api.github.com", "pypi.org"}:
            raise ValueError("Only fixed GitHub/PyPI HTTPS metadata endpoints are permitted")
        if payload is not None and not url.startswith("https://api.github.com/repos/"):
            raise ValueError("Issue writes must use the GitHub API")
        headers = {"Accept": "application/json", "User-Agent": "photos-backup-gpmc-monitor"}
        if parsed.netloc == "api.github.com":
            headers["X-GitHub-Api-Version"] = "2022-11-28"
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
        data = json.dumps(payload).encode() if payload is not None else None
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers)
        with self.opener.open(request, timeout=30) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024:
                raise ValueError("Metadata response exceeded 4 MiB")
            return json.loads(raw)

    def pages(self, path: str) -> list[dict]:
        separator = "&" if "?" in path else "?"
        result = []
        for page in range(1, 101):
            items = self.request(f"https://api.github.com{path}{separator}per_page=100&page={page}")
            if not isinstance(items, list):
                raise ValueError("Expected a GitHub metadata list")
            result.extend(items)
            if len(items) < 100:
                return result
        raise ValueError("Metadata pagination exceeded 100 pages; refusing incomplete deduplication")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Inspect metadata without creating issues")
    args = parser.parse_args(argv)
    dry_run = args.dry_run or os.environ.get("DRY_RUN", "false").lower() == "true"
    repository = os.environ.get("GITHUB_REPOSITORY", "ayush5harma/google-photos-backup")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository name")
    token = os.environ.get("GITHUB_TOKEN")
    if not dry_run and not token:
        raise ValueError("GITHUB_TOKEN is required to create issues; use --dry-run to inspect metadata")
    pins = read_pins(Path(__file__).resolve().parents[1])
    client = MetadataClient(token)
    versions = discover_versions(
        client.request("https://pypi.org/pypi/gpmc/json"),
        client.pages("/repos/xob0t/gpmc/releases"),
    )
    issues = client.pages(f"/repos/{repository}/issues?state=all")
    pending = pending_versions(versions, pins, issues)
    print(f"Checked {len(versions)} stable upstream versions and {len(issues)} existing issues/PRs.")
    for version in pending:
        if dry_run:
            print(f"Would open issue: gpmc {version} is available ({', '.join(sorted(versions[version]))})")
        else:
            issue = client.request(
                f"https://api.github.com/repos/{repository}/issues",
                {"title": f"Review upstream gpmc {version}", "body": issue_body(version, versions[version], pins)},
            )
            print(f"Opened issue #{int(issue['number'])} for gpmc {version}.")
    if not pending:
        print("No unacknowledged stable gpmc updates above the current pins.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HTTPError as error:
        print(f"Metadata API failed with HTTP {error.code}; no response body or token logged.", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Update monitor failed: {error}", file=sys.stderr)
        sys.exit(1)
