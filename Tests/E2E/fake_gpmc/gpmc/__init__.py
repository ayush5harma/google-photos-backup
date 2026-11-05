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
  "refuse_accounts": ["<email>"] sign-ins for these accounts answer 403
  "network": {...}               a simulated link, for measuring throughput;
                                 every key optional, seconds and MB/s:
      "startup"      importing gpmc (once per bridge process)
      "auth"         Google's answer to a sign-in (once per client, cached
                     like gpmc's bearer token)
      "rtt"          every call's round trip
      "handshake"    opening a connection (TCP + TLS), paid by every call
                     made on a session that has not connected yet
      "commit"       Google's extra time to commit an upload
      "link_mb_s"    the uplink, shared by every upload in the process
      "stream_mb_s"  the most one connection carries
  "per_account": true            each account (the credential's Email) holds
                                 its own media and albums, as separate Google
                                 accounts do, under "accounts" in the ledger

Like gpmc 0.9.0, every call goes through `with self.api._new_session() as s:`
and a session's close() ends its connection, so the bridge's kept sessions
change what a run costs here exactly as they would against Google.

Ledger (JSON, written under an exclusive file lock):
  {"media": {"<sha1 hex>": "<media key>"},
   "counters": {"uploads": n, "auth": n, "<file name>": attempts},
   "uploads": [{"filename", "sha1", "status": "uploaded" | "existing" | "failed", "message"?,
                "account", "saver", "use_quota", "quality", "model", "pid", "connections"}],
   "albums": {"<album id>": {"name", "media_keys": [...]}},
   "accounts": {"<email>": {"media": {...}, "albums": {...}}}}   with "per_account"
  An uploaded entry carries what gpmc 0.9.0 would commit: the flags the bridge
  passed, and the quality and device model Client._upload_file derives from
  them ("original" / "Pixel XL" is the free path). "connections" counts the
  connections the process had opened by then. Every entry records the account,
  so a test can prove each account goes up as Original quality.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import logging
import os
import threading
import time
import urllib.parse
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

SCENARIO_ENV = "FAKE_GPMC_SCENARIO"
AUTH_URL = "https://android.googleapis.com/auth"
UPLOAD_URL = "https://photos.googleapis.com/data/upload/uploadmedia/interactive"
COMMIT_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752"
ALBUM_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/484917746253879292"
MB = 1024 * 1024

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


def _network() -> dict[str, float]:
    return _scenario().get("network") or {}


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


def _email(auth_data: str) -> str:
    """The Email field of an auth_data string."""
    for pair in auth_data.split("&"):
        name, _, value = pair.partition("=")
        if name == "Email":
            return urllib.parse.unquote_plus(value)
    return ""


def _space(data: dict[str, Any], scenario: dict[str, Any], account: str) -> dict[str, Any]:
    """Where this account's media and albums live: the ledger itself, or with
    "per_account" a Google account of its own."""
    if not scenario.get("per_account"):
        return data
    space = data.setdefault("accounts", {}).setdefault(account or "unknown", {})
    space.setdefault("media", {})
    space.setdefault("albums", {})
    return space


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


class _Link:
    """The uplink every upload in this process shares, first come first
    served in 256 KB slices, each connection held to its own top speed."""

    SLICE = 256 * 1024

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._free_at = 0.0

    def send(self, size: int, link_rate: float, stream_rate: float) -> None:
        left = size
        while left > 0:
            part = min(self.SLICE, left)
            now = time.monotonic()
            with self._lock:
                start = max(now, self._free_at)
                self._free_at = start + part / link_rate
                link_done = self._free_at
            done = max(link_done, now + part / stream_rate)
            time.sleep(max(0.0, done - time.monotonic()))
            left -= part


_LINK = _Link()
_connections = [0]
# Not _lock: the ledger holds that one, and an upload's entry reads this.
_connections_lock = threading.Lock()


def _opened() -> int:
    with _connections_lock:
        _connections[0] += 1
        return _connections[0]


def _connections_so_far() -> int:
    with _connections_lock:
        return _connections[0]


class Session:
    """Shaped like the requests.Session gpmc's Api._new_session returns."""

    def __init__(self) -> None:
        self.cookies: dict[str, str] = {}
        self.headers: dict[str, str] = {}
        self.adapters: dict[str, Any] = {}
        self.verify = True
        self.trust_env = True
        self.connected = False

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *exc: Any) -> bool:
        self.close()
        return False

    def close(self) -> None:
        self.connected = False

    def call(self, upload_bytes: int = 0, server: float = 0.0) -> None:
        """One request on this session's connection, timed by the scenario."""
        net = _network()
        if not self.connected:
            _opened()
            self.connected = True
            time.sleep(float(net.get("handshake", 0)))
        time.sleep(float(net.get("rtt", 0)) + server)
        if upload_bytes and net.get("link_mb_s"):
            link = float(net["link_mb_s"]) * MB
            _LINK.send(upload_bytes, link, float(net.get("stream_mb_s", net["link_mb_s"])) * MB)


if _network().get("startup"):
    # What importing gpmc, requests, rich and blackboxprotobuf costs.
    time.sleep(float(_network()["startup"]))


class Api:
    def __init__(self, auth_data: str) -> None:
        self.auth_data = auth_data
        self.account = _email(auth_data)
        self.model = "Pixel XL"
        self.make = "Google"
        self._token: str | None = None

    def _new_session(self) -> Session:
        return Session()

    @property
    def bearer_token(self) -> str:
        # gpmc keeps the token until it expires, so a client signs in once.
        if self._token:
            return self._token
        scenario = _scenario()
        auth = scenario.get("auth", "ok")
        with _ledger(scenario) as data:
            attempt = _count(data, "auth")
        with self._new_session() as session:
            session.call(server=float(_network().get("auth", 0)))
        if attempt <= scenario.get("auth_rate_limit_first", 0) or auth == "rate_limit":
            raise _error("429", AUTH_URL)
        if auth == "refuse" or self.account in scenario.get("refuse_accounts", []):
            raise _error("403", AUTH_URL)
        if auth == "network":
            raise ConnectionError("HTTPSConnectionPool(host='android.googleapis.com', port=443): Max retries exceeded")
        if auth == "no_token":
            raise RuntimeError("Auth response does not contain bearer token")
        self._token = "fake-bearer"
        return self._token

    def add_media_to_album(self, album_media_key: str, media_keys: list[str]) -> dict:
        # gpmc 0.9.0 appends to an existing album here, not on Client.
        with self._new_session() as session:
            session.call()
        _album(media_keys, album_id=album_media_key, account=self.account)
        return {}

    def create_album(self, album_name: str, media_keys: list[str]) -> str:
        with self._new_session() as session:
            session.call()
        return _album(media_keys, name=album_name, account=self.account)

    def get_download_urls(self, media_key: str) -> dict:
        # Read-only, as the bridge uses it to tell a dead key from a refusing
        # album: a key in dead_media_keys answers 404 like an album call.
        with self._new_session() as session:
            session.call()
        if media_key in _scenario().get("dead_media_keys", []):
            raise _error("404", "https://photosdata-pa.googleapis.com/$rpc/PhotosPrepareDownload")
        return {"1": {"5": {"2": {"6": f"https://lh3.googleusercontent.com/fake/{media_key}=d"}}}}

    def find_remote_media_by_hash(self, sha1_hash: bytes) -> str | None:
        with self._new_session() as session:
            session.call()
        scenario = _scenario()
        with _ledger(scenario) as data:
            return _space(data, scenario, self.account)["media"].get(sha1_hash.hex())

    def get_upload_token(self, sha_hash_b64: str, file_size: int) -> str:
        with self._new_session() as session:
            session.call()
        return f"upload-{sha_hash_b64}"

    def upload_file(self, file: Path, upload_token: str) -> dict:
        with self._new_session() as session:
            session.call(upload_bytes=Path(file).stat().st_size)
        return {"1": upload_token}

    def commit_upload(self, upload_response_decoded: dict, file_name: str, sha1_hash: bytes,
                      quality: str = "original", model: str | None = None, upload_timestamp: int | None = None) -> str:
        with self._new_session() as session:
            session.call(server=float(_network().get("commit", 0)))
        if _scenario().get("per_account"):
            # A key of the account's own: one item in two accounts has two keys.
            return "fake-" + hashlib.sha1((self.account + sha1_hash.hex()).encode()).hexdigest()[:24]
        return f"fake-{sha1_hash.hex()[:24]}"


def _sha1(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(MB), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Client:
    def __init__(self, auth_data: str = "", proxy: str = "", language: str = "", timeout: int = 60, log_level: str = "INFO") -> None:
        if "Token=" not in auth_data:
            raise ValueError("auth_data has no Token field")
        self.timeout = timeout
        self.language = language
        self.api = Api(auth_data)
        self.account = self.api.account

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
                results.update(self._upload_file(path, filename, force_upload, saver, use_quota, progress_callback))
            except Exception as error:
                # gpmc 0.9.0 reports a failed file only like this: a progress
                # event with phase "error" and one logged line.
                if progress_callback:
                    progress_callback(self._event("error", path, filename, 0))
                _logger.error(f"Error uploading file {path}: {error}")
                with _ledger(_scenario()) as data:
                    data["uploads"].append({"filename": filename, "status": "failed", "message": str(error),
                                            "account": self.account, "saver": saver, "use_quota": use_quota})
        return results

    def _upload_file(self, path: Path, filename: str, force: bool, saver: bool, use_quota: bool,
                     progress: Callable[[dict[str, Any]], None] | None) -> dict[str, str]:
        tags = {"account": self.account, "saver": saver, "use_quota": use_quota}
        scenario = _scenario()
        report = (lambda phase, done: progress(self._event(phase, path, filename, done))) if progress else (lambda *_: None)
        size = path.stat().st_size
        sha1 = _sha1(path)
        report("hashing", size)
        if scenario.get("delay"):
            time.sleep(float(scenario["delay"]))

        if not force:
            report("checking", 0)
            if key := self.api.find_remote_media_by_hash(bytes.fromhex(sha1)):
                with _ledger(scenario) as data:
                    data["uploads"].append({"filename": filename, "sha1": sha1, "status": "existing", **tags})
                report("skipped", size)
                return {path.absolute().as_posix(): key}
        with _ledger(scenario) as data:
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

        token = self.api.get_upload_token(sha1, size)
        report("uploading", 0)
        uploaded = self.api.upload_file(path, token)
        report("uploading", size)
        report("finalizing", size)
        # gpmc 0.9.0's Client._upload_file, word for word in effect: these two
        # flags are all that decide the quality and model of the commit.
        model, quality = "Pixel XL", "original"
        if saver:
            quality, model = "saver", "Pixel 2"
        if use_quota:
            model = "Pixel 8"
        media_key = self.api.commit_upload(uploaded, filename, bytes.fromhex(sha1), quality=quality, model=model)
        with _ledger(scenario) as data:
            _space(data, scenario, self.account)["media"][sha1] = media_key
            data["uploads"].append({"filename": filename, "sha1": sha1, "status": "uploaded", **tags,
                                    "quality": quality, "model": model,
                                    "pid": os.getpid(), "connections": _connections_so_far()})
        report("complete", size)
        return {path.absolute().as_posix(): media_key}

    @staticmethod
    def _event(phase: str, path: Path, filename: str, done: int) -> dict[str, Any]:
        total = path.stat().st_size if path.exists() else 0
        return {"version": 1, "type": "progress", "operation": "upload", "phase": phase, "path": path.absolute().as_posix(),
                "filename": filename, "bytes_completed": done, "bytes_total": total}

    def add_to_album(self, media_keys: list[str], album_name: str, show_progress: bool) -> list[str]:
        return [self.api.create_album(album_name, media_keys)]


def _album(media_keys: list[str], name: str | None = None, album_id: str | None = None, account: str = "") -> str:
    scenario = _scenario()
    if scenario.get("album_error"):
        raise RuntimeError(scenario["album_error"])
    if set(media_keys) & set(scenario.get("dead_media_keys", [])):
        raise _error("404", ALBUM_URL)
    with _ledger(scenario) as data:
        albums = _space(data, scenario, account)["albums"]
        if album_id is None:
            prefix = f"fake-album-{account}-" if scenario.get("per_account") else "fake-album-"
            album_id = f"{prefix}{len(albums) + 1}"
            albums[album_id] = {"name": name, "media_keys": []}
        album = albums.setdefault(album_id, {"name": name, "media_keys": []})
        album["media_keys"] += [key for key in media_keys if key not in album["media_keys"]]
    return album_id
