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
item, item_failed, album, album_failed, done, stopped, fatal. Each item is
reported as soon as Google confirms it. A fatal or stopped event is always the
last line and the exit status names its kind (EXIT_*).

  item_failed {"id", "message", "retryable"}   retryable: sending the same
      file again may work (network trouble, HTTP 408/429/5xx); added within
      protocol 1, so readers must not require it.
  fatal {"kind", "message"}   kind: auth | network | rate_limit | request |
      internal. rate_limit is Google's HTTP 429. ("storage_full" is reserved:
      gpmc 0.9.0 drops the response body that tells a full account apart from
      any other refusal, so this bridge cannot report it.)

SIGTERM stops the run: files still uploading are abandoned (the next run finds
any Google did commit through gpmc's hash check), except that an album call in
progress is allowed to finish and report first.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import logging
import os
import platform
import re
import signal
import sys
import threading
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, TextIO
from urllib.parse import parse_qsl, urljoin, urlsplit

PROTOCOL_VERSION = 1

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_AUTH = 2
EXIT_NETWORK = 3
EXIT_REQUEST = 4
EXIT_STOPPED = 5
EXIT_RATE_LIMIT = 6

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


class StopRequested(BaseException):
    """Raised in the main thread when the app asks the bridge to stop.

    A BaseException, like KeyboardInterrupt, so that the `except Exception`
    around authentication and gpmc calls cannot mistake it for a failure.
    """


class StopSignal:
    """What SIGTERM does: stop now, unless inside a critical section, in
    which case stop as soon as it ends."""

    def __init__(self) -> None:
        self.requested = False
        self._critical = 0

    def request(self) -> None:
        # Only the first signal acts: a second one landing while the first is
        # being handled would escape that handler and skip the fast exit.
        if self.requested:
            return
        self.requested = True
        if not self._critical:
            raise StopRequested

    @contextlib.contextmanager
    def critical(self) -> Iterator[None]:
        self._critical += 1
        try:
            yield
        finally:
            self._critical -= 1
        if self.requested and not self._critical:
            raise StopRequested


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
                # 2026-10-15: gpmc logs native Windows separators but returns POSIX result keys.
                self.reasons[Path(match["path"]).absolute().as_posix()] = match["reason"]


def _vendored_site_packages() -> None:
    """The app bundle ships gpmc and its dependencies beside this file."""
    vendored = Path(__file__).resolve().parent / "site-packages"
    if vendored.is_dir() and str(vendored) not in sys.path:
        sys.path.insert(0, str(vendored))


def default_client_factory(auth_data: str, timeout: int) -> Any:
    _vendored_site_packages()
    from gpmc import Client

    # Given explicitly: left to itself gpmc takes the first auth_data field
    # whose text contains "lang", which an address like langdon@... wins.
    language = dict(parse_qsl(auth_data)).get("lang", "")
    return Client(auth_data=auth_data, timeout=timeout, language=language)


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


# Google said no to the credential itself; anything else (an overloaded or
# rate-limited Google, a bug) is not proof the credential is bad, and the app
# keeps a credential unless it is: a fresh sign-in works only once.
_REFUSED_STATUSES = {401, 403}


def _is_transient_status(status: int | None) -> bool:
    """408 and any 5xx: Google or the path to it had trouble, and the same
    request may work later (the per-file rule in _is_retryable_failure and
    the app's FailureClassifier say the same). 429 is classified first."""
    return status is not None and (status == 408 or 500 <= status <= 599)


def _http_status(error: BaseException) -> int | None:
    return getattr(getattr(error, "response", None), "status_code", None)


def _classify(error: BaseException, during_auth: bool = False) -> tuple[str, int]:
    status = _http_status(error)
    if status == 429:
        return "rate_limit", EXIT_RATE_LIMIT
    if _is_network_error(error) or type(error).__name__ == "RetryError" or _is_transient_status(status):
        return "network", EXIT_NETWORK
    if status in _REFUSED_STATUSES or "does not contain bearer token" in str(error):
        return "auth", EXIT_AUTH
    # A credential missing a field gpmc needs fails while the client is built.
    if during_auth and isinstance(error, (KeyError, ValueError)):
        return "auth", EXIT_AUTH
    return "internal", EXIT_INTERNAL


# The texts requests and urllib3 give an HTTP status (gpmc keeps only the
# text of a per-file error, so that is all there is to go on), and fragments of
# the texts for a network that failed before Google answered. Mirrors
# FailureClassifier in Sources/PhotosBackupCore/RetryPolicy.swift.
_STATUS_PATTERNS = [
    re.compile(r"\b([1-5][0-9]{2}) (?:Client|Server) Error\b", re.IGNORECASE),
    re.compile(r"too many ([1-5][0-9]{2}) error responses", re.IGNORECASE),
    re.compile(r"\bHTTP(?: Error)?:? ([1-5][0-9]{2})\b", re.IGNORECASE),
    re.compile(r"\bstatus(?: code)?:? ([1-5][0-9]{2})\b", re.IGNORECASE),
]
_NETWORK_MARKERS = (
    "timed out", "timeout", "connection reset", "connection aborted", "connection refused", "connectionerror",
    "remotedisconnected", "max retries exceeded", "newconnectionerror", "nameresolutionerror", "name resolution",
    "network is unreachable", "no route to host", "broken pipe", "temporarily unavailable", "eof occurred",
)


def _status_in(message: str) -> int | None:
    for pattern in _STATUS_PATTERNS:
        match = pattern.search(message)
        if match:
            return int(match[1])
    return None


def _is_retryable_failure(message: str) -> bool:
    """Whether sending the same file again may succeed."""
    status = _status_in(message)
    if status is not None and status >= 400:
        return status in (408, 429) or status >= 500
    lowered = message.lower()
    return "too many requests" in lowered or any(marker in lowered for marker in _NETWORK_MARKERS)


def _email(auth_data: str) -> str | None:
    return dict(parse_qsl(auth_data)).get("Email")


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


def _upload(request: Event, client: Any, emit: Emit, failures: FailureLog, stop: StopSignal) -> int:
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
    lock = threading.Lock()

    def on_progress(event: Event) -> None:
        path = event.get("path", "")
        phase = event.get("phase")
        if phase == "skipped":
            with lock:
                skipped.add(path)
        emit(_event("progress", id=by_path.get(path), phase=phase, bytes_completed=event.get("bytes_completed", 0), bytes_total=event.get("bytes_total", 0)))

    def upload_one(item: Event) -> dict[str, str]:
        # One gpmc call per file, so each media key is reported the moment
        # Google confirms it: a stop or a crash then loses at most the files
        # in flight, never a whole batch's results.
        return client.upload(
            target={Path(item["path"]): {"hash": None, "filename": item["filename"]}},
            use_quota=use_quota,
            saver=saver,
            threads=1,
            force_upload=bool(request.get("force", False)),
            progress_callback=on_progress,
        )

    counts = {"uploaded": 0, "existing": 0, "failed": 0}
    confirmed: list[str] = []
    escaped_retryable: set[str] = set()
    executor = ThreadPoolExecutor(max_workers=threads)
    try:
        futures = {executor.submit(upload_one, item): item for item in items}
        for future in as_completed(futures):
            item = futures[future]
            path = Path(item["path"]).absolute().as_posix()
            try:
                media_key = future.result().get(path)
            except Exception as error:
                # gpmc catches per-file errors itself; this only guards
                # against one escaping and taking the other files with it.
                logging.getLogger(__name__).exception("upload of %s raised", path)
                failures.reasons.setdefault(path, str(error))
                if _classify(error)[0] in ("network", "rate_limit"):
                    escaped_retryable.add(path)
                media_key = None
            if media_key:
                status = "existing" if path in skipped else "uploaded"
                counts[status] += 1
                confirmed.append(media_key)
                emit(_event("item", id=item["id"], media_key=media_key, status=status))
            else:
                counts["failed"] += 1
                message = failures.reasons.get(path, "gpmc returned no media key")
                retryable = path in escaped_retryable or _is_retryable_failure(message)
                emit(_event("item_failed", id=item["id"], message=message, retryable=retryable))
    finally:
        # On any way out (a stop, the app gone and stdout broken), files not
        # yet started must not upload behind the app's back.
        executor.shutdown(wait=False, cancel_futures=True)

    if album and confirmed:
        # A stop must not land between Google creating the album and the app
        # hearing its id, or the next run would create a second one.
        with stop.critical():
            try:
                album_id = _add_to_album(client, confirmed, album)
                emit(_event("album", album_id=album_id, added=len(confirmed)))
            except Exception as error:
                logging.getLogger(__name__).exception("adding to album failed")
                emit(_event("album_failed", message=str(error)))

    emit(_event("done", **counts))
    return EXIT_OK



def _verification_items(request: Event) -> list[Event]:
    items = _require(request, "items", list)
    if not items or len(items) > 1000:
        raise RequestError("verification requires 1-1000 items")
    for item in items:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k] for k in ("id", "path", "media_key")):
            raise RequestError("verification items require id, path and media_key")
        if "expected_bytes" in item and (type(item["expected_bytes"]) is not int or item["expected_bytes"] <= 0):
            raise RequestError("expected_bytes must be positive")
        if "expected_sha256" in item and (not isinstance(item["expected_sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", item["expected_sha256"])):
            raise RequestError("expected_sha256 must be a lowercase SHA-256 digest")
    return items


def _original_url(value: Any) -> str:
    # Both the initial URL and every redirect must remain on Google download
    # hosts. No authorization header is sent: these are signed download URLs.
    if not isinstance(value, str):
        raise ValueError("original download unavailable")
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower()
    if (parsed.scheme != "https" or parsed.username or parsed.password or
            parsed.port not in (None, 443) or not any(
                host == suffix or host.endswith("." + suffix)
                for suffix in ("googleusercontent.com", "googlevideo.com"))):
        raise ValueError("untrusted original download location")
    return value


def verify_original(client: Any, item: Event, stop: StopSignal | None = None) -> Event:
    """Compare a fresh Google ORIGINAL readback with a stable local source.

    Success proves bytes for this media key at this instant, not future
    availability or quota treatment. Call immediately before source removal.
    Never return/log signed URLs or provider exception text.
    """
    stop = stop or StopSignal()
    deadline = time.monotonic() + 1800

    def check() -> None:
        if stop.requested:
            raise StopRequested
        if time.monotonic() > deadline:
            raise TimeoutError("original verification timed out")

    path = Path(item["path"])
    with path.open("rb", buffering=0) as source:
        before = os.fstat(source.fileno())
        if before.st_size <= 0 or before.st_size > 20 * 1024**3:
            raise ValueError("source outside verification size limit")
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            check()
            digest.update(chunk)
        sha256 = digest.hexdigest()
        if item.get("expected_bytes", before.st_size) != before.st_size or item.get("expected_sha256", sha256) != sha256:
            raise ValueError("source changed since preview")
        check()
        decoded = client.api.get_download_urls(item["media_key"])
        url = _original_url(decoded["1"]["5"]["2"]["6"])
        remote_digest, count = hashlib.sha256(), 0
        # A fresh session has no account cookies or Authorization defaults.
        with client.api._new_session() as session:
            session.verify = True
            session.trust_env = False
            session.headers.clear()
            session.cookies.clear()
            # Disable provider retry/backoff on streamed reads; the caller can retry.
            for adapter in getattr(session, "adapters", {}).values():
                adapter.max_retries = 0
            for redirect in range(6):
                check()
                response = session.get(url, stream=True, allow_redirects=False,
                                       headers={"Accept-Encoding": "identity"}, timeout=(15, 30))
                try:
                    if response.status_code in (301, 302, 303, 307, 308):
                        if redirect == 5:
                            raise ValueError("too many original download redirects")
                        url = _original_url(urljoin(url, response.headers.get("Location", "")))
                        continue
                    if response.status_code != 200:
                        raise ValueError("original download refused")
                    for chunk in response.iter_content(1024 * 1024):
                        check()
                        count += len(chunk)
                        if count > before.st_size:
                            raise ValueError("original download exceeds source size")
                        remote_digest.update(chunk)
                    break
                finally:
                    response.close()
        # Windows may defer timestamp updates while another handle is open.
        # Re-read bytes as well as metadata; never accept a same-size mutation.
        source.seek(0)
        final_digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            check()
            final_digest.update(chunk)
        if final_digest.hexdigest() != sha256:
            raise ValueError("source changed during verification")
        after = os.fstat(source.fileno())
        # Compare handle metadata with handle metadata. On Windows, stat(path)
        # and fstat(handle) may expose different file-ID widths.
        with path.open("rb", buffering=0) as current_source:
            current = os.fstat(current_source.fileno())
        fingerprint = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if fingerprint(before) != fingerprint(after) or fingerprint(before) != fingerprint(current):
            raise ValueError("source changed during verification")
        if count != before.st_size or remote_digest.hexdigest() != sha256:
            raise ValueError("Google original differs from source")
        return {"id": item["id"], "media_key": item["media_key"], "sha256": sha256, "bytes": count}


def _verify_originals(request: Event, client: Any, emit: Emit, stop: StopSignal) -> int:
    counts = {"verified": 0, "failed": 0}
    for item in _verification_items(request):
        try:
            proof = verify_original(client, item, stop)
        except Exception:
            # Provider exceptions can contain signed download URLs.
            counts["failed"] += 1
            emit(_event("item_failed", id=item["id"], message="Original verification failed; retain the source", retryable=True))
        else:
            counts["verified"] += 1
            emit(_event("verified", **proof))
    emit(_event("done", **counts))
    return EXIT_OK if not counts["failed"] else EXIT_INTERNAL

def run(request: Any, emit: Emit, client_factory: ClientFactory = default_client_factory, stop: StopSignal | None = None) -> int:
    """Answer one request through emit(); returns the process exit status."""
    stop = stop or StopSignal()
    failures = FailureLog()
    logging.getLogger().addHandler(failures)
    try:
        if not isinstance(request, dict):
            raise RequestError("the request must be a JSON object")
        command = request.get("command")
        if command == "version":
            emit(_event("version", protocol=PROTOCOL_VERSION, gpmc=_gpmc_version(), python=platform.python_version()))
            return EXIT_OK
        if command not in ("check-auth", "upload", "add-to-album", "verify-original"):
            raise RequestError(f"unknown command {command!r}")

        # Validate everything that needs no network before authenticating.
        if command == "upload":
            _items(request)
        elif command == "verify-original":
            _verification_items(request)
        elif command == "add-to-album":
            if not all(isinstance(key, str) and key for key in _require(request, "media_keys", list)):
                raise RequestError("`media_keys` must be non-empty strings")
            _album(request, required=True)

        try:
            client = _connect(request, client_factory)
        except RequestError:
            raise
        except Exception as error:
            kind, code = _classify(error, during_auth=True)
            logging.getLogger(__name__).exception("authentication failed")
            emit(_event("fatal", kind=kind, message=str(error)))
            return code

        if command == "verify-original":
            return _verify_originals(request, client, emit, stop)
        if command == "check-auth":
            # A bearer token proves the sign-in; a hash lookup proves Google
            # Photos itself accepts the account (gotohp validates the same way).
            try:
                client.api.find_remote_media_by_hash(bytes(20))
            except Exception as error:
                kind, code = _classify(error)
                logging.getLogger(__name__).exception("Google Photos refused the account")
                emit(_event("fatal", kind=kind, message=f"Google Photos refused the account: {error}"))
                return code
            emit(_event("auth", email=_email(request["auth_data"])))
            return EXIT_OK
        if command == "add-to-album":
            with stop.critical():
                album_id = _add_to_album(client, request["media_keys"], request["album"])
                emit(_event("album", album_id=album_id, added=len(request["media_keys"])))
            return EXIT_OK
        return _upload(request, client, emit, failures, stop)
    except StopRequested:
        emit(_event("stopped"))
        return EXIT_STOPPED
    except BrokenPipeError:
        # The app is gone; there is nobody left to report to.
        return EXIT_STOPPED
    except RequestError as error:
        emit(_event("fatal", kind="request", message=str(error)))
        return EXIT_REQUEST
    except Exception as error:
        logging.getLogger(__name__).exception("bridge failed")
        if _http_status(error) == 429:
            kind, code = "rate_limit", EXIT_RATE_LIMIT
        elif _is_network_error(error):
            kind, code = "network", EXIT_NETWORK
        else:
            kind, code = "internal", EXIT_INTERNAL
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
        with contextlib.suppress(BrokenPipeError):
            real.flush()
        os.dup2(saved, 1)
        with contextlib.suppress(BrokenPipeError):
            real.close()


def main() -> int:
    # Configure the root logger before gpmc does: its basicConfig() is then a
    # no-op, so its records reach stderr as plain lines instead of rich markup.
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    with protocol_stdout() as out:
        lock = threading.Lock()
        terminal = False

        def emit(event: Event) -> None:
            nonlocal terminal
            line = json.dumps(event, separators=(",", ":"))
            with lock:
                # 2026-10-15: A worker can finish after SIGTERM interrupts
                # the main thread; the process protocol must end at stopped.
                if terminal:
                    return
                out.write(line + "\n")
                out.flush()
                if event["type"] in ("done", "stopped", "fatal"):
                    terminal = True

        try:
            request = json.loads(sys.stdin.read())
        except ValueError as error:
            emit(_event("fatal", kind="request", message=f"stdin is not JSON: {error}"))
            return EXIT_REQUEST
        stop = StopSignal()
        signal.signal(signal.SIGTERM, lambda _signum, _frame: stop.request())
        # 2026-10-15: Windows console clients send CTRL_BREAK_EVENT; unlike
        # terminate(), it lets the bridge report its confirmed work first.
        if hasattr(signal, "SIGBREAK"):
            signal.signal(signal.SIGBREAK, lambda _signum, _frame: stop.request())
        code = run(request, emit, stop=stop)
    if code == EXIT_STOPPED:
        # Abandoned uploads are still running in worker threads, and normal
        # interpreter exit would wait for every one of them.
        sys.stderr.flush()
        os._exit(code)
    return code


if __name__ == "__main__":
    sys.exit(main())
