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
import shutil
import signal
import sqlite3
import sys
import tempfile
import time
import uuid
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


def _download(asset: Any, session: Any, version: Any, destination: Path, max_bytes: int) -> None:
    size = getattr(version, "size", None)
    if not isinstance(size, int) or size <= 0 or size > max_bytes:
        raise ValueError("original exceeds staging limit or has unknown size")
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


def google_upload(auth_data: str, item: dict[str, str]) -> tuple[str, str]:
    import gpmc_bridge

    results: list[dict[str, Any]] = []
    code = gpmc_bridge.run({"command": "upload", "auth_data": auth_data, "items": [item]}, results.append)
    confirmed = next((e for e in results if e["type"] == "item"), None)
    if code != 0 or confirmed is None:
        failure = next((e for e in results if e["type"] in ("fatal", "item_failed")), None)
        raise RuntimeError((failure or {}).get("kind", "upload_failed"))
    return confirmed["media_key"], confirmed["status"]


def check_google(auth_data: str) -> None:
    import gpmc_bridge

    results: list[dict[str, Any]] = []
    code = gpmc_bridge.run({"command": "check-auth", "auth_data": auth_data}, results.append)
    if code != 0 or not any(e["type"] == "auth" for e in results):
        raise GoogleAuthError()


def _backup(request: dict[str, Any], state: Path, emit: Callable[[dict[str, Any]], None],
            factory: Callable[[str, str | None, Path], Any],
            upload: Callable[[str, dict[str, str]], tuple[str, str]]) -> int:
    account = required(request, "account")
    auth_data = required(request, "auth_data")
    automatic_reclaim = request.get("reclaim_after_backup", False)
    if type(automatic_reclaim) is not bool or (automatic_reclaim and request.get("confirm_recently_deleted") is not True):
        raise RequestError("automatic reclaim requires explicit Recently Deleted confirmation")
    reclaim_ids: list[str] = []
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
    if upload is google_upload:
        check_google(auth_data)
    with session_directory(state, account) as cookies:
        service = factory(account, None, cookies)
        if auth_status(service) != "signed_in":
            emit(event("auth", status="signed_out", account=account))
            return 2
        with contextlib.closing(_ledger(state, account, google_account)) as ledger:
            counts = {"uploaded": 0, "existing": 0, "failed": 0}
            completed = 0
            album = service.photos.all
            total = len(album)
            for asset in album:
                if max_items is not None and completed >= max_items:
                    break
                component_results = []
                original_media_key = None
                try:
                    for name, version, filename in _components(asset):
                        key = (asset.id, name, str(version.checksum))
                        row = ledger.execute("SELECT media_key FROM confirmed WHERE asset_id=? AND version=? AND checksum=?", key).fetchone()
                        if row:
                            component_results.append("existing")
                            if name == "original":
                                original_media_key = row[0]
                            continue
                        with tempfile.TemporaryDirectory(prefix="asset-", dir=staging) as folder:
                            safe_name = Path(filename.replace("\\", "/")).name
                            if safe_name in ("", ".", ".."):
                                raise ValueError("invalid original filename")
                            destination = Path(folder) / safe_name
                            _download(asset, service.session, version, destination, max_bytes)
                            created = getattr(asset, "asset_date", None)
                            if created is not None:
                                with contextlib.suppress(ValueError, OverflowError, OSError):
                                    timestamp = created.timestamp()
                                    os.utime(destination, (timestamp, timestamp))
                            media_key, status = upload(auth_data, {"id": asset.id + ":" + name,
                                                              "path": str(destination), "filename": filename})
                            if not media_key:
                                raise RuntimeError("upload_failed")
                            with ledger:
                                ledger.execute("INSERT OR REPLACE INTO confirmed VALUES (?, ?, ?, ?, ?)",
                                               (*key, media_key, status))
                            component_results.append(status)
                            if name == "original":
                                original_media_key = media_key
                    status = "uploaded" if "uploaded" in component_results else "existing"
                    counts[status] += 1
                    emit(event("item", id=asset.id, status=status, media_key=original_media_key))
                    emit(event("source_asset", id=asset.id, filename=str(asset.filename)))
                    reclaim_ids.append(asset.id)
                except (StopRequested, KeyboardInterrupt):
                    raise
                except Exception as error:
                    counts["failed"] += 1
                    emit(event("item_failed", id=asset.id, code=_failure_code(error), retryable=True))
                completed += 1
                emit(event("progress", completed=completed, total=total, **counts))
            emit(event("done", **counts, pending=max(0, total - completed) + counts["failed"]))
    if automatic_reclaim and reclaim_ids:
        preview_events: list[dict[str, Any]] = []
        code = _reclaim(dict(request, command="reclaim-preview", asset_ids=reclaim_ids), state, preview_events.append, factory)
        preview = next((e for e in preview_events if e["type"] == "reclaim_preview"), None)
        if code or not preview or preview["count"] != len(reclaim_ids):
            emit(event("reclaim_done", soft_deleted=0, retained=len(reclaim_ids), uncertain=0, immediate_space_recovery=False))
            return 1
        return _reclaim(dict(request, command="reclaim", preview_token=preview["token"]), state, emit, factory)
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

def _failure_code(error: Exception) -> str:
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
                return _backup(request, state, emit, factory, upload)
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


def main() -> int:
    # 2026-10-15: gpmc uses stdout for rich progress, which corrupts NDJSON;
    # suppress provider logs because exception reprs may include auth values.
    logging.disable(logging.CRITICAL)
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
        return run(request, emit)
    finally:
        protocol.close()


if __name__ == "__main__":
    sys.exit(main())
