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
   "items": [{"id": "<PHAsset id>", "path": "/abs/file", "filename": "IMG_1.HEIC",
              "force": false}],                   force optional, per item
   "quality": "original" | "saver" | "quota",     optional, default original
   "threads": 1,                                  optional
   "force": false,                                optional, skip gpmc's hash check
   "timeout": 60,                                 optional, seconds per request
   "album": {"id": "..."} | {"name": "..."}}      optional
  {"command": "add-to-album", "auth_data": "...", "media_keys": [...], "album": {...}}

  An album may also carry "split_missing": true: a 404 then finds the keys
  Google no longer has instead of failing the whole call (see
  _add_splitting_missing). "probe_media_keys", which apps before 0.6.0 sent,
  is ignored: the bridge never sends a key its request is not adding.

Events all carry "type" and "v" (PROTOCOL_VERSION): version, auth, progress,
item, item_failed, album, missing_media, album_failed, done, stopped, fatal,
and served in a serve session.
Each item is reported as soon as Google confirms it. A fatal or stopped event
is always the last line and the exit status names its kind (EXIT_*).

  item_failed {"id", "message", "retryable"}   retryable: sending the same
      file again may work (network trouble, HTTP 408/429/5xx); added within
      protocol 1, so readers must not require it.
  album {"album_id", "added", "media_keys"?}   media_keys, the keys actually
      added, only for a split_missing album; without it every key went in.
  missing_media {"media_keys"}   split_missing only, before album: keys Google
      no longer has. Both come before album_failed or fatal when the album
      step stops part-way, so an album it made is never lost.
  fatal {"kind", "message"}   kind: auth | network | rate_limit | request |
      internal. rate_limit is Google's HTTP 429. ("storage_full" is reserved:
      gpmc 0.9.0 drops the response body that tells a full account apart from
      any other refusal, so this bridge cannot report it.)

SIGTERM stops the run: files still uploading are abandoned (the next run finds
any Google did commit through gpmc's hash check), except that an album call in
progress is allowed to finish and report first.

Serve session (the Mac app, one per backup run): a first stdin line
{"command": "serve"} keeps the bridge reading one request per line, each on a
single line, until stdin closes (exit 0). Every request is answered with the
events it gets one-shot, then

  served {"code"}   the exit status a one-shot bridge would have had

so a reader waits for served instead of end of file. The client, gpmc's bearer
token and the kept connections last for the session; a stop ends it (stopped,
exit 5). The flags each upload sends to gpmc are the same in both modes
(upload_flags).
"""

from __future__ import annotations

import contextlib
import functools
import hashlib
import json
import logging
import ntpath
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
MAX_THREADS = 16

# quality -> (saver, use_quota), the two gpmc flags that pick the device model
# gpmc reports at commit: Pixel XL (original, free), Pixel 2 (storage saver),
# Pixel 8 (original, counted against the account's storage).
QUALITIES = {"original": (False, False), "saver": (True, False), "quota": (False, True)}


def upload_flags(quality: str) -> dict[str, bool]:
    """The gpmc keyword arguments a quality sends; the only place they are made.

    gpmc 0.9.0's Client._upload_file picks the model it commits from these two
    flags and nothing else (Pixel XL when both are False). Every upload the
    bridge makes passes exactly these, so one long-lived bridge, more threads
    or kept connections cannot move an Original-quality item onto the
    account's storage. tests/test_uplink.py QualityGuardTests and
    tests/test_original_real_gpmc.py hold every path to it.
    """
    saver, use_quota = QUALITIES[quality]
    return {"saver": saver, "use_quota": use_quota}

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


def _filesystem_path(path: str) -> str:
    """Use Win32 extended paths for I/O without changing serialized item IDs."""
    if sys.platform != "win32":
        return path
    # Normalize separators/dot components before adding the extended prefix:
    # the extended Win32 namespace does not perform ordinary path parsing.
    absolute = ntpath.abspath(path)
    if absolute.startswith("\\\\.\\"):
        raise RequestError("Windows device namespace paths are not supported")
    if absolute.startswith("\\\\?\\"):
        return absolute
    if absolute.startswith("\\\\"):
        return "\\\\?\\UNC\\" + absolute[2:]
    return "\\\\?\\" + absolute


def _path_key(path: str) -> str:
    """Match gpmc's native log paths and POSIX progress/result paths alike."""
    if sys.platform == "win32":
        return ntpath.normcase(_filesystem_path(path)).replace("\\", "/")
    return Path(path).absolute().as_posix()


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
                self.reasons[_path_key(match["path"])] = match["reason"]


# Google takes at most 500 media keys per add-to-album call (gpmc's batch).
ALBUM_BATCH = 500

# Every gpmc name the bridge calls, held against the fakes by
# tests/test_gpmc_surface.py and against the bundled gpmc by
# scripts/build-app.sh. Measured 2026-10-26: a call to a method that exists
# only on gpmc's main branch shipped from v0.2.0 through 0.5.1 because both
# fakes had it, and every album append after the first batch failed.
GPMC_SURFACE: dict[str, tuple[str, ...]] = {
    "Client": ("upload", "add_to_album"),
    "Api": ("bearer_token", "find_remote_media_by_hash", "get_download_urls", "_new_session", "add_media_to_album", "create_album"),
}


# gpmc 0.9.0 decodes Google's replies without a schema, and blackboxprotobuf
# then reads a media key whose bytes happen to parse as protobuf as a nested
# message: a dict instead of the key. Measured 2026-10-26: about one random
# "AF1Qip..." key in 14,000; the dict broke the item's line in the app ("The
# uploader stopped unexpectedly (exit 0)") and the album add for its batch.
# gpmc fixed this on main after 0.9.0 by pinning the key fields to strings
# (github.com/xob0t/gpmc issue #80, MIT); these are those three schemas.
KEY_RESPONSE_TYPES: dict[str, dict[str, Any]] = {
    "find_remote_media_by_hash": {"1": {"type": "message", "message_typedef": {"2": {"type": "message", "message_typedef": {
        "2": {"type": "message", "message_typedef": {"1": {"type": "string"}}}}}}}},
    "commit_upload": {"1": {"type": "message", "message_typedef": {"3": {"type": "message", "message_typedef": {
        "1": {"type": "string"}}}}}},
    "create_album": {"1": {"type": "message", "message_typedef": {"1": {"type": "string"}}}},
}
_decode_hint = threading.local()


def pin_media_key_types(api_module: Any) -> None:
    """Make 0.9.0's three key-returning calls decode with upstream's schemas.

    Each of them decodes exactly one reply, through the decode_message name
    gpmc.api imported; the schema travels in a thread-local, so parallel
    uploads keep their own. A gpmc that passes a schema itself is unaffected.
    """
    if getattr(api_module, "_photos_backup_key_types", False):
        return
    original = api_module.decode_message

    def decode_message(buf: Any, message_type: Any = None, *args: Any, **kwargs: Any) -> Any:
        if message_type is None:
            message_type = getattr(_decode_hint, "typedef", None)
        return original(buf, message_type, *args, **kwargs)

    def pinned(method: Callable[..., Any], typedef: dict[str, Any]) -> Callable[..., Any]:
        @functools.wraps(method)
        def call(self: Any, *args: Any, **kwargs: Any) -> Any:
            _decode_hint.typedef = typedef
            try:
                return method(self, *args, **kwargs)
            finally:
                _decode_hint.typedef = None

        return call

    api_module.decode_message = decode_message
    for name, typedef in KEY_RESPONSE_TYPES.items():
        setattr(api_module.Api, name, pinned(getattr(api_module.Api, name), typedef))
    api_module._photos_backup_key_types = True


def missing_gpmc_surface(client_type: Any, api_type: Any) -> list[str]:
    owners = {"Client": client_type, "Api": api_type}
    return [f"{owner}.{name}" for owner, names in GPMC_SURFACE.items() for name in names if not hasattr(owners[owner], name)]


def _vendored_site_packages() -> None:
    """The app bundle ships gpmc and its dependencies beside this file."""
    vendored = Path(__file__).resolve().parent / "site-packages"
    if vendored.is_dir() and str(vendored) not in sys.path:
        sys.path.insert(0, str(vendored))


def default_client_factory(auth_data: str, timeout: int) -> Any:
    _vendored_site_packages()
    from gpmc import Client

    if _gpmc_version() == "0.9.0":
        import gpmc.api

        pin_media_key_types(gpmc.api)
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
    if not isinstance(album.get("split_missing", False), bool):
        raise RequestError("`album.split_missing` must be a boolean")
    # probe_media_keys from an app before 0.6.0 is accepted and never read.
    return album


def _items(request: Event) -> list[Event]:
    items = _require(request, "items", list)
    for item in items:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k] for k in ("id", "path", "filename")):
            raise RequestError("every item needs string `id`, `path` and `filename`")
        if not isinstance(item.get("force", False), bool):
            raise RequestError("an item's `force` must be a boolean")
    return items


def _connect(request: Event, factory: ClientFactory) -> Any:
    """Build the client and fetch a bearer token, so auth fails before any upload."""
    auth_data = _require(request, "auth_data", str).strip()
    timeout = request.get("timeout", DEFAULT_TIMEOUT)
    if not isinstance(timeout, int) or timeout <= 0:
        raise RequestError("`timeout` must be a positive integer")
    client = factory(auth_data, timeout)
    _renew_one_at_a_time(client.api)
    _ = client.api.bearer_token
    return client


# gpmc 0.9.0's bearer_token renews an expired token with no lock, from
# whichever thread finds it expired. A serve session outlives the token (it
# expires about an hour after sign-in), so every upload thread that reads it
# during the renewal signed in again at once: up to MAX_THREADS sign-ins
# (PR #52 review). Renewals now go one at a time, and a thread that waited
# for one uses the token it brought. Without gpmc's _get_auth_token (a
# fake, a later gpmc) this changes nothing.
_RENEWAL_ATTRIBUTE = "_photos_backup_one_renewal"


def _renew_one_at_a_time(api: Any) -> None:
    renew = getattr(api, "_get_auth_token", None)
    if renew is None or getattr(api, _RENEWAL_ATTRIBUTE, False):
        return
    lock = threading.Lock()

    def renew_once() -> Any:
        with lock:
            cache = getattr(api, "auth_response_cache", None) or {}
            # gpmc's own test for an expired token, the other way round.
            if cache.get("Auth") and int(cache.get("Expiry", "0")) > int(time.time()):
                return cache
            renewed = renew()
            # Stored before the lock opens: gpmc stores it only after this
            # returns, and a thread let in meanwhile would find the old,
            # expired token and sign in again.
            api.auth_response_cache = renewed
            return renewed

    api._get_auth_token = renew_once
    setattr(api, _RENEWAL_ATTRIBUTE, True)


# gpmc 0.9.0 makes every call through `with self._new_session() as session:`,
# a new requests.Session each time, so every call opens its own TCP and TLS
# connection and closes it: four per uploaded file (hash check, upload token,
# upload, commit), each a handshake away from Google before any byte moves.
# In a serve session (the Mac app's run), while an upload or album step runs,
# Api._new_session hands out sessions from a pool instead and `with` gives
# them back, so later calls reuse the open connection. Each session is made
# by gpmc's own _new_session (same retry adapter, proxies and TLS settings)
# and is used by one call at a time; the headers and bodies are gpmc's own,
# per call, as before. Verification is left on fresh sessions:
# verify_original clears a session's headers, cookies and retries for its
# signed downloads. A one-shot request (the Windows app, the Android app's
# in-process run(), the Mac app's checks) keeps gpmc's fresh sessions.
# One session serves one call at a time, so it holds one connection per host
# and requests' per-session pool (10 connections a host) is never the limit,
# however many threads run: sixteen threads are sixteen sessions. What must
# cover every thread is this idle list: with fewer slots than threads, each
# round of calls would close the surplus sessions and open them again.
MAX_IDLE_SESSIONS = MAX_THREADS + 2
_POOL_ATTRIBUTE = "_photos_backup_sessions"

# A kept session idle longer than this is closed at checkout, not reused.
# Between two requests the app may spend minutes exporting from Photos, and a
# connection Google closed meanwhile fails the next call with
# RemoteDisconnected. urllib3 1.26 (1.26.20 in the bundle) does not retry a
# POST after a read error, so the item failed as a server error and the app
# lowered its parallelism for the rest of the run (PR #52 review). 60 s is a
# margin under the idle timeouts HTTP front ends commonly use; Google's own
# was not measured.
MAX_IDLE_SECONDS = 60.0
_monotonic = time.monotonic  # the tests replace it


class SessionPool:
    """requests sessions kept open between gpmc calls, one call at a time each."""

    def __init__(self, make: Callable[[], Any]) -> None:
        self._make = make
        # (session, when it was given back), the most recent last.
        self._idle: list[tuple[Any, float]] = []
        self._lock = threading.Lock()
        self._closed = False
        self.made = 0

    def checkout(self) -> Any:
        now = _monotonic()
        with self._lock:
            stale = [session for session, since in self._idle if now - since > MAX_IDLE_SECONDS]
            self._idle = [(session, since) for session, since in self._idle if now - since <= MAX_IDLE_SECONDS]
            session = self._idle.pop()[0] if self._idle else None
        for old in stale:
            type(old).close(old)
        if session is None:
            session = self._make()
            # `with session:` ends in close(): give it back instead.
            session.close = functools.partial(self._checkin, session)
            with self._lock:
                self.made += 1
        # A fresh gpmc session carries no cookies; neither does a kept one.
        session.cookies.clear()
        return session

    def _checkin(self, session: Any) -> None:
        with self._lock:
            if not self._closed and len(self._idle) < MAX_IDLE_SESSIONS:
                self._idle.append((session, _monotonic()))
                return
        type(session).close(session)

    def close(self) -> None:
        with self._lock:
            self._closed = True
            idle, self._idle = self._idle, []
        for session, _ in idle:
            type(session).close(session)


_MISSING = object()


@contextlib.contextmanager
def _kept_sessions(client: Any, keep: bool) -> Iterator[None]:
    """Route the client's gpmc calls through its session pool meanwhile, in a
    serve session (`keep`); a one-shot request is left as it was."""
    if not keep:
        yield
        return
    api = getattr(client, "api", None)
    previous = getattr(api, "__dict__", {}).get("_new_session", _MISSING)
    pool = getattr(client, _POOL_ATTRIBUTE, None)
    if pool is None:
        make = getattr(api, "_new_session", None)
        if make is None:
            yield
            return
        pool = SessionPool(make)
        setattr(client, _POOL_ATTRIBUTE, pool)
    api._new_session = pool.checkout
    try:
        yield
    finally:
        if previous is _MISSING:
            del api._new_session
        else:
            api._new_session = previous


def _close_sessions(client: Any) -> None:
    pool = getattr(client, _POOL_ATTRIBUTE, None)
    if pool is not None:
        pool.close()


class ClientCache:
    """The client factory of a serve session: the client, and with it gpmc's
    cached bearer token and the kept connections, lasts for the session.

    One credential at a time: a request with another credential (or timeout)
    replaces the client, so a session never holds two accounts' clients.
    """

    keeps_clients = True

    def __init__(self, factory: ClientFactory) -> None:
        self._factory = factory
        self._key: tuple[str, int] | None = None
        self._client: Any = None

    def __call__(self, auth_data: str, timeout: int) -> Any:
        key = (auth_data, timeout)
        if self._key != key:
            self.close()
            self._client = self._factory(auth_data, timeout)
            self._key = key
        return self._client

    def close(self) -> None:
        if self._client is not None:
            _close_sessions(self._client)
        self._key, self._client = None, None


# Refused album calls a request may spend telling dead keys from live ones.
# An isolated dead key costs about nine refusals (a 500-key batch halves nine
# times), so this settles about 14 per request; measured 2026-10-27 with the
# test fakes, 14 scattered dead keys in one batch took 170 calls in all.
# Whatever is left waits for the next request.
ALBUM_REFUSAL_BUDGET = 128

# Read-only lookups (Api.get_download_urls) a request may spend on keys
# refused on their own when none of its adds went in, to tell dead keys from
# a refusing album without re-adding anything. A lone dead key is the case
# that needs it (one key per request, then one lookup); keys left unread wait
# for the next request.
ALBUM_READ_BUDGET = 16

# Google's album calls fail now and then with a 5xx that a few seconds later
# does not recur. Measured 2026-10-27 on 0.5.4: 7 of about 30 album steps
# ended on a 500 or 503, and each one skipped its album for the rest of the
# run. A call answered with a 5xx or 408 is tried again after each of these
# pauses, at most ALBUM_RETRY_BUDGET times in one request, so a Google that
# keeps failing still ends the step within about a minute. Dropped
# connections are not retried here: gpmc already retries a connect for about
# 8 minutes (measured 486 s) before the bridge sees it, and the app halts the
# run on a network failure anyway.
ALBUM_RETRY_DELAYS = (2.0, 5.0, 12.0)
ALBUM_RETRY_BUDGET = 8
_sleep = time.sleep  # the tests replace it


def _album_caller(stop: StopSignal | None) -> Callable[..., Any]:
    """Call an album method, waiting out Google's passing 5xx; a stop during
    a wait ends the step (StopRequested)."""
    left = [ALBUM_RETRY_BUDGET]

    def call(method: Callable[..., Any], **kwargs: Any) -> Any:
        for delay in (*ALBUM_RETRY_DELAYS, None):
            try:
                return method(**kwargs)
            except Exception as error:
                if delay is None or not _is_transient_status(_http_status(error)) or left[0] <= 0:
                    raise
                left[0] -= 1
                logging.getLogger(__name__).info("album call failed (%s); trying again in %.0f s", error, delay)
                _wait(delay, stop)
        raise AssertionError("unreachable")

    return call


def _wait(seconds: float, stop: StopSignal | None) -> None:
    waited = 0.0
    while waited < seconds:
        if stop is not None and stop.requested:
            raise StopRequested
        step = min(0.25, seconds - waited)
        _sleep(step)
        waited += step


class AlbumIncomplete(Exception):
    """An album step stopped part-way: what it did is reported before `cause`."""

    def __init__(self, album_id: str | None, added: list[str], missing: list[str], cause: BaseException) -> None:
        super().__init__(str(cause))
        self.album_id, self.added, self.missing, self.cause = album_id, added, missing, cause


def _add_to_album(client: Any, media_keys: list[str], album: Event,
                  stop: StopSignal | None = None) -> tuple[str | None, list[str], list[str]]:
    """Add the keys to the album, creating it first when it has no id yet.

    Returns the album's id (None when no key was left to create it with), the
    keys added and the keys Google no longer has. Only a request asking for
    `split_missing` (the Mac app) looks for those; any other keeps the
    behaviour the Windows and Android apps read the album event by, where
    `album` means every key went in.
    """
    call = _album_caller(stop)
    if not album.get("split_missing"):
        if album.get("id"):
            # gpmc 0.9.0, the release the app pins, has no
            # Client.add_to_existing_album (only gpmc's main branch does):
            # append the way 0.9.0's own add_to_album does, 500 keys per call.
            for start in range(0, len(media_keys), ALBUM_BATCH):
                call(client.api.add_media_to_album, album_media_key=album["id"], media_keys=media_keys[start:start + ALBUM_BATCH])
            return album["id"], list(media_keys), []
        # The Windows and Android apps' creation path, left as it was: only
        # the Mac's (Api.create_album, below) is retried.
        # add_to_album splits past 20,000 items into "<name> 1", "<name> 2"...;
        # the first is the one the app remembers and appends to next time.
        return client.add_to_album(media_keys, album["name"], False)[0], list(media_keys), []
    return _add_splitting_missing(client, media_keys, album, stop, call)


def _add_splitting_missing(client: Any, media_keys: list[str], album: Event, stop: StopSignal | None,
                           call: Callable[..., Any]) -> tuple[str | None, list[str], list[str]]:
    # Google refuses a whole create_album or add_media_to_album call with a
    # 404 when any key in it no longer resolves. Measured 2026-10-27, a day
    # after a 25,954-item run: 1 of 72 sampled keys, and 3 of the 4 waiting
    # for one album, opened in Google Photos like a made-up key; twelve albums
    # stopped filling. A refused batch is halved until each dead key stands
    # alone, so every live key still goes in and the dead ones go back to the
    # app to upload again.
    #
    # A deleted album answers 404 too. Until 0.6.0 the app sent up to three
    # keys the album already held, and the bridge re-added one to tell the
    # two apart; a photo the owner had taken out of a shared album by hand
    # went back in. Now only this request's own adds decide: the album is
    # alive once one of them goes in, and only then are keys refused on
    # their own reported missing. If none goes in (album gone, or every key
    # dead) each key refused on its own is looked up read-only instead
    # (_read_back): one that Google answers 404 for is dead and reported
    # missing; if any reads back alive, or cannot be read, the refusal stays
    # the album's. Nothing is ever re-added to find out.
    known = album.get("id") or None
    album_id = known
    added: list[str] = []
    refused_alone: list[str] = []
    refusals = 0
    first_refusal: BaseException | None = None

    def refused(error: BaseException) -> bool:
        nonlocal refusals, first_refusal
        if _http_status(error) != 404:
            return False
        refusals += 1
        first_refusal = first_refusal or error
        return refusals <= ALBUM_REFUSAL_BUDGET

    def alive() -> bool:
        # An album being created exists once create_album answers, and a
        # 404 before that can only be the keys' own.
        return known is None or bool(added)

    def missing() -> list[str]:
        return list(refused_alone) if alive() else []

    def stop_between_calls() -> None:
        # Halving can take a few minutes inside the stop-deferring album
        # step; a stop here still reports what went in (AlbumIncomplete).
        if stop is not None and stop.requested:
            raise StopRequested

    def append(keys: list[str]) -> None:
        stop_between_calls()
        try:
            call(client.api.add_media_to_album, album_media_key=album_id, media_keys=keys)
        except Exception as error:
            if not refused(error):
                raise
            if len(keys) == 1:
                refused_alone.append(keys[0])
                return
            half = len(keys) // 2
            append(keys[:half])
            append(keys[half:])
            return
        added.extend(keys)

    def create(keys: list[str]) -> None:
        nonlocal album_id
        stop_between_calls()
        try:
            # Retried like an append: a 5xx after Google made the album risks
            # a second one either way, now or when the app tries next.
            album_id = call(client.api.create_album, album_name=album["name"], media_keys=keys)
        except Exception as error:
            if not refused(error):
                raise
            if len(keys) == 1:
                refused_alone.append(keys[0])
                return
            half = len(keys) // 2
            create(keys[:half])
            (append if album_id else create)(keys[half:])
            return
        added.extend(keys)

    try:
        # Creating through Api rather than Client.add_to_album lets a
        # refused first batch be halved too; the Mac app never sends more
        # than 500 keys, far below the 20,000 Client.add_to_album splits at.
        for start in range(0, len(media_keys), ALBUM_BATCH):
            batch = media_keys[start:start + ALBUM_BATCH]
            (append if album_id else create)(batch)
    except (Exception, StopRequested) as error:
        if added or missing() or album_id != known:
            raise AlbumIncomplete(album_id, added, missing(), error) from error
        raise
    if refused_alone and not alive() and first_refusal is not None:
        dead, settled = _read_back(client, refused_alone, stop, call)
        if not settled:
            if dead:
                raise AlbumIncomplete(album_id, added, dead, first_refusal) from first_refusal
            raise first_refusal
        return album_id, added, dead
    return album_id, added, missing()


def _read_back(client: Any, keys: list[str], stop: StopSignal | None,
               call: Callable[..., Any]) -> tuple[list[str], bool]:
    """Look up keys an album refused one by one, read-only, when nothing in
    the request went in. Returns the keys Google answered 404 for, and
    whether every key was read and found dead (only then is the refusal
    the keys' rather than the album's).

    A 404 is the only answer taken for dead. A key that comes back with a
    download URL is alive; any other answer, or a key past ALBUM_READ_BUDGET,
    proves nothing either way and is never reported, so the worst case is
    an album that fails again next run, never a photo sent twice."""
    dead: list[str] = []
    settled = len(keys) <= ALBUM_READ_BUDGET
    for key in keys[:ALBUM_READ_BUDGET]:
        if stop is not None and stop.requested:
            raise StopRequested
        try:
            answer = call(client.api.get_download_urls, media_key=key)
        except Exception as error:
            if _http_status(error) == 404:
                dead.append(key)
                continue
            logging.getLogger(__name__).info("could not read back media key %s: %s", key, error)
            settled = False
            continue
        if not _has_download_url(answer):
            logging.getLogger(__name__).info("media key %s read back without a download URL", key)
        settled = False
    return dead, settled and len(dead) == len(keys)


def _has_download_url(answer: Any) -> bool:
    try:
        return bool(answer["1"]["5"]["2"]["6"])
    except (KeyError, TypeError, IndexError):
        return False


def _album_step(client: Any, media_keys: list[str], album: Event, emit: Emit, stop: StopSignal) -> None:
    """Run the album call and report what it did, even when it stops part-way,
    so the app never loses the id of an album this call made."""
    try:
        album_id, added, missing = _add_to_album(client, media_keys, album, stop)
    except AlbumIncomplete as partial:
        _report_album(emit, album, partial.album_id, partial.added, partial.missing)
        raise partial.cause from None
    _report_album(emit, album, album_id, added, missing)


def _report_album(emit: Emit, album: Event, album_id: str | None, added: list[str], missing: list[str]) -> None:
    if missing:
        logging.getLogger(__name__).warning("Google Photos no longer has %d photos sent to an album: %s", len(missing), " ".join(missing))
        emit(_event("missing_media", media_keys=missing))
    if album_id:
        keys = {"media_keys": added} if album.get("split_missing") else {}
        emit(_event("album", album_id=album_id, added=len(added), **keys))


def _upload(request: Event, client: Any, emit: Emit, failures: FailureLog, stop: StopSignal, keep_sessions: bool) -> int:
    items = _items(request)
    quality = request.get("quality", "original")
    if quality not in QUALITIES:
        raise RequestError(f"`quality` must be one of {sorted(QUALITIES)}")
    flags = upload_flags(quality)
    threads = request.get("threads", 1)
    if not isinstance(threads, int) or not 1 <= threads <= MAX_THREADS:
        raise RequestError(f"`threads` must be 1-{MAX_THREADS}")
    album = _album(request, required=False)

    by_path = {_path_key(item["path"]): item["id"] for item in items}
    skipped: set[str] = set()
    lock = threading.Lock()

    def on_progress(event: Event) -> None:
        path = _path_key(event.get("path", ""))
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
            target={Path(_filesystem_path(item["path"])): {"hash": None, "filename": item["filename"]}},
            **flags,
            threads=1,
            # Per item: a photo whose earlier key Google lost goes up again
            # without the hash check, which could hand that key back.
            force_upload=bool(request.get("force", False)) or item.get("force", False),
            progress_callback=on_progress,
        )

    with _kept_sessions(client, keep_sessions):
        counts, confirmed = _upload_all(items, upload_one, threads, emit, failures, skipped)
        if album and confirmed:
            # A stop must not land between Google creating the album and the app
            # hearing its id, or the next run would create a second one.
            with stop.critical():
                try:
                    _album_step(client, confirmed, album, emit, stop)
                except Exception as error:
                    logging.getLogger(__name__).exception("adding to album failed")
                    emit(_event("album_failed", message=str(error)))

    emit(_event("done", **counts))
    return EXIT_OK


def _upload_all(items: list[Event], upload_one: Callable[[Event], dict[str, str]], threads: int, emit: Emit,
                failures: FailureLog, skipped: set[str]) -> tuple[dict[str, int], list[str]]:
    """Send every item, `threads` at a time in the order given, reporting each
    as Google confirms it; returns the counts and the confirmed media keys."""
    counts = {"uploaded": 0, "existing": 0, "failed": 0}
    confirmed: list[str] = []
    escaped_retryable: set[str] = set()
    executor = ThreadPoolExecutor(max_workers=threads)
    try:
        futures = {executor.submit(upload_one, item): item for item in items}
        for future in as_completed(futures):
            item = futures[future]
            path = _path_key(item["path"])
            try:
                media_key = {_path_key(key): value for key, value in future.result().items()}.get(path)
            except Exception as error:
                # gpmc catches per-file errors itself; this only guards
                # against one escaping and taking the other files with it.
                logging.getLogger(__name__).exception("upload of %s raised", path)
                failures.reasons.setdefault(path, str(error))
                if _classify(error)[0] in ("network", "rate_limit"):
                    escaped_retryable.add(path)
                media_key = None
            if media_key is not None and not isinstance(media_key, str):
                # A key gpmc could not decode as a string would break this
                # item's line in the app and the album add for the batch.
                failures.reasons[path] = f"gpmc returned a media key of type {type(media_key).__name__}, not a string"
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
    return counts, confirmed


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

    path = Path(_filesystem_path(item["path"]))
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
    client = None
    # A serve session's ClientCache keeps the client between requests, and
    # with it the kept connections; a one-shot request keeps neither.
    keep_sessions = bool(getattr(client_factory, "keeps_clients", False))
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
            with _kept_sessions(client, keep_sessions), stop.critical():
                _album_step(client, request["media_keys"], request["album"], emit, stop)
            return EXIT_OK
        return _upload(request, client, emit, failures, stop, keep_sessions)
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
        # A client made for this request alone takes its connections with it;
        # a serve session's ClientCache keeps them for the next request.
        if client is not None and not keep_sessions:
            _close_sessions(client)


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


TERMINAL_EVENTS = ("done", "stopped", "fatal")


class _Gate:
    """One request's way out: nothing after its terminal event or once it is
    closed, so a worker thread a stop abandoned cannot speak afterwards (in a
    serve session, into the next request's answer)."""

    def __init__(self, write: Emit) -> None:
        self._write = write
        self._open = True
        self._lock = threading.Lock()

    def emit(self, event: Event) -> None:
        with self._lock:
            # 2026-10-15: A worker can finish after SIGTERM interrupts
            # the main thread; the process protocol must end at stopped.
            if not self._open:
                return
            self._write(event)
            if event["type"] in TERMINAL_EVENTS:
                self._open = False

    def close(self) -> None:
        with self._lock:
            self._open = False


def _is_serve(line: str) -> bool:
    try:
        request = json.loads(line)
    except ValueError:
        return False
    return isinstance(request, dict) and request.get("command") == "serve"


def serve(lines: TextIO, write: Emit, stop: StopSignal, client_factory: ClientFactory = default_client_factory) -> int:
    """Answer one request per line until `lines` ends (the Mac app's run).

    Each request gets exactly the events a one-shot bridge would emit for it,
    then {"type": "served", "code": <that bridge's exit status>}. The client
    is kept (ClientCache), so later requests skip the start-up, the sign-in
    and new connections. A stop ends the session as it ends a one-shot run.
    """
    clients = ClientCache(client_factory)
    try:
        for line in iter(lines.readline, ""):
            if not line.strip():
                continue
            gate = _Gate(write)
            code = _serve_one(line, gate.emit, clients, stop)
            gate.close()
            write(_event("served", code=code))
            if code == EXIT_STOPPED:
                return EXIT_STOPPED
        return EXIT_OK
    except StopRequested:
        # Between requests: nothing in flight, nothing more to report.
        write(_event("stopped"))
        return EXIT_STOPPED
    except BrokenPipeError:
        return EXIT_STOPPED
    finally:
        clients.close()


def _serve_one(line: str, emit: Emit, clients: ClientCache, stop: StopSignal) -> int:
    try:
        request = json.loads(line)
    except ValueError as error:
        emit(_event("fatal", kind="request", message=f"request line is not JSON: {error}"))
        return EXIT_REQUEST
    if isinstance(request, dict) and request.get("command") == "serve":
        emit(_event("fatal", kind="request", message="already serving"))
        return EXIT_REQUEST
    return run(request, emit, client_factory=clients, stop=stop)


def _stop_on_signals(stop: StopSignal) -> None:
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stop.request())
    # 2026-10-15: Windows console clients send CTRL_BREAK_EVENT; unlike
    # terminate(), it lets the bridge report its confirmed work first.
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, lambda _signum, _frame: stop.request())


def main() -> int:
    # Configure the root logger before gpmc does: its basicConfig() is then a
    # no-op, so its records reach stderr as plain lines instead of rich markup.
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    with protocol_stdout() as out:
        lock = threading.Lock()

        def write(event: Event) -> None:
            line = json.dumps(event, separators=(",", ":"))
            with lock:
                out.write(line + "\n")
                out.flush()

        stop = StopSignal()
        # One request is one JSON object read to EOF (the Windows app, older
        # Mac builds); a first line {"command": "serve"} opens a session.
        first = sys.stdin.readline()
        if _is_serve(first):
            _stop_on_signals(stop)
            code = serve(sys.stdin, write, stop)
        else:
            gate = _Gate(write)
            try:
                request = json.loads(first + sys.stdin.read())
            except ValueError as error:
                gate.emit(_event("fatal", kind="request", message=f"stdin is not JSON: {error}"))
                return EXIT_REQUEST
            _stop_on_signals(stop)
            code = run(request, gate.emit, stop=stop)
    if code == EXIT_STOPPED:
        # Abandoned uploads are still running in worker threads, and normal
        # interpreter exit would wait for every one of them.
        sys.stderr.flush()
        os._exit(code)
    return code


if __name__ == "__main__":
    sys.exit(main())
