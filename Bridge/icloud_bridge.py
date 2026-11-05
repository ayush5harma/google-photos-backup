#!/usr/bin/env python3
"""One-request iCloud Photos to Google Photos bridge.

Requests arrive as one JSON object on stdin. Responses are newline-delimited
JSON on stdout. Passwords, verification codes and Google auth_data are never
accepted on the command line or written to protocol output. Version 1 commands:

  status         {account, state_dir}
  sign-in        {account, password, state_dir}
  send-code      {account, password, phone_id, state_dir}
  verify-2fa     {account, password, code, state_dir, phone_id?}
  backup         {account, state_dir, staging_dir, auth_data, max_items?}
  reclaim-status {}

Every event has type and v=1. Auth emits status signed_in, signed_out or
needs_2fa. Backup emits item, item_failed, progress and finally done. Each
confirmed component is committed to an account-bound SQLite ledger before its
staging file is removed. Reclaim requires an account-bound preview and fresh
original readback before conditional soft deletion to Recently Deleted.
"""

from __future__ import annotations

import contextlib
import base64
import ctypes
import hashlib
import json
import logging
import os
import queue
import shutil
import signal
import sqlite3
import sys
import tempfile
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any, Callable, Iterator
from urllib.parse import parse_qsl, urlencode

# 2026-10-15: The packaged -I smoke omitted the script directory, so insert
# the bundle paths explicitly before importing the provider or gpmc bridge.
BRIDGE_DIR = Path(__file__).resolve().parent
for directory in (BRIDGE_DIR, BRIDGE_DIR / "site-packages"):
    if directory.is_dir() and str(directory) not in sys.path:
        sys.path.insert(0, str(directory))

VERSION = 1
CHUNK = 1024 * 1024
DEFAULT_MAX_BYTES = 20 * 1024 * 1024 * 1024

# Uploads at once (issue #60): the range the apps offer, independent of how
# many gpmc threads one gpmc request may use (each iCloud upload is its own
# one-item request with threads=1).
MIN_THREADS, MAX_THREADS = 1, 32
# Originals downloading from iCloud at once.
DEFAULT_DOWNLOAD_THREADS, MAX_DOWNLOAD_THREADS = 4, 8
# Free space a download ahead leaves on the staging volume: the same margin as
# the Mac photo path's StagingWindow.freeSpaceFloor, chosen, not measured. The
# first item of an empty pipeline downloads whatever this says, as every item
# did before the pipeline existed.
FREE_SPACE_FLOOR = 5_000_000_000


class RequestError(ValueError):
    pass


class StopRequested(BaseException):
    pass


class GoogleAuthError(Exception):
    pass


class Unsupported2SAError(Exception):
    pass


class MFADeliveryError(Exception):
    pass


class UploadFailed(Exception):
    """Google did not confirm one upload. kind: rate_limit (HTTP 429),
    network (sending again may work) or transfer."""

    def __init__(self, kind: str, retryable: bool) -> None:
        super().__init__(kind)
        self.kind = kind
        self.retryable = retryable


def event(event_type: str, **fields: Any) -> dict[str, Any]:
    return {"type": event_type, "v": VERSION, **fields}


def required(request: dict[str, Any], key: str, *, strip: bool = True) -> str:
    value = request.get(key)
    if not isinstance(value, str) or not value or (strip and not value.strip()):
        raise RequestError(f"{key} is required")
    return value.strip() if strip else value


def private_dir(value: str) -> Path:
    path = Path(value).expanduser().resolve()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise RequestError("state path is not a directory")
    if os.name != "nt":
        path.chmod(0o700)
    return path


def account_key(account: str) -> str:
    return hashlib.sha256(account.casefold().encode("utf-8")).hexdigest()


def session_backend() -> str:
    if os.name == "nt":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return "posix"


def _dpapi(data: bytes, decrypt: bool) -> bytes:
    """Protect Windows session material for the current user."""
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]

    input_buf = ctypes.create_string_buffer(data)
    input_blob = Blob(len(data), ctypes.cast(input_buf, ctypes.POINTER(ctypes.c_ubyte)))
    output_blob = Blob()
    fn = ctypes.windll.crypt32.CryptUnprotectData if decrypt else ctypes.windll.crypt32.CryptProtectData
    if decrypt:
        ok = fn(ctypes.byref(input_blob), None, None, None, None, 0, ctypes.byref(output_blob))
    else:
        ok = fn(ctypes.byref(input_blob), None, None, None, None, 0, ctypes.byref(output_blob))
    if not ok:
        raise OSError("Windows credential protection failed")
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(output_blob.pbData)


@contextlib.contextmanager
def state_lock(state: Path) -> Iterator[None]:
    lock_path = state / ".icloud.lock"
    with lock_path.open("a+b") as handle:
        if os.name != "nt":
            lock_path.chmod(0o600)
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX)
        else:
            import msvcrt
            handle.seek(0)
            handle.write(b"\0")
            handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        try:
            yield
        finally:
            if os.name != "nt":
                fcntl.flock(handle, fcntl.LOCK_UN)
            else:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def has_saved_session(state: Path, account: str) -> bool:
    key = account_key(account)
    if session_backend() == "windows":
        return (state / ("session-" + key + ".dpapi")).is_file()
    if session_backend() == "macos":
        return (state / ("session-" + key + ".marker")).is_file()
    directory = state / ("session-" + key)
    return directory.is_dir() and any(directory.iterdir())


@contextlib.contextmanager
def session_directory(state: Path, account: str) -> Iterator[Path]:
    """Expose pyicloud's two files only while a request is running.

    Windows keeps their durable copies protected by CurrentUser DPAPI. A
    temporary directory is removed on normal exit; stale directories from a
    process forcibly killed by the OS are removed at the next launch.
    """
    key = account_key(account)
    backend = session_backend()
    if backend == "posix":
        cookie_dir = private_dir(str(state / ("session-" + key)))
        try:
            yield cookie_dir
        finally:
            for entry in cookie_dir.iterdir():
                if entry.is_file():
                    entry.chmod(0o600)
        return

    for stale in state.glob("session-tmp-*"):
        if stale.is_dir():
            shutil.rmtree(stale, ignore_errors=True)
    cookie_dir = Path(tempfile.mkdtemp(prefix="session-tmp-", dir=state))
    safe = state / ("session-" + key + ".dpapi")
    try:
        if backend == "windows":
            saved = _dpapi(safe.read_bytes(), True) if safe.exists() else None
        else:
            from keyring.backends.macOS import Keyring
            keyring = Keyring()
            keyring.keychain = None
            stored = keyring.get_password("google-photos-backup-icloud", key)
            saved = base64.b64decode(stored) if stored else None
        if saved:
            decoded = json.loads(saved)
            for name, content in decoded.items():
                if Path(name).name != name:
                    raise RequestError("invalid saved session")
                (cookie_dir / name).write_bytes(bytes.fromhex(content))
        yield cookie_dir
    finally:
        try:
            files = {p.name: p.read_bytes().hex() for p in cookie_dir.iterdir() if p.is_file()}
            if files:
                encoded = json.dumps(files).encode()
                if backend == "windows":
                    temporary = safe.with_suffix(".tmp")
                    temporary.write_bytes(_dpapi(encoded, False))
                    os.replace(temporary, safe)
                else:
                    keyring.set_password("google-photos-backup-icloud", key, base64.b64encode(encoded).decode())
                    marker = state / ("session-" + key + ".marker")
                    marker.touch(mode=0o600)
        finally:
            shutil.rmtree(cookie_dir, ignore_errors=True)


def make_service(account: str, password: str | None, cookie_dir: Path) -> Any:
    # 2026-10-15: The 1.32.3 PyPI wheel exposed no pyicloud_ipd import in the
    # local inspection; the pinned source distribution supplies this API.
    from pyicloud_ipd import PyiCloudService

    return PyiCloudService("com", account, lambda: password, cookie_directory=str(cookie_dir))


def auth_status(service: Any) -> str:
    if not getattr(service, "data", None):
        return "signed_out"
    if service.requires_2sa:
        if service.requires_2fa or service.data.get("dsInfo", {}).get("hsaVersion") == 2:
            return "needs_2fa"
        raise Unsupported2SAError()
    # 2026-10-15: pyicloud may load a stale token from disk; Photos performs
    # the CloudKit indexing query that tests whether the session still works.
    _ = service.photos
    return "signed_in"


def _phones(service: Any) -> list[dict[str, Any]]:
    result = []
    for phone in service.get_trusted_phone_numbers():
        label = str(phone.obfuscated_number)
        # 2026-10-15: The provider supplies an obfuscated number; reject an
        # unexpectedly unmasked response before it can reach the app.
        if not ("*" in label or "•" in label):
            label = "Trusted phone"
        result.append({"id": phone.id, "label": label})
    return result


def _is_network_error(error: Exception) -> bool:
    if any(cls.__name__ in ("ConnectionError", "Timeout", "ConnectTimeout", "ReadTimeout")
           for cls in type(error).__mro__):
        return True
    status = getattr(error, "code", None) or getattr(getattr(error, "response", None), "status_code", None)
    with contextlib.suppress(TypeError, ValueError):
        return int(status) in (408, 429) or 500 <= int(status) <= 599
    return False


def _auth_event(status: str, account: str, service: Any | None = None) -> dict[str, Any]:
    if status == "needs_2fa" and service is not None:
        device_code_available = bool(service.requires_2fa)
        try:
            phones = _phones(service)
        except Exception as error:
            if not (device_code_available and _is_network_error(error)):
                raise
            # 2026-10-15: A failed optional phone query must not prevent a
            # device code already delivered by Apple's push from being used.
            phones = []
        return event("auth", status=status, account=account, phones=phones,
                     device_code_available=device_code_available)
    return event("auth", status=status, account=account)


def _phone_id(request: dict[str, Any], service: Any) -> int:
    identifier = request.get("phone_id")
    if type(identifier) is not int or identifier < 0:
        raise RequestError("phone_id must be a trusted phone integer ID")
    if identifier not in {phone["id"] for phone in _phones(service)}:
        raise RequestError("phone_id is not a trusted phone")
    return identifier


def _auth_command(request: dict[str, Any], state: Path, emit: Callable[[dict[str, Any]], None],
                  factory: Callable[[str, str | None, Path], Any]) -> int:
    command = request["command"]
    account = required(request, "account")
    password = required(request, "password", strip=False) if command != "status" else None
    code = required(request, "code") if command == "verify-2fa" else None
    if command == "status" and not has_saved_session(state, account):
        emit(event("auth", status="signed_out", account=account))
        return 0
    with session_directory(state, account) as cookies:
        service = None
        try:
            service = factory(account, password, cookies)
            status = auth_status(service)
            if status == "needs_2fa":
                if command == "sign-in":
                    # 2026-10-15: icloudpd 1.32.3 explicitly triggers a push
                    # before asking for a device code; a failed push is nonfatal.
                    service.trigger_push_notification()
                elif command == "send-code":
                    if not service.send_2fa_code_sms(_phone_id(request, service)):
                        raise MFADeliveryError()
                elif code is not None:
                    if "phone_id" in request:
                        valid = service.validate_2fa_code_sms(_phone_id(request, service), code)
                    elif service.requires_2fa:
                        valid = service.validate_2fa_code(code)
                    else:
                        raise RequestError("phone_id is required for SMS verification")
                    if valid:
                        status = auth_status(service)
        except Exception as error:
            if _is_auth_error(error):
                status = "signed_out"
            else:
                raise
        response = _auth_event(status, account, service)
    emit(response)
    return 0


def _is_auth_error(error: Exception) -> bool:
    return type(error).__name__ in ("PyiCloudFailedLoginException", "PyiCloud2FARequiredException") or \
        getattr(error, "code", None) in (401, "401", 403, "403")


def _ledger(state: Path, account: str, google_account: str) -> sqlite3.Connection:
    binding = account.casefold() + "\0" + google_account.casefold()
    path = state / ("backup-" + hashlib.sha256(binding.encode()).hexdigest() + ".sqlite3")
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    connection.execute("CREATE TABLE IF NOT EXISTS confirmed (asset_id TEXT NOT NULL, version TEXT NOT NULL, checksum TEXT NOT NULL, media_key TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(asset_id, version, checksum))")
    if os.name != "nt":
        path.chmod(0o600)
    return connection


def _components(asset: Any) -> list[tuple[str, Any, str]]:
    from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

    versions = asset.versions
    result = []
    for name, key in (("original", AssetVersionSize.ORIGINAL), ("live", LivePhotoVersionSize.ORIGINAL)):
        if key in versions:
            version = versions[key]
            filename = asset.calculate_version_filename(
                version, key, lambda s: str(Path(s).with_suffix(".MOV")))
            result.append((name, version, filename))
    if not any(name == "original" for name, _, _ in result):
        raise ValueError("original version unavailable")
    return result


class _Abandoned(Exception):
    """The run is over; a worker leaves without starting another request."""


class _SessionGate:
    """Starts pyicloud requests one at a time.

    pyicloud_ipd 1.32.3's PyiCloudSession.request rewrites the session file
    and the cookie file after every response, so two requests starting at once
    could interleave those writes and leave a corrupt session behind. A
    download holds the gate only until its response headers arrive; the body
    then streams outside it, alongside the other downloads. Once the run ends
    no request starts, so the files are quiet when session_directory saves them.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.stopped = False

    def __enter__(self) -> None:
        self._lock.acquire()
        if self.stopped:
            self._lock.release()
            raise _Abandoned()

    def __exit__(self, *_: Any) -> bool:
        self._lock.release()
        return False

    def close(self, timeout: float) -> None:
        self.stopped = True
        if self._lock.acquire(timeout=timeout):
            self._lock.release()


def _download(asset: Any, session: Any, version: Any, destination: Path, max_bytes: int,
              gate: Any = None) -> None:
    size = getattr(version, "size", None)
    if not isinstance(size, int) or size <= 0 or size > max_bytes:
        raise ValueError("original exceeds staging limit or has unknown size")
    with gate if gate is not None else contextlib.nullcontext():
        response = asset.download(session, version.url)
    try:
        response.raise_for_status()
        count = 0
        with destination.open("xb") as output:
            if os.name != "nt":
                destination.chmod(0o600)
            for chunk in response.iter_content(CHUNK):
                if not chunk:
                    continue
                count += len(chunk)
                if count > max_bytes or count > size:
                    raise ValueError("original exceeded declared size")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if count != size:
            raise IOError("original download was incomplete")
    finally:
        response.close()


def _gpmc_client_factory(auth_data: str, timeout: int) -> Any:
    import gpmc_bridge

    return gpmc_bridge.default_client_factory(auth_data, timeout)


class _RunClients:
    """The gpmc client factory of one iCloud run: gpmc_bridge's ClientCache,
    so the client, its bearer token and its kept connections last for the run
    (keeps_clients tells gpmc_bridge.run so), behind a lock because every
    upload thread asks it for the client."""

    keeps_clients = True

    def __init__(self, factory: Callable[[str, int], Any]) -> None:
        import gpmc_bridge

        self._cache = gpmc_bridge.ClientCache(factory)
        self._lock = threading.Lock()
        self.client: Any = None

    def __call__(self, auth_data: str, timeout: int) -> Any:
        with self._lock:
            self.client = self._cache(auth_data, timeout)
            return self.client

    def close(self) -> None:
        with self._lock:
            self._cache.close()
            self.client = None


class GoogleRun:
    """One Google sign-in for a whole iCloud run (issue #60).

    Before, every photo was a separate gpmc_bridge.run() with a new client:
    a sign-in and four fresh connections a photo. Each upload is still its own
    one-item gpmc_bridge.run(), so the item is confirmed the moment Google
    commits it and every flag comes from gpmc_bridge.upload_flags("original")
    (saver and use_quota both False: Pixel XL, free), but all of them share one
    client and its pool of kept sessions.
    """

    def __init__(self, auth_data: str, factory: Callable[[str, int], Any] | None = None) -> None:
        import gpmc_bridge

        self._gpmc = gpmc_bridge
        self._auth = auth_data
        self._clients = _RunClients(factory or _gpmc_client_factory)
        self._kept: Any = None

    def __enter__(self) -> "GoogleRun":
        results: list[dict[str, Any]] = []
        code = self._gpmc.run({"command": "check-auth", "auth_data": self._auth}, results.append,
                              client_factory=self._clients)
        if code != 0 or not any(e["type"] == "auth" for e in results) or self._clients.client is None:
            self._clients.close()
            raise GoogleAuthError()
        # Entered once for the run: each upload's own _kept_sessions then finds
        # the pool in place and leaves it so. Entered and left by many threads
        # at once, the first to leave would unhook the pool under the others.
        self._kept = self._gpmc._kept_sessions(self._clients.client, True)
        self._kept.__enter__()
        return self

    def __exit__(self, *_: Any) -> bool:
        try:
            if self._kept is not None:
                self._kept.__exit__(None, None, None)
        finally:
            self._kept = None
            self._clients.close()
        return False

    def upload(self, item: dict[str, str], on_sent: Callable[[int], None] | None = None) -> tuple[str, str]:
        results: list[dict[str, Any]] = []

        def collect(event: dict[str, Any]) -> None:
            if on_sent is not None and event["type"] == "progress" and event.get("phase") == "uploading":
                on_sent(int(event.get("bytes_completed") or 0))
            results.append(event)

        request = {"command": "upload", "auth_data": self._auth, "items": [item],
                   "quality": "original", "threads": 1}
        code = self._gpmc.run(request, collect, client_factory=self._clients)
        return _upload_outcome(self._gpmc, code, results)


def _upload_outcome(gpmc: Any, code: int, results: list[dict[str, Any]]) -> tuple[str, str]:
    confirmed = next((e for e in results if e["type"] == "item"), None)
    if code == 0 and confirmed is not None and confirmed.get("media_key"):
        return confirmed["media_key"], confirmed["status"]
    fatal = next((e for e in results if e["type"] == "fatal"), None)
    if fatal is not None:
        kind = fatal.get("kind")
        if kind == "auth":
            raise GoogleAuthError()
        if kind in ("rate_limit", "network"):
            raise UploadFailed(kind, True)
        raise UploadFailed("transfer", False)
    failed = next((e for e in results if e["type"] == "item_failed"), None) or {}
    message = str(failed.get("message", ""))
    # gpmc keeps only the text of a per-file error; its status is the one
    # thing that tells Google's 429 apart from any other failure.
    if gpmc._status_in(message) == 429 or "too many requests" in message.lower():
        raise UploadFailed("rate_limit", True)
    if failed.get("retryable"):
        raise UploadFailed("network", True)
    raise UploadFailed("transfer", False)


def google_upload(auth_data: str, item: dict[str, str]) -> tuple[str, str]:
    """The default `upload`. _backup does not call it: it marks the real
    Google path, for which a backup opens one GoogleRun for the whole run."""
    with GoogleRun(auth_data) as google:
        return google.upload(item)


def check_google(auth_data: str) -> None:
    import gpmc_bridge

    results: list[dict[str, Any]] = []
    code = gpmc_bridge.run({"command": "check-auth", "auth_data": auth_data}, results.append)
    if code != 0 or not any(e["type"] == "auth" for e in results):
        raise GoogleAuthError()


class UploadParallelism:
    """How many iCloud uploads go at once (issue #60), by the shared rules.

    Automatic starts at four and adds one each time a measured step moves at
    least 10% more bytes a second than the best step so far. A step that is
    not faster is measured once more before the climb ends, so one noisy step
    cannot lock the level; a second miss goes back to the best level and
    stays there. A 429 halves the level and two retryable failures within half
    a minute take one off; after either it only goes down. Manual uses exactly
    the chosen number, whatever Google answers.

    A step is judged on wall-clock bytes over at least 24 MB and 4 seconds
    (the Mac photo path's UploadParallelism.decisionBytes/decisionSeconds),
    timed from the step's first answer so the uploads started at the previous
    level do not count for it.
    """

    INITIAL = 4
    IMPROVEMENT = 0.10
    DECISION_BYTES = 24_000_000
    DECISION_SECONDS = 4.0
    MISSES_TO_SETTLE = 2
    FAILURE_WINDOW = 30.0
    FAILURES_THAT_COUNT = 2

    def __init__(self, threads: int, automatic: bool, clock: Callable[[], float] = time.monotonic) -> None:
        if type(threads) is not int or not MIN_THREADS <= threads <= MAX_THREADS:
            raise ValueError(f"threads must be {MIN_THREADS}-{MAX_THREADS}")
        self.automatic = automatic
        self.cap = MAX_THREADS if automatic else threads
        self.level = min(self.INITIAL, self.cap) if automatic else threads
        self.climbing = automatic and self.level < self.cap
        self.reason = "finding the fastest" if self.climbing else "chosen" if not automatic else "the most it uses"
        self._clock = clock
        self._best: tuple[int, float] | None = None
        self._misses = 0
        self._window_start: float | None = None
        self._window_bytes = 0
        self._failures: deque[float] = deque()

    def completed(self, stored_bytes: int) -> None:
        """Google confirmed an upload that stored `stored_bytes` (0 when it
        already had the item)."""
        if not self.climbing:
            return
        now = self._clock()
        if self._window_start is None:
            self._window_start, self._window_bytes = now, 0
            return
        self._window_bytes += stored_bytes
        elapsed = now - self._window_start
        if self._window_bytes < self.DECISION_BYTES or elapsed < self.DECISION_SECONDS:
            return
        rate = self._window_bytes / elapsed
        self._window_start = None
        if self._best is None or rate >= self._best[1] * (1 + self.IMPROVEMENT):
            self._best, self._misses = (self.level, rate), 0
            if self.level < self.cap:
                self.level += 1
            else:
                self._settle(self.level, "the most it uses")
            return
        self._misses += 1
        if self._misses >= self.MISSES_TO_SETTLE:
            self._settle(self._best[0], f"no faster at {self.level}")

    def rate_limited(self) -> None:
        if self.automatic:
            self._settle(self.level // 2, "Google asked to slow down")

    def retryable_failure(self) -> None:
        if not self.automatic:
            return
        now = self._clock()
        self._failures.append(now)
        while self._failures and self._failures[0] < now - self.FAILURE_WINDOW:
            self._failures.popleft()
        if len(self._failures) >= self.FAILURES_THAT_COUNT:
            self._failures.clear()
            self._settle(self.level - 1, "Google had trouble keeping up")

    def _settle(self, level: int, reason: str) -> None:
        self.level = max(MIN_THREADS, level)
        self.climbing = False
        self.reason = reason
        self._window_start = None

    @property
    def summary(self) -> str:
        return f"{self.level} at a time ({self.reason})"


class _Speed:
    """Bytes a second Google is being sent, over the last half minute, from
    gpmc's per-file "uploading" progress (the Mac's ThroughputMeter)."""

    WINDOW = 30.0
    MINIMUM_SPAN = 5.0

    def __init__(self, clock: Callable[[], float]) -> None:
        self._clock = clock
        self.sent = 0
        self._per_part: dict[int, int] = {}
        self._marks: deque[tuple[float, int]] = deque()

    def update(self, key: int, total: int) -> None:
        before = self._per_part.get(key, 0)
        # Less than before: gpmc started the file over.
        added = total - before if total >= before else total
        self._per_part[key] = total
        if added <= 0:
            return
        self.sent += added
        now = self._clock()
        self._marks.append((now, self.sent))
        while len(self._marks) > 2 and self._marks[1][0] <= now - self.WINDOW:
            self._marks.popleft()

    def finished(self, key: int) -> None:
        self._per_part.pop(key, None)

    def bytes_per_second(self) -> int | None:
        if not self._marks:
            return None
        now = self._clock()
        baseline = self._marks[0]
        for mark in self._marks:
            if mark[0] <= now - self.WINDOW:
                baseline = mark
        span = now - baseline[0]
        if span < self.MINIMUM_SPAN:
            return None
        return int((self._marks[-1][1] - baseline[1]) / span)


def _free_bytes(path: Path) -> int | None:
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return None


class _Part:
    """One component (the original, or a Live Photo's motion) on its way."""

    def __init__(self, job: "_Job", name: str, version: Any, filename: str, key: tuple[str, str, str],
                 max_bytes: int) -> None:
        self.job, self.name, self.version, self.filename, self.key = job, name, version, filename, key
        size = getattr(version, "size", None)
        # An unusable size fails in _download before any byte is staged.
        self.size = size if isinstance(size, int) and 0 < size <= max_bytes else 0
        self.folder: Path | None = None
        self.path: Path | None = None
        self.done = False


class _Job:
    """One iCloud asset in the pipeline."""

    def __init__(self, asset: Any) -> None:
        self.asset = asset
        self.parts: list[_Part] = []
        self.results: list[str] = []
        self.original_media_key: str | None = None
        self.error: BaseException | None = None
        self.downloading = False

    @property
    def open_parts(self) -> int:
        return sum(1 for part in self.parts if not part.done)


class _Pipeline:
    """Downloads from iCloud and uploads to Google at the same time (issue #60).

    The worker threads only move bytes. Everything else happens on the thread
    that calls run(): reading the album, the ledger (every write in order on
    one connection), the events, and the decisions on what starts next.
    Downloads run ahead of the uploads, a few at a time, while the staged
    bytes stay within max_bytes and the staging volume keeps FREE_SPACE_FLOOR.
    An asset counts as backed up only when Google confirmed every component;
    only those reach reclaim_ids.
    """

    POLL_SECONDS = 0.5
    PROGRESS_SECONDS = 1.0
    SHUTDOWN_SECONDS = 30.0

    def __init__(self, *, service: Any, album: Any, total: int, ledger: sqlite3.Connection, staging: Path,
                 max_bytes: int, max_items: int | None, send: Callable[[dict[str, str], Callable[[int], None]], tuple[str, str]],
                 emit: Callable[[dict[str, Any]], None], parallelism: UploadParallelism, download_threads: int,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.service, self.ledger, self.staging = service, ledger, staging
        self.max_bytes, self.max_items, self.send, self.emit = max_bytes, max_items, send, emit
        self.parallelism, self.download_threads, self.clock = parallelism, download_threads, clock
        self.total = total
        self.assets = iter(album)
        self.gate = _SessionGate()
        self.messages: queue.Queue[tuple[Any, ...]] = queue.Queue()
        self.download_queue: queue.Queue[_Job | None] = queue.Queue()
        self.upload_queue: queue.Queue[_Part | None] = queue.Queue()
        self.download_workers: list[threading.Thread] = []
        self.upload_workers: list[threading.Thread] = []
        self.counts = {"uploaded": 0, "existing": 0, "failed": 0}
        self.reclaim_ids: list[str] = []
        self.speed = _Speed(clock)
        self.jobs: set[_Job] = set()
        self.ready: deque[_Part] = deque()
        self.next_job: _Job | None = None
        self.exhausted = False
        self.started = 0
        self.completed = 0
        self.downloading = 0
        self.uploading = 0
        self.staged = 0
        self.last_progress = 0.0

    def run(self) -> None:
        for _ in range(self.download_threads):
            self._spawn(self._download_worker, self.download_workers)
        try:
            while True:
                self._start_downloads()
                self._start_uploads()
                if self.exhausted and self.next_job is None and not self.jobs:
                    return
                try:
                    message = self.messages.get(timeout=self.POLL_SECONDS)
                except queue.Empty:
                    continue
                self._handle(*message)
        finally:
            self._shutdown()

    # The run's thread: what starts next.

    def _start_downloads(self) -> None:
        while True:
            if self.next_job is None:
                if self.exhausted:
                    return
                if self.max_items is not None and self.started >= self.max_items:
                    self.exhausted = True
                    return
                with self.gate:
                    asset = next(self.assets, None)
                if asset is None:
                    self.exhausted = True
                    return
                self.started += 1
                self.next_job = self._prepare(asset)
                continue
            job = self.next_job
            if not self._room_for(job):
                return
            self.next_job = None
            self.jobs.add(job)
            self.staged += sum(part.size for part in job.parts)
            job.downloading = True
            self.downloading += 1
            self.download_queue.put(job)

    def _prepare(self, asset: Any) -> _Job | None:
        """The asset's components the ledger does not hold yet, or None when
        there is nothing to transfer (all confirmed before, or unusable)."""
        job = _Job(asset)
        try:
            for name, version, filename in _components(asset):
                key = (asset.id, name, str(version.checksum))
                row = self.ledger.execute("SELECT media_key FROM confirmed WHERE asset_id=? AND version=? AND checksum=?", key).fetchone()
                if row:
                    job.results.append("existing")
                    if name == "original":
                        job.original_media_key = row[0]
                    continue
                job.parts.append(_Part(job, name, version, filename, key, self.max_bytes))
        except Exception as error:
            job.parts, job.error = [], error
        if job.parts:
            return job
        self._finish(job)
        return None

    def _room_for(self, job: _Job) -> bool:
        if self.downloading >= self.download_threads:
            return False
        # Enough ahead that every upload slot finds a file waiting, no more.
        if len(self.jobs) >= self.download_threads + 2 * self.parallelism.level:
            return False
        if not self.jobs:
            return True
        need = sum(part.size for part in job.parts)
        if self.staged + need > self.max_bytes:
            return False
        free = _free_bytes(self.staging)
        return free is None or free - need >= FREE_SPACE_FLOOR

    def _start_uploads(self) -> None:
        while self.ready and self.uploading < self.parallelism.level:
            part = self.ready.popleft()
            if part.job.error is not None:
                # A component of this asset already failed: the asset is
                # retried next run, as the serial bridge stopped at a failure.
                self._settle(part)
                continue
            self.uploading += 1
            if len(self.upload_workers) < self.uploading:
                self._spawn(self._upload_worker, self.upload_workers)
            self.upload_queue.put(part)

    # The run's thread: what the workers report.

    def _handle(self, kind: str, *fields: Any) -> None:
        if kind == "sent":
            part, total = fields
            self.speed.update(id(part), total)
            if self.clock() - self.last_progress >= self.PROGRESS_SECONDS:
                self._progress()
        elif kind == "downloaded":
            (part,) = fields
            if part.job.error is not None:
                self._settle(part)
            else:
                self.ready.append(part)
        elif kind == "download_failed":
            part, error = fields
            self._raise_if_run_ends(error)
            if _is_auth_error(error):
                # The iCloud session was refused: every later download would be too.
                raise error
            part.job.error = part.job.error or error
            for later in part.job.parts[part.job.parts.index(part):]:
                self._settle(later)
        elif kind == "download_finished":
            (job,) = fields
            job.downloading = False
            self.downloading -= 1
            self._finish_if_settled(job)
        elif kind == "uploaded":
            part, media_key, status = fields
            self.uploading -= 1
            if not media_key:
                self._upload_failed(part, RuntimeError("upload_failed"))
                return
            with self.ledger:
                self.ledger.execute("INSERT OR REPLACE INTO confirmed VALUES (?, ?, ?, ?, ?)", (*part.key, media_key, status))
            part.job.results.append(status)
            if part.name == "original":
                part.job.original_media_key = media_key
            stored = part.size if status == "uploaded" else 0
            if stored:
                self.speed.update(id(part), stored)
            self.parallelism.completed(stored)
            self._settle(part)
        elif kind == "upload_failed":
            part, error = fields
            self.uploading -= 1
            self._upload_failed(part, error)

    def _upload_failed(self, part: _Part, error: BaseException) -> None:
        self._raise_if_run_ends(error)
        if isinstance(error, GoogleAuthError):
            raise error
        if isinstance(error, UploadFailed) and error.kind == "rate_limit":
            self.parallelism.rate_limited()
        elif (isinstance(error, UploadFailed) and error.retryable) or _is_network_error(error):
            self.parallelism.retryable_failure()
        part.job.error = part.job.error or error
        self._settle(part)

    @staticmethod
    def _raise_if_run_ends(error: BaseException) -> None:
        if isinstance(error, (StopRequested, KeyboardInterrupt)):
            raise error

    def _settle(self, part: _Part) -> None:
        if part.done:
            return
        part.done = True
        self.staged -= part.size
        self.speed.finished(id(part))
        if part.folder is not None:
            shutil.rmtree(part.folder, ignore_errors=True)
        self._finish_if_settled(part.job)

    def _finish_if_settled(self, job: _Job) -> None:
        if job in self.jobs and not job.downloading and not job.open_parts:
            self.jobs.discard(job)
            self._finish(job)

    def _finish(self, job: _Job) -> None:
        asset = job.asset
        if job.error is not None:
            self.counts["failed"] += 1
            self.emit(event("item_failed", id=asset.id, code=_failure_code(job.error), retryable=True))
        else:
            status = "uploaded" if "uploaded" in job.results else "existing"
            self.counts[status] += 1
            self.emit(event("item", id=asset.id, status=status, media_key=job.original_media_key))
            self.emit(event("source_asset", id=asset.id, filename=str(asset.filename)))
            self.reclaim_ids.append(asset.id)
        self.completed += 1
        self._progress()

    def _progress(self) -> None:
        self.last_progress = self.clock()
        self.emit(event("progress", completed=self.completed, total=self.total, **self.counts,
                        bytes_sent=self.speed.sent, bytes_per_second=self.speed.bytes_per_second(),
                        threads=self.parallelism.level))

    # Worker threads: bytes only, every result back through self.messages.

    @staticmethod
    def _spawn(target: Callable[[], None], workers: list[threading.Thread]) -> None:
        # Daemon threads: a stopped run abandons transfers in flight (the
        # ledger never saw them, so the next run sends them again).
        worker = threading.Thread(target=target, daemon=True)
        workers.append(worker)
        worker.start()

    def _download_worker(self) -> None:
        while True:
            job = self.download_queue.get()
            if job is None or self.gate.stopped:
                return
            try:
                for part in job.parts:
                    try:
                        self._download_part(job, part)
                    except _Abandoned:
                        return
                    except BaseException as error:
                        self.messages.put(("download_failed", part, error))
                        break
                    self.messages.put(("downloaded", part))
            finally:
                self.messages.put(("download_finished", job))

    def _download_part(self, job: _Job, part: _Part) -> None:
        if self.gate.stopped:
            raise _Abandoned()
        part.folder = Path(tempfile.mkdtemp(prefix="asset-", dir=self.staging))
        safe_name = Path(part.filename.replace("\\", "/")).name
        if safe_name in ("", ".", ".."):
            raise ValueError("invalid original filename")
        destination = part.folder / safe_name
        _download(job.asset, self.service.session, part.version, destination, self.max_bytes, self.gate)
        created = getattr(job.asset, "asset_date", None)
        if created is not None:
            with contextlib.suppress(ValueError, OverflowError, OSError):
                timestamp = created.timestamp()
                os.utime(destination, (timestamp, timestamp))
        part.path = destination

    def _upload_worker(self) -> None:
        while True:
            part = self.upload_queue.get()
            if part is None or self.gate.stopped:
                return
            item = {"id": part.job.asset.id + ":" + part.name, "path": str(part.path), "filename": part.filename}
            try:
                media_key, status = self.send(item, lambda total, part=part: self.messages.put(("sent", part, total)))
            except BaseException as error:
                self.messages.put(("upload_failed", part, error))
                continue
            self.messages.put(("uploaded", part, media_key, status))

    def _shutdown(self) -> None:
        # No iCloud request starts after this, and one in progress has written
        # its session files before session_directory saves them.
        self.gate.close(self.SHUTDOWN_SECONDS)
        for _ in self.download_workers:
            self.download_queue.put(None)
        for _ in self.upload_workers:
            self.upload_queue.put(None)
        for job in list(self.jobs) + ([self.next_job] if self.next_job else []):
            for part in job.parts:
                if part.folder is not None:
                    shutil.rmtree(part.folder, ignore_errors=True)


def _backup(request: dict[str, Any], state: Path, emit: Callable[[dict[str, Any]], None],
            factory: Callable[[str, str | None, Path], Any],
            upload: Callable[[str, dict[str, str]], tuple[str, str]],
            verify: Callable | None = None, delete: Callable | None = None) -> int:
    account = required(request, "account")
    auth_data = required(request, "auth_data")
    automatic_reclaim = request.get("reclaim_after_backup", False)
    if type(automatic_reclaim) is not bool or (automatic_reclaim and request.get("confirm_recently_deleted") is not True):
        raise RequestError("automatic reclaim requires explicit Recently Deleted confirmation")
    google_account = dict(parse_qsl(auth_data)).get("Email", "").strip()
    if not google_account or "@" not in google_account:
        raise RequestError("Google auth_data must identify an Email account")
    staging = private_dir(required(request, "staging_dir"))
    staging = private_dir(str(staging / account_key(account)))
    # 2026-10-15: A force kill skips TemporaryDirectory cleanup; the state
    # lock makes removal of this account's abandoned files safe at next run.
    for orphan in staging.glob("asset-*"):
        if orphan.is_dir():
            shutil.rmtree(orphan)
    max_items = request.get("max_items", 100 if automatic_reclaim else None)
    if automatic_reclaim and (type(max_items) is not int or not 1 <= max_items <= 100):
        raise RequestError("automatic reclaim is limited to 100 items per confirmed run")
    if max_items is not None and (type(max_items) is not int or max_items < 1):
        raise RequestError("max_items must be a positive integer")
    max_bytes = request.get("max_staging_bytes", DEFAULT_MAX_BYTES)
    if type(max_bytes) is not int or max_bytes < 1:
        raise RequestError("max_staging_bytes must be positive")
    # An app before issue #60 sends no thread settings: one upload at a time.
    threads = request.get("threads", 1)
    automatic = request.get("threads_automatic", False)
    download_threads = request.get("download_threads", DEFAULT_DOWNLOAD_THREADS)
    if type(threads) is not int or not MIN_THREADS <= threads <= MAX_THREADS:
        raise RequestError(f"threads must be {MIN_THREADS}-{MAX_THREADS}")
    if type(automatic) is not bool:
        raise RequestError("threads_automatic must be a boolean")
    if type(download_threads) is not int or not 1 <= download_threads <= MAX_DOWNLOAD_THREADS:
        raise RequestError(f"download_threads must be 1-{MAX_DOWNLOAD_THREADS}")
    parallelism = UploadParallelism(threads, automatic)
    pipeline = None
    with contextlib.ExitStack() as stack:
        if upload is google_upload:
            send = stack.enter_context(GoogleRun(auth_data)).upload
        else:
            send = lambda item, _on_sent: upload(auth_data, item)  # noqa: E731
        cookies = stack.enter_context(session_directory(state, account))
        service = factory(account, None, cookies)
        if auth_status(service) != "signed_in":
            emit(event("auth", status="signed_out", account=account))
            return 2
        ledger = stack.enter_context(contextlib.closing(_ledger(state, account, google_account)))
        album = service.photos.all
        pipeline = _Pipeline(service=service, album=album, total=len(album), ledger=ledger, staging=staging,
                             max_bytes=max_bytes, max_items=max_items, send=send, emit=emit,
                             parallelism=parallelism, download_threads=download_threads)
        pipeline.run()
        counts = pipeline.counts
        emit(event("done", **counts, pending=max(0, pipeline.total - pipeline.completed) + counts["failed"],
                   bytes_sent=pipeline.speed.sent, threads=parallelism.level))
    reclaim_ids = pipeline.reclaim_ids
    if automatic_reclaim and reclaim_ids:
        hooks = {k: v for k, v in (("verify", verify), ("delete", delete)) if v is not None}
        preview_events: list[dict[str, Any]] = []
        code = _reclaim(dict(request, command="reclaim-preview", asset_ids=reclaim_ids), state, preview_events.append, factory, **hooks)
        preview = next((e for e in preview_events if e["type"] == "reclaim_preview"), None)
        if code or not preview or preview["count"] != len(reclaim_ids):
            emit(event("reclaim_done", soft_deleted=0, retained=len(reclaim_ids), uncertain=0, immediate_space_recovery=False))
            return 1
        return _reclaim(dict(request, command="reclaim", preview_token=preview["token"]), state, emit, factory, **hooks)
    return 0


def google_verify(auth_data: str, item: dict[str, Any]) -> dict[str, Any]:
    import gpmc_bridge
    results: list[dict[str, Any]] = []
    code = gpmc_bridge.run({"command": "verify-original", "auth_data": auth_data, "items": [item]}, results.append)
    proof = next((e for e in results if e["type"] == "verified"), None)
    if code or proof is None:
        raise ValueError("original verification failed")
    return proof


def _reclaim_snapshot(asset: Any, ledger: sqlite3.Connection) -> dict[str, Any]:
    # A previous interrupted delete cannot be made safe merely by minting a
    # new preview token. Keep it blocked until the Apple outcome is reconciled.
    if ledger.execute("SELECT 1 FROM reclaim_actions WHERE asset_id=? AND status='delete_requested' LIMIT 1", (asset.id,)).fetchone():
        raise ValueError("previous deletion outcome requires review")
    record = asset._asset_record
    tag, name = record.get("recordChangeTag"), record.get("recordName")
    if not isinstance(tag, str) or not tag or not isinstance(name, str) or not name:
        raise ValueError("source revision unavailable")
    components = []
    for kind, version, filename in _components(asset):
        checksum = str(version.checksum)
        row = ledger.execute("SELECT media_key FROM confirmed WHERE asset_id=? AND version=? AND checksum=?",
                             (asset.id, kind, checksum)).fetchone()
        if not row or not row[0] or type(version.size) is not int or version.size <= 0:
            raise ValueError("component not backed up")
        components.append(dict(kind=kind, checksum=checksum, bytes=version.size, media_key=row[0]))
    return dict(id=asset.id, record_name=name, change_tag=tag, components=components)


def _soft_delete(library: Any, snapshot: dict[str, Any]) -> None:
    # Same conditional CloudKit update used by icloudpd, but unlike its helper
    # validate both HTTP and record-level success before reporting deletion.
    body = {"atomic": True, "desiredKeys": ["isDeleted"], "operations": [{
        "operationType": "update", "record": {"fields": {"isDeleted": {"value": 1}},
        "recordChangeTag": snapshot["change_tag"], "recordName": snapshot["record_name"],
        "recordType": "CPLAsset"}}], "zoneID": library.zone_id}
    response = library.session.post(library.service_endpoint + "/records/modify?" + urlencode(library.params),
                                    data=json.dumps(body), headers={"Content-type": "application/json"})
    try:
        response.raise_for_status()
        records = response.json().get("records", [])
        if len(records) != 1:
            raise ValueError("deletion not confirmed")
        record = records[0]
        if (record.get("recordName") != snapshot["record_name"] or record.get("serverErrorCode") or
                record.get("fields", {}).get("isDeleted", {}).get("value") != 1):
            raise ValueError("deletion not confirmed")
    finally:
        response.close()


def _reclaim(request: dict[str, Any], state: Path, emit: Callable[[dict[str, Any]], None],
             factory: Callable, verify: Callable = google_verify, delete: Callable = _soft_delete) -> int:
    account, auth_data = required(request, "account"), required(request, "auth_data")
    google_account = dict(parse_qsl(auth_data)).get("Email", "").strip()
    if not google_account or "@" not in google_account:
        raise RequestError("Google auth_data must identify an Email account")
    command = request["command"]
    if command == "reclaim" and request.get("confirm_recently_deleted") is not True:
        raise RequestError("confirm_recently_deleted must be true after reviewing the preview")
    if verify is google_verify:
        check_google(auth_data)
    with session_directory(state, account) as cookies, contextlib.closing(_ledger(state, account, google_account)) as ledger:
        ledger.execute("CREATE TABLE IF NOT EXISTS reclaim_batches (token TEXT PRIMARY KEY, created REAL NOT NULL, snapshot TEXT NOT NULL)")
        ledger.execute("CREATE TABLE IF NOT EXISTS reclaim_actions (token TEXT NOT NULL, asset_id TEXT NOT NULL, status TEXT NOT NULL, PRIMARY KEY(token,asset_id))")
        service = factory(account, None, cookies)
        if auth_status(service) != "signed_in":
            emit(event("auth", status="signed_out", account=account))
            return 2
        if command == "reclaim-preview":
            ids = request.get("asset_ids")
            if not isinstance(ids, list) or not ids or len(ids) > 100 or not all(isinstance(i, str) and i for i in ids):
                raise RequestError("select 1-100 asset_ids for a reclaim preview")
            wanted, snapshots = set(ids), []
            for asset in service.photos.all:
                if asset.id not in wanted:
                    continue
                try:
                    snapshot = _reclaim_snapshot(asset, ledger)
                    snapshots.append(snapshot)
                    emit(event("reclaim_candidate", id=asset.id, components=len(snapshot["components"]),
                               bytes=sum(c["bytes"] for c in snapshot["components"])))
                except Exception:
                    emit(event("item_failed", id=asset.id, code="not_reclaimable", retryable=False))
                wanted.remove(asset.id)
                if not wanted:
                    break
            for missing in wanted:
                emit(event("item_failed", id=missing, code="source_unavailable", retryable=True))
            token = uuid.uuid4().hex
            with ledger:
                ledger.execute("INSERT INTO reclaim_batches VALUES (?,?,?)", (token, time.time(), json.dumps(snapshots, sort_keys=True)))
            emit(event("reclaim_preview", token=token, count=len(snapshots),
                       bytes=sum(c["bytes"] for a in snapshots for c in a["components"]),
                       expires_in=900, destination="recently_deleted", immediate_space_recovery=False))
            return 0
        token = required(request, "preview_token")
        row = ledger.execute("SELECT created,snapshot FROM reclaim_batches WHERE token=?", (token,)).fetchone()
        if not row or not 0 <= time.time() - row[0] <= 900:
            raise RequestError("preview expired or belongs to another account; preview again")
        snapshots = {a["id"]: a for a in json.loads(row[1])}
        staging = private_dir(str(private_dir(required(request, "staging_dir")) / account_key(account)))
        max_bytes = request.get("max_staging_bytes", DEFAULT_MAX_BYTES)
        if type(max_bytes) is not int or not 0 < max_bytes <= DEFAULT_MAX_BYTES:
            raise RequestError("invalid staging limit")
        counts = dict(soft_deleted=0, retained=0, uncertain=0)
        seen = set()
        for asset in service.photos.all:
            if asset.id not in snapshots:
                continue
            seen.add(asset.id)
            snapshot = snapshots[asset.id]
            prior = ledger.execute("SELECT status FROM reclaim_actions WHERE token=? AND asset_id=?", (token, asset.id)).fetchone()
            if prior:
                # An interrupted request may have reached Apple. Never replay a
                # possibly committed deletion, even if a stale listing returns it.
                counts["uncertain" if prior[0] == "delete_requested" else "soft_deleted"] += 1
                continue
            requested = False
            try:
                if _reclaim_snapshot(asset, ledger) != snapshot:
                    raise ValueError("source changed since preview")
                for (kind, version, filename), expected in zip(_components(asset), snapshot["components"]):
                    with tempfile.TemporaryDirectory(prefix="reclaim-", dir=staging) as folder:
                        destination = Path(folder) / "original"
                        _download(asset, service.session, version, destination, max_bytes)
                        proof = verify(auth_data, dict(id=asset.id + ":" + kind, path=str(destination),
                                                       media_key=expected["media_key"], expected_bytes=expected["bytes"]))
                        if proof.get("bytes") != expected["bytes"] or proof.get("media_key") != expected["media_key"]:
                            raise ValueError("original verification incomplete")
                with ledger:
                    ledger.execute("INSERT INTO reclaim_actions VALUES (?,?,?)", (token, asset.id, "delete_requested"))
                requested = True
                delete(service.photos, snapshot)
                with ledger:
                    ledger.execute("UPDATE reclaim_actions SET status='soft_deleted' WHERE token=? AND asset_id=?", (token, asset.id))
                counts["soft_deleted"] += 1
                emit(event("reclaimed", id=asset.id, destination="recently_deleted"))
            except (StopRequested, KeyboardInterrupt):
                raise
            except Exception:
                counts["uncertain" if requested else "retained"] += 1
                emit(event("item_failed", id=asset.id, code="deletion_unconfirmed" if requested else "verification_failed", retryable=False))
        for missing in snapshots.keys() - seen:
            prior = ledger.execute("SELECT status FROM reclaim_actions WHERE token=? AND asset_id=?", (token, missing)).fetchone()
            counts["soft_deleted" if prior and prior[0] == "soft_deleted" else "uncertain" if prior else "retained"] += 1
        emit(event("reclaim_done", **counts, immediate_space_recovery=False))
        return 0 if not counts["retained"] and not counts["uncertain"] else 1

def _failure_code(error: BaseException) -> str:
    if isinstance(error, UploadFailed):
        return "network" if error.retryable else "transfer_failed"
    message = str(error)
    if "staging limit" in message or "declared size" in message:
        return "staging_limit"
    if "original version unavailable" in message:
        return "original_unavailable"
    if _is_auth_error(error):
        return "auth"
    if isinstance(error, (ConnectionError, TimeoutError)):
        return "network"
    return "transfer_failed"


def run(request: Any, emit: Callable[[dict[str, Any]], None],
        factory: Callable[[str, str | None, Path], Any] = make_service,
        upload: Callable[[str, dict[str, str]], tuple[str, str]] = google_upload,
        verify: Callable = google_verify, delete: Callable = _soft_delete) -> int:
    try:
        if not isinstance(request, dict):
            raise RequestError("request must be an object")
        command = required(request, "command")
        if command == "reclaim-status":
            emit(event("reclaim", enabled=True, requires_preview=True, destination="recently_deleted", immediate_space_recovery=False))
            return 0
        if command not in ("status", "sign-in", "send-code", "verify-2fa", "backup", "reclaim-preview", "reclaim"):
            raise RequestError("unknown command")
        state = private_dir(required(request, "state_dir"))
        with state_lock(state):
            if command in ("reclaim-preview", "reclaim"):
                return _reclaim(request, state, emit, factory, verify, delete)
            if command == "backup":
                return _backup(request, state, emit, factory, upload, verify, delete)
            return _auth_command(request, state, emit, factory)
    except (StopRequested, KeyboardInterrupt):
        emit(event("stopped"))
        return 5
    except RequestError as error:
        emit(event("fatal", kind="request", message=str(error)))
        return 4
    except Unsupported2SAError:
        emit(event("fatal", kind="unsupported_2sa", message="Legacy Apple two-step verification is unsupported. Enable two-factor authentication or use the local Photos source."))
        return 4
    except MFADeliveryError:
        emit(event("fatal", kind="mfa_delivery", message="Could not send verification code. Try again."))
        return 3
    except Exception as error:
        if type(error).__name__ == "PyiCloudServiceNotActivatedException":
            # 2026-10-15: The live Apple check returned CheckIndexingState
            # before FINISHED; the library can become available on a retry.
            emit(event("fatal", kind="icloud_unavailable", message="iCloud Photos is still preparing the library or web access is unavailable. Try again later."))
            return 3
        kind = "auth" if _is_auth_error(error) or isinstance(error, GoogleAuthError) else "network" if _is_network_error(error) else "internal"
        # 2026-10-15: HTTP exceptions can include account data and headers;
        # a fixed message keeps those values out of protocol output.
        emit(event("fatal", kind=kind, message={"auth": "iCloud or Google Photos sign-in expired or failed",
                                                 "network": "Could not reach iCloud or Google Photos",
                                                 "internal": "Backup could not continue"}[kind]))
        return {"auth": 2, "network": 3, "internal": 1}[kind]


def quiet_logging() -> None:
    """Nothing a provider logs reaches stdout or stderr.

    Only ERROR records are made at all (issue #60): gpmc logs a failed file's
    reason at ERROR, and gpmc_bridge.FailureLog reads there the HTTP status
    that tells Google's 429 apart. With every record disabled, as before, a
    rate limit looked like any other failure. The root logger's only handler
    writes nothing, which also makes gpmc's own basicConfig (a RichHandler)
    a no-op, and lastResort is cleared so an unhandled record is dropped.
    """
    logging.disable(logging.WARNING)
    logging.getLogger().handlers[:] = [logging.NullHandler()]
    logging.lastResort = None


def main() -> int:
    # 2026-10-15: gpmc uses stdout for rich progress, which corrupts NDJSON;
    # provider logs stay out of every output because exception reprs may
    # include auth values.
    quiet_logging()
    saved = os.dup(1)
    os.dup2(2, 1)
    protocol = os.fdopen(saved, "w", encoding="utf-8", buffering=1)

    def emit(value: dict[str, Any]) -> None:
        protocol.write(json.dumps(value, separators=(",", ":")) + "\n")
        protocol.flush()

    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(StopRequested()))
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, lambda *_: (_ for _ in ()).throw(StopRequested()))
    try:
        try:
            request = json.loads(sys.stdin.read())
        except ValueError:
            emit(event("fatal", kind="request", message="stdin must contain JSON"))
            return 4
        code = run(request, emit)
    finally:
        protocol.close()
    if threading.active_count() > 1:
        # Uploads abandoned by a stop or a fatal error may still be running in
        # worker threads (gpmc's own executor threads are not daemons), and a
        # normal exit would wait for each. The ledger and the session files
        # were saved before run() returned.
        sys.stderr.flush()
        os._exit(code)
    return code


if __name__ == "__main__":
    sys.exit(main())
