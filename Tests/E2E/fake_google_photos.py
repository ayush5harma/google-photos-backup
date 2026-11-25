#!/usr/bin/env python3
"""A fake Google Photos for end-to-end runs of the native client.

Serves every endpoint at the paths GooglePhotosEndpoints.local(base) uses,
speaking the same protobuf as gpmc 0.9.0 and Google, so the iOS app (or any
GooglePhotosClient) can back up to it in the simulator:

    python3 -I Tests/E2E/fake_google_photos.py --port 8765 --log /tmp/fake-google.jsonl

It keeps an in-memory library, so a second run dedupes by hash. Standard
library only; binds 127.0.0.1 and nothing else. Each request is logged as
one JSON line: path, method, query, headers without Authorization, status
and a decoded summary of the body. GET /_state answers the library and the
albums as JSON, for a test to check what was committed.
"""

from __future__ import annotations

import argparse
import hashlib
import base64
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit

DATA_ROOT = "/6439526531001121323/"
UPLOAD_PATH = "/data/upload/uploadmedia/interactive"
METHODS = {
    "5084965799730810217": "find_remote_media_by_hash",
    "16538846908252377752": "commit_upload",
    "8386163679468898444": "create_album",
    "484917746253879292": "add_media_to_album",
}
BEARER = "fake-bearer"


# --- protobuf wire format, as much as these calls use ---------------------

def varint(value: int) -> bytes:
    value &= (1 << 64) - 1
    out = bytearray()
    while value > 0x7F:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def field_int(number: int, value: int) -> bytes:
    return varint(number << 3) + varint(value)


def field_bytes(number: int, value: bytes) -> bytes:
    return varint(number << 3 | 2) + varint(len(value)) + value


def decode(data: bytes) -> list[tuple[int, Any]]:
    """Every (field, value) of one message level; ValueError if malformed."""
    fields: list[tuple[int, Any]] = []
    index = 0

    def read_varint() -> int:
        nonlocal index
        value, shift = 0, 0
        while True:
            if index >= len(data) or shift > 63:
                raise ValueError("truncated varint")
            byte = data[index]
            index += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value
            shift += 7

    while index < len(data):
        key = read_varint()
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError("field 0")
        if wire == 0:
            fields.append((number, read_varint()))
        elif wire == 2:
            length = read_varint()
            if index + length > len(data):
                raise ValueError("length past the end")
            fields.append((number, data[index:index + length]))
            index += length
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if index + size > len(data):
                raise ValueError("fixed field cut short")
            fields.append((number, data[index:index + size]))
            index += size
        else:
            raise ValueError(f"wire type {wire}")
    return fields


def first(data: bytes, number: int) -> Any:
    return next((value for field, value in decode(data) if field == number), None)


def every(data: bytes, number: int) -> list[Any]:
    return [value for field, value in decode(data) if field == number]


def at(data: bytes, *path: int) -> Any:
    current: Any = data
    for number in path:
        if not isinstance(current, bytes):
            return None
        current = first(current, number)
        if current is None:
            return None
    return current


def text(value: Any) -> str | None:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else None


# --- the fake ----------------------------------------------------------------

class FakeGooglePhotos:
    """The library and the knobs; every handler thread shares one."""

    def __init__(self, existing: list[bytes] | None = None, fail_batch: bool = False, rate_limit_first: int = 0,
                 log_path: str | None = None) -> None:
        self.lock = threading.Lock()
        self.library: dict[bytes, str] = {}  # sha1 -> media key
        for sha1 in existing or []:
            self.library[sha1] = self.media_key(sha1)
        self.uploads: dict[str, dict[str, Any]] = {}  # upload id -> declared sha1/size, then receipt
        self.receipts: dict[bytes, dict[str, Any]] = {}  # upload token -> the upload
        self.albums: dict[str, dict[str, Any]] = {}
        self.fail_batch = fail_batch
        self.rate_limit_left = rate_limit_first
        self.counter = 0
        self.log_file = open(log_path, "a", encoding="utf-8") if log_path else None

    @staticmethod
    def media_key(sha1: bytes) -> str:
        return "AF1QipFAKE" + sha1.hex()[:30].upper()

    def next_id(self) -> int:
        self.counter += 1
        return self.counter

    def log(self, entry: dict[str, Any]) -> None:
        if self.log_file is None:
            return
        with self.lock:
            self.log_file.write(json.dumps(entry, sort_keys=True) + "\n")
            self.log_file.flush()

    def close(self) -> None:
        if self.log_file is not None:
            self.log_file.close()
            self.log_file = None

    def state(self) -> dict[str, Any]:
        with self.lock:
            return {"library": {sha1.hex(): key for sha1, key in self.library.items()},
                    "albums": {key: {"name": album["name"], "media_keys": list(album["media_keys"])}
                               for key, album in self.albums.items()}}

    # Each handler returns (status, body, extra headers, summary).

    def auth(self, form: dict[str, list[str]]) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        missing = [name for name in ("androidId", "Email", "Token", "service", "app") if not form.get(name)]
        summary = {"fields": sorted(form), "email": (form.get("Email") or [""])[0]}
        if missing:
            return 403, b"Error=BadAuthentication\n", {}, {**summary, "missing": missing}
        return 200, f"Auth={BEARER}\nExpiry={int(time.time()) + 3600}\n".encode(), {}, summary

    def data_call(self, method: str, body: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        with self.lock:
            if self.rate_limit_left > 0:
                self.rate_limit_left -= 1
                status = field_int(1, 8) + field_bytes(2, b"Too many requests")
                return 429, status, {}, {"rate_limited": True}
        handler = getattr(self, method)
        return handler(body)

    def find_remote_media_by_hash(self, body: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        sha1 = at(body, 1, 1, 1)
        if not isinstance(sha1, bytes) or len(sha1) != 20:
            return 400, b"bad hash lookup", {}, {"error": "no 20-byte hash at 1.1.1"}
        with self.lock:
            key = self.library.get(sha1)
        answer = field_bytes(1, field_bytes(2, field_bytes(2, field_bytes(1, key.encode())))) if key else field_bytes(1, b"")
        return 200, answer, {}, {"sha1": sha1.hex(), "match": key}

    def start_upload(self, headers: Any) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        digest = (headers.get("X-Goog-Hash") or "").removeprefix("sha1=")
        length = headers.get("X-Upload-Content-Length") or ""
        try:
            sha1 = base64.b64decode(digest, validate=True)
            size = int(length)
        except ValueError:
            return 400, b"missing X-Goog-Hash or X-Upload-Content-Length", {}, {"error": "headers"}
        with self.lock:
            upload_id = f"fake-upload-{self.next_id()}"
            self.uploads[upload_id] = {"sha1": sha1, "size": size}
        return 200, b"", {"X-GUploader-UploadID": upload_id}, {"sha1": sha1.hex(), "size": size, "upload_id": upload_id}

    def put(self, upload_id: str, data: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        with self.lock:
            upload = self.uploads.get(upload_id)
            if upload is None:
                return 404, b"unknown upload_id", {}, {"error": "unknown upload_id"}
            actual = hashlib.sha1(data).digest()
            summary = {"upload_id": upload_id, "bytes": len(data), "sha1": actual.hex()}
            if len(data) != upload["size"] or actual != upload["sha1"]:
                return 400, b"bytes do not match the upload start", {}, {**summary, "error": "mismatch"}
            token = f"fake-token-{upload_id}".encode()
            number = self.next_id()
            receipt = field_int(1, number) + field_bytes(2, token)
            self.receipts[token] = {**upload, "upload_id": upload_id}
        return 200, receipt, {}, summary

    def commit_upload(self, body: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        items = every(body, 1)
        model = text(at(body, 2, 3))
        batch = len(items) > 1
        entries: list[bytes] = []
        summary_items = []
        for item in items:
            receipt = first(item, 1) or b""
            token = first(receipt, 2) if receipt else None
            sha1 = first(item, 3)
            entry = field_bytes(1, receipt) + field_int(2, 1)
            with self.lock:
                upload = self.receipts.get(token) if isinstance(token, bytes) else None
                valid = upload is not None and upload["sha1"] == sha1
                key = self.media_key(sha1) if valid and not (batch and self.fail_batch) else None
                if key:
                    self.library[sha1] = key
            if key:
                entry += field_bytes(3, field_bytes(1, key.encode()))
            entries.append(field_bytes(1, entry))
            summary_items.append({"name": text(first(item, 2)), "sha1": sha1.hex() if isinstance(sha1, bytes) else None,
                                  "timestamp": at(item, 4, 1), "quality": first(item, 7), "key": key})
        return 200, b"".join(entries), {}, {"model": model, "items": summary_items, "batch": batch}

    def create_album(self, body: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        name = text(first(body, 1)) or ""
        keys = [text(at(entry, 1, 1)) for entry in every(body, 4)]
        with self.lock:
            unknown = [key for key in keys if key not in self.library.values()]
            if unknown:
                return 404, b"media item not found", {}, {"name": name, "unknown": unknown}
            album_key = f"AF1QipALBUM{self.next_id():04d}"
            self.albums[album_key] = {"name": name, "media_keys": list(keys)}
        return 200, field_bytes(1, field_bytes(1, album_key.encode())), {}, {"name": name, "keys": keys, "album": album_key}

    def add_media_to_album(self, body: bytes) -> tuple[int, bytes, dict[str, str], dict[str, Any]]:
        album_key = text(first(body, 2)) or ""
        keys = [text(value) for value in every(body, 1)]
        with self.lock:
            album = self.albums.get(album_key)
            unknown = [key for key in keys if key not in self.library.values()]
            if album is None or unknown:
                return 404, b"album or media item not found", {}, {"album": album_key, "unknown": unknown}
            album["media_keys"].extend(key for key in keys if key not in album["media_keys"])
        return 200, b"", {}, {"album": album_key, "keys": keys}


def make_handler(fake: FakeGooglePhotos) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002  (the JSON log is the log)
            return None

        def read_body(self) -> bytes:
            if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
                chunks = []
                while True:
                    size = int(self.rfile.readline().split(b";")[0].strip(), 16)
                    if size == 0:
                        self.rfile.readline()
                        return b"".join(chunks)
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline()
            return self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def answer(self, status: int, body: bytes, headers: dict[str, str], summary: dict[str, Any]) -> None:
            self.send_response(status)
            content_type = "text/plain" if self.path.startswith("/auth") else "application/x-protobuf"
            self.send_header("Content-Type", "application/json" if self.path.startswith("/_state") else content_type)
            self.send_header("Content-Length", str(len(body)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)
            parts = urlsplit(self.path)
            fake.log({"path": parts.path, "query": parts.query, "method": self.command, "status": status,
                      "headers": {k: v for k, v in self.headers.items() if k.lower() != "authorization"},
                      "body": summary})

        def authorized(self) -> bool:
            return self.headers.get("Authorization") == f"Bearer {BEARER}"

        def do_GET(self) -> None:  # noqa: N802
            if urlsplit(self.path).path == "/_state":
                self.answer(200, json.dumps(fake.state()).encode(), {}, {})
            else:
                self.answer(404, b"", {}, {"error": "no such path"})

        def do_POST(self) -> None:  # noqa: N802
            body = self.read_body()
            path = urlsplit(self.path).path
            try:
                if path == "/auth":
                    self.answer(*fake.auth(parse_qs(body.decode(), keep_blank_values=True)))
                elif not self.authorized():
                    self.answer(401, b"", {}, {"error": "no bearer"})
                elif path == UPLOAD_PATH:
                    self.answer(*fake.start_upload(self.headers))
                elif path.startswith(DATA_ROOT) and path[len(DATA_ROOT):] in METHODS:
                    self.answer(*fake.data_call(METHODS[path[len(DATA_ROOT):]], body))
                else:
                    self.answer(404, b"", {}, {"error": "no such path"})
            except ValueError as error:
                self.answer(400, b"malformed protobuf", {}, {"error": str(error)})

        def do_PUT(self) -> None:  # noqa: N802
            body = self.read_body()
            parts = urlsplit(self.path)
            upload_id = (parse_qs(parts.query).get("upload_id") or [""])[0]
            if parts.path != UPLOAD_PATH:
                self.answer(404, b"", {}, {"error": "no such path"})
            elif not self.authorized():
                self.answer(401, b"", {}, {"error": "no bearer"})
            else:
                self.answer(*fake.put(upload_id, body))

    return Handler


def serve(fake: FakeGooglePhotos, port: int) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(fake))
    server.daemon_threads = True
    return server


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765, help="0 picks a free port")
    parser.add_argument("--log", help="append one JSON line per request here")
    parser.add_argument("--existing-sha1", action="append", default=[], metavar="HEX",
                        help="a hash the library already holds (repeatable)")
    parser.add_argument("--fail-batch", action="store_true",
                        help="batched commits answer without keys, to exercise the single-commit fallback")
    parser.add_argument("--rate-limit-first", type=int, default=0, metavar="N",
                        help="the first N photosdata calls answer 429")
    args = parser.parse_args(argv)
    fake = FakeGooglePhotos([bytes.fromhex(h) for h in args.existing_sha1], args.fail_batch, args.rate_limit_first, args.log)
    server = serve(fake, args.port)
    print(f"listening on http://127.0.0.1:{server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        fake.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
