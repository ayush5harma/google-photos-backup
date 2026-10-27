"""A stand-in for gpmc 0.9.0 with exactly the surface Bridge/gpmc_bridge.py uses.

It never touches the network. What it does is decided by a JSON scenario, and
what Google "holds" lives in a ledger file, so a sequence of bridge processes
(one per batch, as the app runs them) sees one consistent account.

Where the scenario comes from: the file named by $FAKE_GPMC_SCENARIO, else
`fake_gpmc_scenario.json` in the folder that holds the `site-packages` this
package was imported from (the app passes the bridge no environment of its
own, so a run of the app finds the scenario this way). No file means the
defaults: everything succeeds.

Scenario keys (all optional):
  "ledger": "/abs/ledger.json"   where uploads are kept; default beside the scenario
  "auth": "ok" | "refuse" | "network" | "rate_limit" | "no_token"
  "auth_rate_limit_first": N     the first N sign-ins (across processes) answer 429
  "rate_limit_first": N          the first N file uploads answer 429
  "fail": {"IMG_3.JPG": "413 Client Error: Request Entity Too Large for url: ..."}
                                 these file names always fail with that text
  "flaky": {"IMG_4.JPG": {"times": 2, "error": "503" | "reset" | "timeout"}}
                                 these fail the first N attempts, then upload
  "fail_first": N                the first N new files fail with "fail_message"
                                 (default a 400), whatever their names
  "flaky_first": {"times": N, "error": "503"}   the first N new files fail
                                 retryably, whatever their names
  "album_error": "500 Server Error: ..."   album calls raise this
  "dead_media_keys": ["<key>"]   an album call carrying any of these keys
                                 answers 404, as Google does for a key it
                                 no longer has
  "delay": 0.2                   seconds each file takes (to test Stop)

Ledger (JSON, written under an exclusive file lock):
  {"media": {"<sha1 hex>": "<media key>"},
   "counters": {"uploads": n, "auth": n, "<file name>": attempts},
   "uploads": [{"filename", "sha1", "status": "uploaded" | "existing" | "failed", "message"?}],
   "albums": {"<album id>": {"name", "media_keys": [...]}}}
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import logging
import os
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

SCENARIO_ENV = "FAKE_GPMC_SCENARIO"
UPLOAD_URL = "https://photos.googleapis.com/data/upload/uploadmedia/interactive"
COMMIT_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752"
ALBUM_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/484917746253879292"

_logger = logging.getLogger("gpmc")
_lock = threading.Lock()


class HTTPError(Exception):
    """Worded and shaped like requests.HTTPError: the status is on .response."""

    def __init__(self, status: int, reason: str, url: str) -> None:
        kind = "Client" if status < 500 else "Server"
        super().__init__(f"{status} {kind} Error: {reason} for url: {url}")
        self.response = type("Response", (), {"status_code": status})()


class ConnectionError(OSError):  # noqa: A001 - named like requests' so the bridge sees a network error
    pass


class Timeout(OSError):
    pass


def _scenario_path() -> Path:
    if os.environ.get(SCENARIO_ENV):
        return Path(os.environ[SCENARIO_ENV])
    # <runtime>/site-packages/gpmc/__init__.py -> <runtime>/fake_gpmc_scenario.json
    return Path(__file__).absolute().parents[2] / "fake_gpmc_scenario.json"


def _scenario() -> dict[str, Any]:
    path = _scenario_path()
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {}


def _ledger_path(scenario: dict[str, Any]) -> Path:
    return Path(scenario.get("ledger") or _scenario_path().with_name("fake_gpmc_ledger.json"))


@contextlib.contextmanager
def _process_lock(path: Path) -> Iterator[None]:
    # 2026-10-15: A separate byte lock survives ledger truncation on Windows.
    with open(str(path) + ".lock", "a+b") as handle:
        if os.name == "nt":
            import msvcrt
            handle.write(b"0")
            handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
            try:
                yield
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield


@contextlib.contextmanager
def _ledger(scenario: dict[str, Any]) -> Iterator[dict[str, Any]]:
    """The ledger, locked against other threads and other bridge processes."""
    path = _ledger_path(scenario)
    path.parent.mkdir(parents=True, exist_ok=True)
    with _lock, _process_lock(path), open(path, "a+", encoding="utf-8") as handle:
        handle.seek(0)
        text = handle.read()
        data = json.loads(text) if text.strip() else {}
        for key in ("media", "counters", "albums"):
            data.setdefault(key, {})
        data.setdefault("uploads", [])
        try:
            yield data
        finally:
            # Also when the body raised: a refused attempt still counts.
            handle.seek(0)
            handle.truncate()
            json.dump(data, handle, indent=1, sort_keys=True)
            handle.flush()


def _count(data: dict[str, Any], key: str) -> int:
    """Increments a counter and returns its new value."""
    data["counters"][key] = data["counters"].get(key, 0) + 1
    return data["counters"][key]


def _error(kind: str, url: str) -> Exception:
    if kind == "reset":
        return ConnectionError("('Connection aborted.', ConnectionResetError(54, 'Connection reset by peer'))")
    if kind == "timeout":
        return Timeout("HTTPSConnectionPool(host='photos.googleapis.com', port=443): Read timed out. (read timeout=60)")
    status = int(kind)
    reasons = {403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"}
    return HTTPError(status, reasons.get(status, "Error"), url)


class Api:
    def __init__(self, auth_data: str) -> None:
        self.auth_data = auth_data

    @property
    def bearer_token(self) -> str:
        scenario = _scenario()
        auth = scenario.get("auth", "ok")
        with _ledger(scenario) as data:
            attempt = _count(data, "auth")
        if attempt <= scenario.get("auth_rate_limit_first", 0) or auth == "rate_limit":
            raise _error("429", "https://android.googleapis.com/auth")
        if auth == "refuse":
            raise _error("403", "https://android.googleapis.com/auth")
        if auth == "network":
            raise ConnectionError("HTTPSConnectionPool(host='android.googleapis.com', port=443): Max retries exceeded")
        if auth == "no_token":
            raise RuntimeError("Auth response does not contain bearer token")
        return "fake-bearer"

    def add_media_to_album(self, album_media_key: str, media_keys: list[str]) -> dict:
        # gpmc 0.9.0 appends to an existing album here, not on Client.
        _album(media_keys, album_id=album_media_key)
        return {}

    def create_album(self, album_name: str, media_keys: list[str]) -> str:
        return _album(media_keys, name=album_name)

    def find_remote_media_by_hash(self, sha1_hash: bytes) -> str | None:
        with _ledger(_scenario()) as data:
            return data["media"].get(sha1_hash.hex())


class Client:
    def __init__(self, auth_data: str = "", proxy: str = "", language: str = "", timeout: int = 60, log_level: str = "INFO") -> None:
        if "Token=" not in auth_data:
            raise ValueError("auth_data has no Token field")
        self.timeout = timeout
        self.language = language
        self.api = Api(auth_data)

    def upload(
        self,
        target: dict[Path, dict[str, Any]],
        album_name: str | None = None,
        use_quota: bool = False,
        saver: bool = False,
        threads: int = 1,
        force_upload: bool = False,
        progress_callback: Callable[[dict[str, Any]], None] | None = None,
        **_ignored: Any,
    ) -> dict[str, str]:
        results: dict[str, str] = {}
        for path, options in target.items():
            path = Path(path)
            filename = options.get("filename") or path.name
            try:
                results.update(self._upload_file(path, filename, force_upload, progress_callback))
            except Exception as error:
                # gpmc 0.9.0 reports a failed file only like this: a progress
                # event with phase "error" and one logged line.
                if progress_callback:
                    progress_callback(self._event("error", path, filename, 0))
                _logger.error(f"Error uploading file {path}: {error}")
                with _ledger(_scenario()) as data:
                    data["uploads"].append({"filename": filename, "status": "failed", "message": str(error)})
        return results

    def _upload_file(self, path: Path, filename: str, force: bool, progress: Callable[[dict[str, Any]], None] | None) -> dict[str, str]:
        scenario = _scenario()
        report = (lambda phase, done: progress(self._event(phase, path, filename, done))) if progress else (lambda *_: None)
        content = path.read_bytes()
        report("hashing", len(content))
        sha1 = hashlib.sha1(content).hexdigest()
        if scenario.get("delay"):
            time.sleep(float(scenario["delay"]))

        with _ledger(scenario) as data:
            if not force:
                report("checking", 0)
                if sha1 in data["media"]:
                    data["uploads"].append({"filename": filename, "sha1": sha1, "status": "existing"})
                    report("skipped", len(content))
                    return {path.absolute().as_posix(): data["media"][sha1]}
            if _count(data, "uploads") <= scenario.get("rate_limit_first", 0):
                raise _error("429", UPLOAD_URL)
            if filename in scenario.get("fail", {}):
                raise RuntimeError(scenario["fail"][filename])
            flaky = scenario.get("flaky", {}).get(filename)
            if flaky and _count(data, filename) <= flaky.get("times", 1):
                raise _error(str(flaky.get("error", "503")), COMMIT_URL)
            # By position rather than name, for runs over a real library whose
            # file names the harness never sees.
            if _count(data, "fail_first") <= scenario.get("fail_first", 0):
                raise RuntimeError(scenario.get("fail_message", "400 Client Error: Bad Request for url: " + COMMIT_URL))
            flaky_first = scenario.get("flaky_first", {})
            if _count(data, "flaky_first") <= flaky_first.get("times", 0):
                raise _error(str(flaky_first.get("error", "503")), COMMIT_URL)

        report("uploading", len(content) // 2)
        report("finalizing", len(content))
        media_key = f"fake-{sha1[:24]}"
        with _ledger(scenario) as data:
            data["media"][sha1] = media_key
            data["uploads"].append({"filename": filename, "sha1": sha1, "status": "uploaded"})
        report("complete", len(content))
        return {path.absolute().as_posix(): media_key}

    @staticmethod
    def _event(phase: str, path: Path, filename: str, done: int) -> dict[str, Any]:
        total = path.stat().st_size if path.exists() else 0
        return {"version": 1, "type": "progress", "operation": "upload", "phase": phase, "path": path.absolute().as_posix(),
                "filename": filename, "bytes_completed": done, "bytes_total": total}

    def add_to_album(self, media_keys: list[str], album_name: str, show_progress: bool) -> list[str]:
        return [_album(media_keys, name=album_name)]


def _album(media_keys: list[str], name: str | None = None, album_id: str | None = None) -> str:
    scenario = _scenario()
    if scenario.get("album_error"):
        raise RuntimeError(scenario["album_error"])
    if set(media_keys) & set(scenario.get("dead_media_keys", [])):
        raise _error("404", ALBUM_URL)
    with _ledger(scenario) as data:
        if album_id is None:
            album_id = f"fake-album-{len(data['albums']) + 1}"
            data["albums"][album_id] = {"name": name, "media_keys": []}
        album = data["albums"].setdefault(album_id, {"name": name, "media_keys": []})
        album["media_keys"] += [key for key in media_keys if key not in album["media_keys"]]
    return album_id
