#!/usr/bin/env python3
"""Line protocol between Photos Backup.app and gpmc (github.com/xob0t/gpmc).

The app writes ONE JSON request to stdin and reads newline-delimited JSON
events from stdout. Everything else -- gpmc's logging, tracebacks -- goes to
stderr, which the app keeps as its log.

auth_data travels inside the request, never in argv or the environment: a
process's argv and environment are readable by every other process of the same
user (`ps -E`), its stdin is not. auth_data carries a long-lived Google master
token, so that matters.

Requests (every field not marked optional is required):

  {"command": "version"}
  {"command": "check-auth", "auth_data": "..."}
  {"command": "upload", "auth_data": "...",
   "items": [{"id": "<PHAsset id>", "path": "/abs/file", "filename": "IMG_1.HEIC"}],
   "quality": "original" | "saver" | "quota",     optional, default original
   "threads": 1,                                  optional
   "force": false,                                optional, skip gpmc's hash check
   "timeout": 60,                                 optional, seconds per request
   "album": {"id": "..."} | {"name": "..."}}      optional
  {"command": "add-to-album", "auth_data": "...", "media_keys": [...], "album": {...}}

Events all carry "type" and "v" (PROTOCOL_VERSION): version, auth, progress,
item, item_failed, album, album_failed, done, fatal. A fatal event is always
the last line and the exit status names its kind (EXIT_*).
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import platform
import re
import sys
import threading
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any, TextIO

PROTOCOL_VERSION = 1

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_AUTH = 2
EXIT_NETWORK = 3
EXIT_REQUEST = 4

DEFAULT_TIMEOUT = 60
MAX_THREADS = 8

# quality -> (saver, use_quota), the two gpmc flags that pick the device model
# gpmc reports at commit: Pixel XL (original, free), Pixel 2 (storage saver),
# Pixel 8 (original, counted against the account's storage).
QUALITIES = {"original": (False, False), "saver": (True, False), "quota": (False, True)}

Event = dict[str, Any]
Emit = Callable[[Event], None]
ClientFactory = Callable[[str, int], Any]

# gpmc 0.9.0 reports a failed file only as a progress event with phase
# "error"; the reason is in the line it logs from Client._upload_file.
_FAILURE_LINE = re.compile(r"^Error uploading file (?P<path>.+?): (?P<reason>.*)$", re.DOTALL)


class RequestError(ValueError):
    """The request itself is malformed; retrying it unchanged cannot work."""


class FailureLog(logging.Handler):
    """Collects the per-file failure reasons gpmc logs, keyed by path."""

    def __init__(self) -> None:
        super().__init__(level=logging.ERROR)
        self.reasons: dict[str, str] = {}
        self._lock = threading.Lock()

    def emit(self, record: logging.LogRecord) -> None:
        match = _FAILURE_LINE.match(record.getMessage())
        if match:
            with self._lock:
                self.reasons[match["path"]] = match["reason"]


def _vendored_site_packages() -> None:
    """The app bundle ships gpmc and its dependencies beside this file."""
    vendored = Path(__file__).resolve().parent / "site-packages"
    if vendored.is_dir() and str(vendored) not in sys.path:
        sys.path.insert(0, str(vendored))


def default_client_factory(auth_data: str, timeout: int) -> Any:
    _vendored_site_packages()
    from gpmc import Client

    return Client(auth_data=auth_data, timeout=timeout)


def _gpmc_version() -> str | None:
    _vendored_site_packages()
    try:
        from importlib.metadata import version

        return version("gpmc")
    except Exception:
        return None


def _event(event_type: str, /, **fields: Any) -> Event:
    return {"type": event_type, "v": PROTOCOL_VERSION, **fields}


def _is_network_error(error: BaseException) -> bool:
    # requests.ConnectionError and requests.Timeout, matched by name so the
    # bridge does not import requests before it is needed; the builtin
    # ConnectionError (an OSError) matches too.
    return any(cls.__name__ in ("ConnectionError", "Timeout", "ConnectTimeout", "ReadTimeout") for cls in type(error).__mro__)


def _email(auth_data: str) -> str | None:
    for pair in auth_data.split("&"):
        key, _, value = pair.partition("=")
        if key == "Email":
            return value.replace("%40", "@")
    return None


def _require(request: Event, key: str, kind: type) -> Any:
    value = request.get(key)
    if not isinstance(value, kind) or (kind in (str, list) and not value):
        raise RequestError(f"`{key}` must be a non-empty {kind.__name__}")
    return value


def _album(request: Event, required: bool) -> Event | None:
    album = request.get("album")
    if album is None and not required:
        return None
    if not isinstance(album, dict) or not (album.get("id") or album.get("name")):
        raise RequestError("`album` must carry an `id` or a `name`")
    return album


def _items(request: Event) -> list[Event]:
    items = _require(request, "items", list)
    for item in items:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k] for k in ("id", "path", "filename")):
            raise RequestError("every item needs string `id`, `path` and `filename`")
    return items


def _connect(request: Event, factory: ClientFactory) -> Any:
    """Build the client and fetch a bearer token, so auth fails before any upload."""
    auth_data = _require(request, "auth_data", str).strip()
    timeout = request.get("timeout", DEFAULT_TIMEOUT)
    if not isinstance(timeout, int) or timeout <= 0:
        raise RequestError("`timeout` must be a positive integer")
    client = factory(auth_data, timeout)
    _ = client.api.bearer_token
    return client


def _add_to_album(client: Any, media_keys: list[str], album: Event) -> str:
    if album.get("id"):
        return client.add_to_existing_album(media_keys, album["id"], show_progress=False)
    # add_to_album splits past 20,000 items into "<name> 1", "<name> 2"...;
    # the first is the one the app remembers and appends to next time.
    return client.add_to_album(media_keys, album["name"], False)[0]


def _upload(request: Event, client: Any, emit: Emit, failures: FailureLog) -> int:
    items = _items(request)
    quality = request.get("quality", "original")
    if quality not in QUALITIES:
        raise RequestError(f"`quality` must be one of {sorted(QUALITIES)}")
    saver, use_quota = QUALITIES[quality]
    threads = request.get("threads", 1)
    if not isinstance(threads, int) or not 1 <= threads <= MAX_THREADS:
        raise RequestError(f"`threads` must be 1-{MAX_THREADS}")
    album = _album(request, required=False)

    by_path = {Path(item["path"]).absolute().as_posix(): item["id"] for item in items}
    skipped: set[str] = set()
    errored: set[str] = set()
    lock = threading.Lock()

    def on_progress(event: Event) -> None:
        path = event.get("path", "")
        phase = event.get("phase")
        with lock:
            if phase == "skipped":
                skipped.add(path)
            elif phase == "error":
                errored.add(path)
        emit(_event("progress", id=by_path.get(path), phase=phase, bytes_completed=event.get("bytes_completed", 0), bytes_total=event.get("bytes_total", 0)))

    target = {Path(item["path"]): {"hash": None, "filename": item["filename"]} for item in items}
    results: dict[str, str] = client.upload(
        target=target,
        use_quota=use_quota,
        saver=saver,
        threads=threads,
        force_upload=bool(request.get("force", False)),
        progress_callback=on_progress,
    )

    counts = {"uploaded": 0, "existing": 0, "failed": 0}
    for path, asset_id in by_path.items():
        media_key = results.get(path)
        if media_key:
            status = "existing" if path in skipped else "uploaded"
            counts[status] += 1
            emit(_event("item", id=asset_id, media_key=media_key, status=status))
        else:
            counts["failed"] += 1
            emit(_event("item_failed", id=asset_id, message=failures.reasons.get(path, "gpmc returned no media key")))

    if album and results:
        try:
            album_id = _add_to_album(client, list(results.values()), album)
            emit(_event("album", album_id=album_id, added=len(results)))
        except Exception as error:
            logging.getLogger(__name__).exception("adding to album failed")
            emit(_event("album_failed", message=str(error)))

    emit(_event("done", **counts))
    return EXIT_OK


def run(request: Any, emit: Emit, client_factory: ClientFactory = default_client_factory) -> int:
    """Answer one request through emit(); returns the process exit status."""
    failures = FailureLog()
    logging.getLogger().addHandler(failures)
    try:
        if not isinstance(request, dict):
            raise RequestError("the request must be a JSON object")
        command = request.get("command")
        if command == "version":
            emit(_event("version", protocol=PROTOCOL_VERSION, gpmc=_gpmc_version(), python=platform.python_version()))
            return EXIT_OK
        if command not in ("check-auth", "upload", "add-to-album"):
            raise RequestError(f"unknown command {command!r}")

        # Validate everything that needs no network before authenticating.
        if command == "upload":
            _items(request)
        elif command == "add-to-album":
            if not all(isinstance(key, str) and key for key in _require(request, "media_keys", list)):
                raise RequestError("`media_keys` must be non-empty strings")
            _album(request, required=True)

        try:
            client = _connect(request, client_factory)
        except RequestError:
            raise
        except Exception as error:
            kind, code = ("network", EXIT_NETWORK) if _is_network_error(error) else ("auth", EXIT_AUTH)
            logging.getLogger(__name__).exception("authentication failed")
            emit(_event("fatal", kind=kind, message=str(error)))
            return code

        if command == "check-auth":
            emit(_event("auth", email=_email(request["auth_data"])))
            return EXIT_OK
        if command == "add-to-album":
            album_id = _add_to_album(client, request["media_keys"], request["album"])
            emit(_event("album", album_id=album_id, added=len(request["media_keys"])))
            return EXIT_OK
        return _upload(request, client, emit, failures)
    except RequestError as error:
        emit(_event("fatal", kind="request", message=str(error)))
        return EXIT_REQUEST
    except Exception as error:
        logging.getLogger(__name__).exception("bridge failed")
        kind, code = ("network", EXIT_NETWORK) if _is_network_error(error) else ("internal", EXIT_INTERNAL)
        emit(_event("fatal", kind=kind, message=str(error)))
        return code
    finally:
        logging.getLogger().removeHandler(failures)


@contextlib.contextmanager
def protocol_stdout() -> Iterator[TextIO]:
    """Yield the real stdout and point fd 1 (and sys.stdout) at stderr meanwhile.

    gpmc logs through rich, whose console writes to sys.stdout, and a C
    extension may write to fd 1 directly; either would corrupt the protocol.
    """
    sys.stdout.flush()
    saved = os.dup(1)
    os.dup2(2, 1)
    real = os.fdopen(saved, "w", buffering=1, encoding="utf-8")
    previous = sys.stdout
    sys.stdout = sys.stderr
    try:
        yield real
    finally:
        sys.stdout = previous
        real.flush()
        os.dup2(saved, 1)
        real.close()


def main() -> int:
    # Configure the root logger before gpmc does: its basicConfig() is then a
    # no-op, so its records reach stderr as plain lines instead of rich markup.
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    with protocol_stdout() as out:
        lock = threading.Lock()

        def emit(event: Event) -> None:
            line = json.dumps(event, separators=(",", ":"))
            with lock:
                out.write(line + "\n")
                out.flush()

        try:
            request = json.loads(sys.stdin.read())
        except ValueError as error:
            emit(_event("fatal", kind="request", message=f"stdin is not JSON: {error}"))
            return EXIT_REQUEST
        return run(request, emit)


if __name__ == "__main__":
    sys.exit(main())
