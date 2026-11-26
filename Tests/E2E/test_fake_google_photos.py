"""Drives Tests/E2E/fake_google_photos.py the way GooglePhotosClient does.

    python3 -I -m unittest discover -s Tests/E2E -p 'test_fake_google_photos.py'
"""

from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # -I leaves the script's folder off sys.path

import fake_google_photos as fake  # noqa: E402

DATA = "/6439526531001121323/"
FIND, COMMIT, CREATE, ADD = "5084965799730810217", "16538846908252377752", "8386163679468898444", "484917746253879292"
AUTH_FORM = b"androidId=1&app=com.google.android.apps.photos&Email=a%40b.c&service=oauth2&Token=aas_et%2Fx"


class Client:
    def __init__(self, base: str) -> None:
        self.base = base

    def call(self, method: str, path: str, body: bytes = b"", headers: dict[str, str] | None = None,
             bearer: bool = True) -> tuple[int, bytes, dict[str, str]]:
        request = urllib.request.Request(self.base + path, data=body, method=method, headers=headers or {})
        if bearer:
            request.add_header("Authorization", "Bearer fake-bearer")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read(), dict(response.headers)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read(), dict(error.headers)

    def find(self, sha1: bytes) -> tuple[int, str | None]:
        body = fake.field_bytes(1, fake.field_bytes(1, fake.field_bytes(1, sha1)) + fake.field_bytes(2, b""))
        status, answer, _ = self.call("POST", DATA + FIND, body)
        return status, fake.text(fake.at(answer, 1, 2, 2, 1)) if status == 200 else None

    def upload(self, data: bytes) -> bytes:
        sha1 = hashlib.sha1(data).digest()
        status, _, headers = self.call("POST", fake.UPLOAD_PATH, fake.field_int(1, 2), {
            "X-Goog-Hash": "sha1=" + base64.b64encode(sha1).decode(), "X-Upload-Content-Length": str(len(data))})
        assert status == 200, status
        status, receipt, _ = self.call("PUT", f"{fake.UPLOAD_PATH}?upload_id={headers['X-GUploader-UploadID']}", data)
        assert status == 200, status
        return receipt

    def commit(self, items: list[tuple[bytes, bytes, str]]) -> list[str | None]:
        body = b"".join(fake.field_bytes(1, fake.field_bytes(1, receipt) + fake.field_bytes(2, name.encode())
                                         + fake.field_bytes(3, sha1) + fake.field_bytes(4, fake.field_int(1, 1700000000))
                                         + fake.field_int(7, 3) + fake.field_int(10, 1))
                        for receipt, sha1, name in items)
        body += fake.field_bytes(2, fake.field_bytes(3, b"Pixel XL")) + fake.field_bytes(3, bytes([1, 3]))
        status, answer, _ = self.call("POST", DATA + COMMIT, body)
        assert status == 200, status
        return [fake.text(fake.at(entry, 3, 1)) for entry in fake.every(answer, 1)]


class FakeGooglePhotosTests(unittest.TestCase):
    def start(self, **options: object) -> Client:
        log = tempfile.NamedTemporaryFile(suffix=".jsonl", delete=False)
        log.close()
        self.log_path = Path(log.name)
        self.addCleanup(self.log_path.unlink)
        google = fake.FakeGooglePhotos(log_path=str(self.log_path), **options)  # type: ignore[arg-type]
        self.addCleanup(google.close)
        server = fake.serve(google, 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return Client(f"http://127.0.0.1:{server.server_address[1]}")

    def test_one_upload_end_to_end_then_dedupe(self) -> None:
        client = self.start()
        status, answer, _ = client.call("POST", "/auth", AUTH_FORM, bearer=False)
        self.assertEqual(status, 200)
        self.assertIn(b"Auth=fake-bearer", answer)

        data = b"photo bytes"
        sha1 = hashlib.sha1(data).digest()
        self.assertEqual(client.find(sha1), (200, None))
        receipt = client.upload(data)
        self.assertTrue(fake.first(receipt, 2))
        [key] = client.commit([(receipt, sha1, "a.jpg")])
        self.assertTrue(key and key.startswith("AF1QipFAKE"))
        self.assertEqual(client.find(sha1), (200, key))

        status, answer, _ = client.call("POST", DATA + CREATE, fake.field_bytes(1, b"Trip")
                                        + fake.field_bytes(4, fake.field_bytes(1, fake.field_bytes(1, key.encode()))))
        album = fake.text(fake.at(answer, 1, 1))
        self.assertEqual(status, 200)
        status, _, _ = client.call("POST", DATA + ADD, fake.field_bytes(1, key.encode()) + fake.field_bytes(2, album.encode()))
        self.assertEqual(status, 200)

        state = json.loads(client.call("GET", "/_state")[1])
        self.assertEqual(state["library"], {sha1.hex(): key})
        self.assertEqual(state["albums"][album], {"name": "Trip", "media_keys": [key]})

        lines = [json.loads(line) for line in self.log_path.read_text().splitlines()]
        self.assertEqual([line["method"] for line in lines[:2]], ["POST", "POST"])
        self.assertTrue(all("Authorization" not in line["headers"] for line in lines))
        self.assertEqual(lines[0]["body"]["email"], "a@b.c")

    def test_batched_commits_echo_each_receipt(self) -> None:
        client = self.start()
        items = [(client.upload(data), hashlib.sha1(data).digest(), f"{i}.jpg") for i, data in enumerate([b"one", b"two"])]
        keys = client.commit(items)
        self.assertEqual(len(set(keys)), 2)
        self.assertTrue(all(keys))

    def test_fail_batch_answers_batches_without_keys(self) -> None:
        client = self.start(fail_batch=True)
        items = [(client.upload(data), hashlib.sha1(data).digest(), f"{i}.jpg") for i, data in enumerate([b"one", b"two"])]
        self.assertEqual(client.commit(items), [None, None])
        self.assertTrue(client.commit(items[:1])[0])

    def test_rate_limit_first_n_data_calls(self) -> None:
        client = self.start(rate_limit_first=2)
        sha1 = bytes(20)
        self.assertEqual(client.find(sha1)[0], 429)
        self.assertEqual(client.find(sha1)[0], 429)
        self.assertEqual(client.find(sha1), (200, None))

    def test_existing_hashes_dedupe_and_bad_requests_are_refused(self) -> None:
        sha1 = hashlib.sha1(b"old").digest()
        client = self.start(existing=[sha1])
        self.assertEqual(client.find(sha1), (200, fake.FakeGooglePhotos.media_key(sha1)))
        self.assertEqual(client.call("POST", DATA + FIND, b"", bearer=False)[0], 401)
        self.assertEqual(client.call("POST", DATA + FIND, b"\x0f")[0], 400)
        status, _, _ = client.call("POST", fake.UPLOAD_PATH, b"", {"X-Goog-Hash": "sha1=" + base64.b64encode(bytes(20)).decode(),
                                                                  "X-Upload-Content-Length": "3"})
        self.assertEqual(status, 200)

    def test_bytes_that_do_not_match_the_start_are_refused(self) -> None:
        client = self.start()
        status, _, headers = client.call("POST", fake.UPLOAD_PATH, b"", {
            "X-Goog-Hash": "sha1=" + base64.b64encode(hashlib.sha1(b"abc").digest()).decode(), "X-Upload-Content-Length": "3"})
        status, _, _ = client.call("PUT", f"{fake.UPLOAD_PATH}?upload_id={headers['X-GUploader-UploadID']}", b"abd")
        self.assertEqual(status, 400)

    def test_command_line_prints_its_port_and_binds_loopback(self) -> None:
        process = subprocess.Popen([sys.executable, "-I", str(HERE / "fake_google_photos.py"), "--port", "0"],
                                   stdout=subprocess.PIPE, text=True)
        self.addCleanup(process.wait)
        self.addCleanup(process.terminate)
        line = process.stdout.readline().strip() if process.stdout else ""
        self.assertRegex(line, r"^listening on http://127\.0\.0\.1:\d+$")
        process.stdout.close() if process.stdout else None
        client = Client(line.removeprefix("listening on "))
        self.assertEqual(client.call("POST", "/auth", AUTH_FORM, bearer=False)[0], 200)


if __name__ == "__main__":
    unittest.main()
