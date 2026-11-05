"""What the real gpmc 0.9.0 commits when the bridge uploads at Original quality.

Every layer is the real one -- the bridge's serve session and kept sessions,
gpmc's Client and Api, requests -- except HTTPAdapter.send, which answers like
Google and keeps every request. The commit request's protobuf is decoded with
gpmc's own message type, so these tests read the device model and quality
Google would be told, not the arguments the bridge meant to pass. Runs when
GPMC_SITE_PACKAGES points at a real gpmc install (CI installs the pinned one).
"""

import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gpmc_bridge  # noqa: E402

SITE = os.environ.get("GPMC_SITE_PACKAGES")
# Every field gpmc 0.9.0's sign-in reads, none of them real.
AUTH = ("androidId=abc&app=com.google.android.apps.photos&client_sig=s&callerPkg=com.google.android.apps.photos"
        "&callerSig=s&device_country=us&Email=someone%40example.com&google_play_services_version=1&lang=en_US"
        "&oauth2_foreground=1&sdk_version=28&service=oauth2&Token=aas_et%2Ffake")
AUTH_URL = "https://android.googleapis.com/auth"
HASH_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/5084965799730810217"
UPLOAD_URL = "https://photos.googleapis.com/data/upload/uploadmedia/interactive"
COMMIT_URL = "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752"
QUALITY_FIELD = {"original": 3, "saver": 1}


@unittest.skipUnless(SITE, "set GPMC_SITE_PACKAGES to a real gpmc install")
class OriginalQualityOnRealGpmcTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, SITE)
        import blackboxprotobuf
        import gpmc.message_types
        import requests
        from requests.adapters import HTTPAdapter

        cls.bbp, cls.types, cls.requests, cls.adapter = blackboxprotobuf, gpmc.message_types, requests, HTTPAdapter

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.commits = []
        self.adapters_used = set()
        self.calls = 0
        self.sign_ins = 0
        # The first sign-in's token is expired when next read (see google()).
        self.expires_at_once = False
        self.lock = threading.Lock()
        # gpmc keeps a cache under ~/.gpmc; nothing of the real home is touched.
        self.home = mock.patch.dict(os.environ, {"HOME": str(self.root)})
        self.home.start()

    def tearDown(self):
        self.home.stop()
        self.scratch.cleanup()

    def respond(self, request, content=b"", headers=None, text=None):
        response = self.requests.Response()
        response.status_code = 200
        response._content = text.encode() if text is not None else content
        response.headers.update(headers or {})
        response.url, response.request, response.encoding = request.url, request, "utf-8"
        return response

    def google(self, adapter, request, **_kwargs):
        with self.lock:
            self.calls += 1
            self.adapters_used.add(id(adapter))
        url = request.url
        if url == AUTH_URL:
            with self.lock:
                self.sign_ins += 1
                first = self.sign_ins == 1
            if self.expires_at_once and first:
                return self.respond(request, text=f"Auth=bearer\nExpiry={int(time.time())}\n")
            if self.expires_at_once:
                time.sleep(0.2)  # Google takes a moment; the upload threads meet meanwhile
            return self.respond(request, text="Auth=bearer\nExpiry=9999999999\n")
        if url == HASH_URL:
            return self.respond(request, content=b"\x0a\x00")  # {"1": {}}: not in the library
        if url == UPLOAD_URL:
            return self.respond(request, headers={"X-GUploader-UploadID": "upload-1"})
        if url.startswith(UPLOAD_URL + "?upload_id="):
            body = request.body
            while hasattr(body, "read") and body.read(65536):
                pass
            reply = {"1": 1, "2": b"\xff\xfe"}
            typedef = {"1": {"type": "int"}, "2": {"type": "bytes"}}
            return self.respond(request, content=bytes(self.bbp.encode_message(reply, typedef)))
        if url == COMMIT_URL:
            decoded, _ = self.bbp.decode_message(request.body, self.types.COMMIT_UPLOAD)
            with self.lock:
                self.commits.append(decoded)
            key = {"1": {"3": {"1": f"AF1Qip{len(self.commits):040d}"}}}
            return self.respond(request, content=bytes(self.bbp.encode_message(key, gpmc_bridge.KEY_RESPONSE_TYPES["commit_upload"])))
        raise AssertionError(f"unexpected call to {url}")

    def stage(self, count, offset=0):
        items = []
        for index in range(offset, offset + count):
            path = self.root / "stage" / f"IMG_{index}.jpg"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"pixels {index}".encode() * 64)
            items.append({"id": f"asset-{index}", "path": str(path), "filename": path.name})
        return items

    def serve(self, *requests):
        events = []
        text = "".join(json.dumps(request) + "\n" for request in requests)
        with mock.patch.object(self.adapter, "send", autospec=True, side_effect=self.google):
            code = gpmc_bridge.serve(io.StringIO(text), events.append, gpmc_bridge.StopSignal())
        return code, events

    def upload(self, items, **extra):
        return {"command": "upload", "auth_data": AUTH, "items": items, **extra}

    def test_a_serve_session_commits_original_from_a_pixel_xl_with_kept_connections(self):
        code, events = self.serve(self.upload(self.stage(16), threads=8),
                                  self.upload(self.stage(8, offset=16), threads=4, quality="original"))

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual([e["code"] for e in events if e["type"] == "served"], [0, 0])
        self.assertEqual([e for e in events if e["type"] == "item_failed"], [])
        self.assertEqual(len(self.commits), 24)
        for commit in self.commits:
            self.assertEqual(commit["2"]["3"], "Pixel XL")
            self.assertEqual(commit["1"]["7"], QUALITY_FIELD["original"])
        # 1 sign-in + 4 calls a file over at most 8 kept sessions (+1 for the
        # sign-in's own), where gpmc alone would open one per call.
        self.assertEqual(self.calls, 1 + 4 * 24)
        self.assertLessEqual(len(self.adapters_used), 8 + 1)

    def test_thirty_two_threads_commit_original_over_gpmcs_real_sessions(self):
        # The 32-stream ceiling: real requests Sessions and HTTPAdapters (only
        # send is replaced), one session a thread, kept for the next request.
        code, events = self.serve(self.upload(self.stage(100), threads=32),
                                  self.upload(self.stage(32, offset=100), threads=32))

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual([e for e in events if e["type"] == "item_failed"], [])
        self.assertEqual(len(self.commits), 132)
        for commit in self.commits:
            self.assertEqual(commit["2"]["3"], "Pixel XL")
            self.assertEqual(commit["1"]["7"], QUALITY_FIELD["original"])
        self.assertEqual(self.calls, 1 + 4 * 132)
        self.assertLessEqual(len(self.adapters_used), 32 + 1)

    def test_every_thread_count_commits_original_from_a_pixel_xl(self):
        # Each count the app may send, 1 to the ceiling, through real gpmc:
        # more threads must never reach Google as another device or quality.
        for threads in range(1, gpmc_bridge.MAX_THREADS + 1):
            self.commits = []
            code, events = self.serve(self.upload(self.stage(threads + 1, offset=1000 * threads), threads=threads))
            self.assertEqual(code, gpmc_bridge.EXIT_OK, threads)
            self.assertEqual([e for e in events if e["type"] == "item_failed"], [], threads)
            self.assertEqual(len(self.commits), threads + 1, threads)
            for commit in self.commits:
                self.assertEqual(commit["2"]["3"], "Pixel XL", threads)
                self.assertEqual(commit["1"]["7"], QUALITY_FIELD["original"], threads)

    def test_a_token_that_expires_during_a_request_is_renewed_once(self):
        # PR #52 review: gpmc 0.9.0 renews an expired token with no lock, so
        # eight upload threads finding it expired signed in eight times.
        self.expires_at_once = True
        code, events = self.serve(self.upload(self.stage(8), threads=8))

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual([e for e in events if e["type"] == "item_failed"], [])
        self.assertEqual(len(self.commits), 8)
        self.assertEqual(self.sign_ins, 2, "the sign-in at connect, then one renewal for every thread")

    def test_the_same_reading_sees_the_paid_path(self):
        # The guard is not vacuous: quota is committed from a Pixel 8.
        self.serve(self.upload(self.stage(2), quality="quota"))
        self.assertEqual({commit["2"]["3"] for commit in self.commits}, {"Pixel 8"})


if __name__ == "__main__":
    unittest.main()
