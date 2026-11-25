#!/usr/bin/env python3
"""Write Tests/PhotosBackupCoreTests/GooglePhotosGolden.swift from gpmc 0.9.0 itself.

The Swift client (Sources/PhotosBackupCore/GooglePhotos) must send exactly
what gpmc 0.9.0 and the bridge's CommitBatcher send. This script runs the
real gpmc Api methods and the bridge's own _commit_body for fixed inputs,
with requests' session swapped for a recorder (no network) and time.time
pinned, and prints every request body and header set as Swift constants.

Run with the interpreter the Mac app ships, which has gpmc 0.9.0 and
blackboxprotobuf; -I keeps the user's site-packages out, so the bundle's
site-packages is passed explicitly and only read:

    "/Applications/Photos Backup.app/Contents/Resources/python/bin/python3.13" -I \\
        scripts/tests/make_gpmc_golden.py \\
        --site-packages "/Applications/Photos Backup.app/Contents/Resources/bridge/site-packages" \\
        > Tests/PhotosBackupCoreTests/GooglePhotosGolden.swift
"""

from __future__ import annotations

import argparse
import base64
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SITE_PACKAGES = "/Applications/Photos Backup.app/Contents/Resources/bridge/site-packages"

# Fixed inputs. Names carry non-ASCII so UTF-8 and quote_plus are exercised;
# the receipts' field 2 is bytes that are neither UTF-8 nor protobuf, so
# blackboxprotobuf decodes it as bytes, as it does Google's real upload token.
NOW = 1_767_225_600  # 2026-01-01T00:00:00Z, gpmc's int(time.time()) for albums
SHA1_A = bytes(range(1, 21))
SHA1_B = bytes(range(101, 121))
RECEIPT_A = bytes([0x08, 0x07, 0x12, 0x06, 0xFF, 0xFE, 0x80, 0x41, 0x42, 0x43])
RECEIPT_B = bytes([0x08, 0x09, 0x12, 0x05, 0xFE, 0xFF, 0x81, 0x44, 0x45])
FILE_A = ("Café IMG_0001.HEIC", 1_700_000_000, 123_456)
FILE_B = ("IMG_0002.MOV", 1_600_000_123, 9_876_543_210)
ALBUM_NAME = "Trips – Jibhi 2026"
ALBUM_KEY = "AF1QipAlbumKey0001"
MEDIA_KEYS = ["AF1QipKeyOne", "AF1QipKeyTwo", "AF1QipKeyThree"]
UPLOAD_ID = "fake-upload-id_42"
AUTH_DATA = (
    "androidId=3a1b2c3d4e5f6071&app=com.google.android.apps.photos&callerPkg=com.google.android.apps.photos"
    "&callerSig=38918a453d07199354f8b19af05ec6562ced5788&client_sig=38918a453d07199354f8b19af05ec6562ced5788"
    "&device_country=us&Email=first.last%2Btag%40gmail.com&google_play_services_version=240913000&lang=en_US"
    "&oauth2_foreground=1&operatorCountry=us&sdk_version=33"
    "&service=oauth2%3Ahttps%3A%2F%2Fwww.googleapis.com%2Fauth%2Fphotos.native&source=android"
    "&Token=aas_et%2FAKppINa+fake%2Ftoken%3D%3D"
)
# The quality name, and the (model, quality) gpmc's Client._upload_file
# passes to commit_upload for it.
QUALITIES = {"original": ("Pixel XL", "original"), "saver": ("Pixel 2", "saver"), "quota": ("Pixel 8", "original")}


class Recorded:
    def __init__(self, method: str, url: str, headers: dict[str, str], data: Any) -> None:
        self.method, self.url, self.headers = method, url, dict(headers)
        if hasattr(data, "read"):
            data = data.read()
        if isinstance(data, dict):
            # requests form-encodes a dict body with urlencode, which is the
            # body the Swift client must write.
            from urllib.parse import urlencode
            data = urlencode(data).encode()
        self.body = bytes(data or b"")


class FakeResponse:
    def __init__(self, content: bytes, headers: dict[str, str] | None = None, text: str = "") -> None:
        self.content, self.headers, self.text, self.status_code = content, headers or {}, text, 200

    def raise_for_status(self) -> None:
        return None


class Recorder:
    """Stands in for requests.Session: records each call, answers it."""

    def __init__(self) -> None:
        self.calls: list[Recorded] = []
        self.answers: list[FakeResponse] = []

    def __call__(self) -> Recorder:
        return self

    def __enter__(self) -> Recorder:
        return self

    def __exit__(self, *_: Any) -> None:
        return None

    def _answer(self, method: str, url: str, headers: dict[str, str], data: Any) -> FakeResponse:
        self.calls.append(Recorded(method, url, headers, data))
        return self.answers.pop(0)

    def post(self, url: str, headers: dict[str, str], data: Any, timeout: int) -> FakeResponse:
        return self._answer("POST", url, headers, data)

    def put(self, url: str, headers: dict[str, str], data: Any, timeout: int) -> FakeResponse:
        return self._answer("PUT", url, headers, data)

    def last(self) -> Recorded:
        return self.calls[-1]


def load(site_packages: str) -> tuple[Any, Any, Any]:
    sys.path.insert(0, site_packages)
    sys.path.insert(0, str(REPO / "Bridge"))
    import blackboxprotobuf  # noqa: F401  (fail early without it)
    import gpmc
    from gpmc import api as gpmc_api
    import gpmc_bridge
    version = getattr(gpmc, "__version__", None)
    if version not in (None, "0.9.0"):
        raise SystemExit(f"expected gpmc 0.9.0, found {version}")
    return gpmc_api, gpmc_bridge, blackboxprotobuf


def record(site_packages: str) -> tuple[list[tuple[str, Recorded]], dict[str, bytes]]:
    gpmc_api, bridge, bbp = load(site_packages)

    class PinnedTime:
        @staticmethod
        def time() -> float:
            return NOW + 0.75  # the fraction must be dropped, as int() does

    gpmc_api.time = PinnedTime  # gpmc.api calls time.time() for album stamps
    recorder = Recorder()
    api = gpmc_api.Api(AUTH_DATA)
    api._new_session = recorder  # type: ignore[method-assign]
    out: list[tuple[str, Recorded]] = []
    extra: dict[str, bytes] = {}

    recorder.answers.append(FakeResponse(b"", text=f"Auth=fake-bearer\nExpiry={NOW + 3600}\n"))
    api.auth_response_cache = api._get_auth_token()
    out.append(("auth", recorder.last()))

    recorder.answers.append(FakeResponse(bytes([0x0A, 0x00])))
    api.find_remote_media_by_hash(SHA1_A)
    out.append(("findRemoteMedia", recorder.last()))

    recorder.answers.append(FakeResponse(b"", headers={"X-GUploader-UploadID": UPLOAD_ID}))
    api.get_upload_token(base64.b64encode(SHA1_A).decode(), FILE_A[2])
    out.append(("uploadStart", recorder.last()))

    decoded: dict[bytes, Any] = {}
    for receipt in (RECEIPT_A, RECEIPT_B):
        recorder.answers.append(FakeResponse(receipt))
        decoded[receipt] = api.upload_file(b"file bytes", UPLOAD_ID)
    out.append(("uploadPut", recorder.last()))

    for name, (model, quality) in QUALITIES.items():
        recorder.answers.append(FakeResponse(_commit_answer(bbp)))
        api.commit_upload(upload_response_decoded=decoded[RECEIPT_A], file_name=FILE_A[0], sha1_hash=SHA1_A,
                          upload_timestamp=FILE_A[1], model=model, quality=quality)
        out.append((f"commitOne_{name}", recorder.last()))

        # The bridge's batched body, built by its own _commit_body from the
        # kwargs gpmc's Client hands commit_upload (CommitBatcher.commit_upload).
        commits = []
        for receipt, (file_name, stamp, _size), sha1 in ((RECEIPT_A, FILE_A, SHA1_A), (RECEIPT_B, FILE_B, SHA1_B)):
            commits.append(bridge._Commit({"upload_response_decoded": decoded[receipt], "file_name": file_name,
                                           "sha1_hash": sha1, "upload_timestamp": stamp, "model": model,
                                           "quality": quality}))
        extra[f"commitBatch_{name}"] = bridge._commit_body(api, bridge._codec(api), commits)

    recorder.answers.append(FakeResponse(bytes([0x0A, 0x14, 0x0A, 0x12]) + ALBUM_KEY.encode()))
    api.create_album(ALBUM_NAME, MEDIA_KEYS)
    out.append(("createAlbum", recorder.last()))

    recorder.answers.append(FakeResponse(b""))
    api.add_media_to_album(ALBUM_KEY, MEDIA_KEYS)
    out.append(("addToAlbum", recorder.last()))
    return out, extra


def _commit_answer(bbp: Any) -> bytes:
    return bytes(bbp.encode_message({"1": {"3": {"1": "AF1QipCommitted"}}},
                                    {"1": {"type": "message", "message_typedef": {"3": {"type": "message", "message_typedef": {"1": {"type": "string"}}}}}}))


def swift_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit(calls: list[tuple[str, Recorded]], extra: dict[str, bytes], site_packages: str) -> str:
    lines = [
        "// Generated by scripts/tests/make_gpmc_golden.py from gpmc 0.9.0 and the bridge's",
        "// CommitBatcher body builder; do not edit by hand. Regenerate with:",
        '//   "/Applications/Photos Backup.app/Contents/Resources/python/bin/python3.13" -I \\',
        "//     scripts/tests/make_gpmc_golden.py \\",
        '//     --site-packages "/Applications/Photos Backup.app/Contents/Resources/bridge/site-packages" \\',
        "//     > Tests/PhotosBackupCoreTests/GooglePhotosGolden.swift",
        "",
        "import Foundation",
        "",
        "enum GooglePhotosGolden {",
        f"    static let now: TimeInterval = {NOW}.75",
        f"    static let authData = {swift_string(AUTH_DATA)}",
        f"    static let sha1A = \"{SHA1_A.hex()}\"",
        f"    static let sha1B = \"{SHA1_B.hex()}\"",
        f"    static let receiptA = \"{RECEIPT_A.hex()}\"",
        f"    static let receiptB = \"{RECEIPT_B.hex()}\"",
        f"    static let fileA = (name: {swift_string(FILE_A[0])}, timestamp: {FILE_A[1]}, size: Int64({FILE_A[2]}))",
        f"    static let fileB = (name: {swift_string(FILE_B[0])}, timestamp: {FILE_B[1]}, size: Int64({FILE_B[2]}))",
        f"    static let albumName = {swift_string(ALBUM_NAME)}",
        f"    static let albumKey = {swift_string(ALBUM_KEY)}",
        f"    static let mediaKeys = [{', '.join(swift_string(k) for k in MEDIA_KEYS)}]",
        f"    static let uploadID = {swift_string(UPLOAD_ID)}",
        "",
        "    struct Call {",
        "        let method: String",
        "        let url: String",
        "        let headers: [String: String]",
        "        let body: String",
        "    }",
        "",
        "    /// Each request gpmc made, by name: method, URL, headers (Authorization",
        "    /// is gpmc's \"Bearer fake-bearer\"), body as hex.",
        "    static let calls: [String: Call] = [",
    ]
    for name, call in calls:
        headers = ", ".join(f"{swift_string(k)}: {swift_string(v)}" for k, v in sorted(call.headers.items()))
        lines.append(f"        {swift_string(name)}: Call(")
        lines.append(f"            method: {swift_string(call.method)},")
        lines.append(f"            url: {swift_string(call.url)},")
        lines.append(f"            headers: [{headers}],")
        lines.append(f"            body: \"{call.body.hex()}\"")
        lines.append("        ),")
    lines.append("    ]")
    lines.append("")
    lines.append("    /// Bodies the bridge's _commit_body built for a 2-item batch (A, B), per quality.")
    lines.append("    static let batchBodies: [String: String] = [")
    for name, body in extra.items():
        lines.append(f"        {swift_string(name)}: \"{body.hex()}\",")
    lines.append("    ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--site-packages", default=DEFAULT_SITE_PACKAGES)
    args = parser.parse_args()
    calls, extra = record(args.site_packages)
    sys.stdout.write(emit(calls, extra, args.site_packages))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
