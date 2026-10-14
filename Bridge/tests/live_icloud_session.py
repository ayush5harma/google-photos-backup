#!/usr/bin/env python3
"""Opt-in, read-only session and one-original download check; emits no identifiers."""
import contextlib
import logging
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import icloud_bridge


def main() -> int:
    config = Path.home() / ".config/avd-photos/config"
    if not config.is_file():
        print("iCloud account setting unavailable")
        return 2
    match = re.search(r"^ICLOUD_USERNAME=(?:['\"])?([^\n'\"]+)", config.read_text(), re.MULTILINE)
    if not match:
        print("iCloud account setting unavailable")
        return 2
    account = match.group(1).strip()
    cookie_source = Path.home() / ".pyicloud"
    stem = "".join(c for c in account if re.match(r"\w", c))
    logging.disable(logging.CRITICAL)
    with tempfile.TemporaryDirectory(prefix="icloud-session-check-") as directory:
        private = Path(directory)
        private.chmod(0o700)
        copied = 0
        for suffix in (".session", ""):
            source = cookie_source / (stem + suffix)
            if source.is_file():
                destination = private / source.name
                shutil.copyfile(source, destination)
                destination.chmod(0o600)
                copied += 1
        if not copied:
            print("iCloud session unavailable")
            return 2
        try:
            # 2026-10-15: HTTP failures may embed account URLs; only fixed outcomes leave this harness.
            with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                service = icloud_bridge.make_service(account, None, private)
                status = icloud_bridge.auth_status(service)
                downloaded = False
                if status == "signed_in":
                    for index, asset in enumerate(service.photos.all):
                        if index >= 10:
                            break
                        _, version, _ = icloud_bridge._components(asset)[0]
                        if not 0 < version.size <= 100 * 1024 * 1024:
                            continue
                        destination = private / "sample-original"
                        icloud_bridge._download(asset, service.session, version, destination, 100 * 1024 * 1024)
                        downloaded = destination.stat().st_size == version.size
                        destination.unlink()
                        break
            print("iCloud session:", status)
            print("Read-only original download:", "passed; temporary copy removed" if downloaded else "not verified")
            return 0 if status == "signed_in" and downloaded else 2
        except Exception as error:
            allowed = {"PyiCloudFailedLoginException", "PyiCloud2FARequiredException", "PyiCloudAPIResponseException"}
            kind = type(error).__name__ if type(error).__name__ in allowed else "provider or network failure"
            print("iCloud session check could not complete:", kind)
            return 2


if __name__ == "__main__":
    sys.exit(main())
