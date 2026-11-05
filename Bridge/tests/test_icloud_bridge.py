"""Protocol and crash-resume behavior without live Apple or Google accounts."""

import re
import shutil
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import contextlib
import types
import os
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import icloud_bridge  # noqa: E402


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def raise_for_status(self):
        pass

    def iter_content(self, size):
        yield self.data

    def close(self):
        pass


class FakeAsset:
    id = "apple-asset-1"
    filename = "original.heic"

    def __init__(self):
        self.version = type("Version", (), {"size": 6, "url": "https://invalid.example/original",
                                              "checksum": "checksum-1"})()

    def download(self, session, url):
        return FakeResponse(b"pixels")


class FakeAlbum:
    def __init__(self, assets):
        self.assets = assets

    def __len__(self):
        return len(self.assets)

    def __iter__(self):
        return iter(self.assets)


class FakeService:
    session = object()

    def __init__(self, state="signed_in", assets=()):
        self.data = {} if state == "signed_out" else {"dsInfo": {"hsaVersion": 2 if state == "phone_only" else 0}}
        self.requires_2fa = state == "needs_2fa"
        self.requires_2sa = state in ("needs_2fa", "phone_only")
        self.photos = type("Photos", (), {"all": FakeAlbum(assets)})()
        self._state = state
        self.pushes = 0
        self.sent = []

    def get_trusted_phone_numbers(self):
        return [types.SimpleNamespace(id=7, obfuscated_number="***1234")]

    def trigger_push_notification(self):
        self.pushes += 1
        return True

    def send_2fa_code_sms(self, phone_id):
        self.sent.append(phone_id)
        return True

    def validate_2fa_code_sms(self, phone_id, code):
        self.sent.append((phone_id, code))
        if code != "123456":
            return False
        self.requires_2fa = self.requires_2sa = False
        return True

    def validate_2fa_code(self, code):
        if code != "123456":
            return False
        self.requires_2fa = self.requires_2sa = False
        return True


class ICloudBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = str(Path(self.temp.name) / "state")
        self.stage = str(Path(self.temp.name) / "stage")
        self.events = []
        self.real_session_directory = icloud_bridge.session_directory
        @contextlib.contextmanager
        def fake_session(state, account):
            yield Path(self.temp.name)
        session_patch = patch.object(icloud_bridge, "session_directory", fake_session)
        session_patch.start()
        self.addCleanup(session_patch.stop)

    def request(self, command, factory, upload=None, **extra):
        data = {"command": command, "account": "person@example.com", "state_dir": self.state, **extra}
        return icloud_bridge.run(data, self.events.append, factory=factory,
                                 upload=upload or (lambda *_: ("google-key", "uploaded")))

    def test_signed_out_status_does_not_request_password(self):
        calls = []

        def factory(account, password, cookies):
            calls.append(password)
            return FakeService("signed_out")

        self.assertEqual(self.request("status", factory), 0)
        self.assertEqual(calls, [])
        self.assertEqual(self.events, [{"type": "auth", "v": 1, "status": "signed_out", "account": "person@example.com"}])

    def test_password_and_mfa_code_are_not_emitted(self):
        service = FakeService("needs_2fa")
        self.assertEqual(self.request("sign-in", lambda *_: service, password="private-password"), 0)
        self.assertEqual(self.events[-1]["status"], "needs_2fa")
        self.assertEqual(service.pushes, 1)
        self.assertEqual(self.events[-1]["phones"], [{"id": 7, "label": "***1234"}])
        self.assertTrue(self.events[-1]["device_code_available"])
        self.assertEqual(self.request("verify-2fa", lambda *_: service, password="private-password", code="123456"), 0)
        self.assertEqual(self.events[-1]["status"], "signed_in")
        self.assertNotIn("private-password", str(self.events))
        self.assertNotIn("123456", str(self.events))

    def test_phone_only_hsa2_sends_and_verifies_sms(self):
        service = FakeService("phone_only")
        factory = lambda *_: service
        self.assertEqual(self.request("sign-in", factory, password="secret"), 0)
        self.assertEqual(self.events[-1]["status"], "needs_2fa")
        self.assertFalse(self.events[-1]["device_code_available"])
        self.assertEqual(service.pushes, 1)
        self.assertEqual(self.request("send-code", factory, password="secret", phone_id=7), 0)
        self.assertEqual(service.sent, [7])
        self.assertEqual(self.events[-1]["status"], "needs_2fa")
        self.assertEqual(self.request("verify-2fa", factory, password="secret", code="123456", phone_id=7), 0)
        self.assertEqual(service.sent[-1], (7, "123456"))
        self.assertEqual(self.events[-1]["status"], "signed_in")

    def test_phone_only_requires_phone_id_to_verify(self):
        service = FakeService("phone_only")
        self.assertEqual(self.request("verify-2fa", lambda *_: service,
                                      password="secret", code="123456"), 4)
        self.assertEqual(self.events[-1]["kind"], "request")

    def test_phone_discovery_occurs_before_session_directory_closes(self):
        open_state = {"open": False}

        @contextlib.contextmanager
        def session(state, account):
            open_state["open"] = True
            try:
                yield Path(self.temp.name)
            finally:
                open_state["open"] = False

        service = FakeService("phone_only")

        def phones():
            self.assertTrue(open_state["open"])
            return [types.SimpleNamespace(id=7, obfuscated_number="***1234")]

        service.get_trusted_phone_numbers = phones
        with patch.object(icloud_bridge, "session_directory", session):
            self.assertEqual(self.request("sign-in", lambda *_: service, password="secret"), 0)
        self.assertFalse(open_state["open"])
        self.assertEqual(self.events[-1]["phones"], [{"id": 7, "label": "***1234"}])

    def test_device_code_continues_if_optional_phone_query_has_network_error(self):
        service = FakeService("needs_2fa")
        service.get_trusted_phone_numbers = lambda: (_ for _ in ()).throw(ConnectionError("offline"))
        self.assertEqual(self.request("sign-in", lambda *_: service, password="secret"), 0)
        self.assertEqual(self.events[-1]["phones"], [])
        self.assertTrue(self.events[-1]["device_code_available"])

    def test_phone_only_account_reports_phone_query_network_failure(self):
        service = FakeService("phone_only")
        service.get_trusted_phone_numbers = lambda: (_ for _ in ()).throw(ConnectionError("offline"))
        self.assertEqual(self.request("sign-in", lambda *_: service, password="secret"), 3)
        self.assertEqual(self.events[-1]["kind"], "network")

    def test_password_whitespace_is_preserved(self):
        passwords = []
        self.request("sign-in", lambda account, password, cookies: (passwords.append(password) or FakeService()),
                     password="  spaced password  ")
        self.assertEqual(passwords, ["  spaced password  "])

    def test_revoked_session_is_signed_out(self):
        class Revoked(Exception):
            pass

        Revoked.__name__ = "PyiCloudFailedLoginException"
        with patch.object(icloud_bridge, "has_saved_session", return_value=True):
            self.assertEqual(self.request("status", lambda *_: (_ for _ in ()).throw(Revoked())), 0)
        self.assertEqual(self.events[-1]["status"], "signed_out")

    def test_legacy_two_step_fails_explicitly_instead_of_looping_mfa(self):
        service = FakeService()
        service.requires_2sa = True
        service.requires_2fa = False
        self.assertEqual(self.request("sign-in", lambda *_: service, password="secret"), 4)
        self.assertEqual(self.events[-1]["type"], "fatal")
        self.assertEqual(self.events[-1]["kind"], "unsupported_2sa")
        self.assertIn("two-step verification", self.events[-1]["message"])

    def test_provider_error_uses_generic_fatal_without_secret(self):
        def fail(*args):
            raise RuntimeError("private-password from provider")

        self.assertEqual(self.request("sign-in", fail, password="private-password"), 1)
        self.assertEqual(self.events[-1]["kind"], "internal")
        self.assertNotIn("private-password", str(self.events))

    def test_photo_library_indexing_reports_retry_later(self):
        class PyiCloudServiceNotActivatedException(Exception):
            pass

        def unavailable(*args):
            raise PyiCloudServiceNotActivatedException("private account and server details")

        self.assertEqual(self.request("sign-in", unavailable, password="private-password"), 3)
        self.assertEqual(self.events[-1]["kind"], "icloud_unavailable")
        self.assertIn("Try again later", self.events[-1]["message"])
        self.assertNotIn("private account", str(self.events))

    def test_failure_then_resume_commits_only_confirmed_component(self):
        asset = FakeAsset()
        factory = lambda *_: FakeService(assets=[asset])
        attempts = []

        def upload(auth, item):
            attempts.append(item)
            if len(attempts) == 1:
                raise ConnectionError("temporary")
            return "google-key", "uploaded"

        with patch.object(icloud_bridge, "_components", return_value=[("original", asset.version, asset.filename)]):
            request = {"staging_dir": self.stage, "auth_data": "Email=google%40example.com&Token=google-secret"}
            self.assertEqual(self.request("backup", factory, upload, **request), 0)
            self.assertEqual(self.events[-2]["type"], "progress")
            self.assertEqual(self.events[-1]["failed"], 1)
            self.assertEqual(self.events[-1]["pending"], 1)
            self.assertEqual(self.request("backup", factory, upload, **request), 0)
            self.assertEqual(self.events[-1]["uploaded"], 1)
            self.assertEqual(self.request("backup", factory, upload, **request), 0)
            self.assertEqual(self.events[-1]["existing"], 1)
        self.assertEqual(len(attempts), 2)
        self.assertFalse(list((Path(self.stage) / icloud_bridge.account_key("person@example.com")).iterdir()))
        ledger = next(Path(self.state).glob("backup-*.sqlite3"))
        with contextlib.closing(sqlite3.connect(ledger)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM confirmed").fetchone()[0], 1)
        self.assertNotIn("google-secret", str(self.events))

    def test_live_component_failure_keeps_original_confirmation_for_resume(self):
        asset = FakeAsset()
        live_version = type("Version", (), {"size": 6, "url": "https://invalid.example/live",
                                            "checksum": "checksum-live"})()
        calls = []

        def upload(auth, item):
            calls.append(item["id"])
            if item["id"].endswith(":live") and len(calls) == 2:
                raise ConnectionError("temporary")
            return "key-" + item["id"], "uploaded"

        components = [("original", asset.version, "original.heic"), ("live", live_version, "original.MOV")]
        with patch.object(icloud_bridge, "_components", return_value=components):
            request = {"staging_dir": self.stage, "auth_data": "Email=google%40example.com"}
            self.assertEqual(self.request("backup", lambda *_: FakeService(assets=[asset]), upload, **request), 0)
            self.assertEqual((self.events[-1]["failed"], self.events[-1]["pending"]), (1, 1))
            self.assertEqual(self.request("backup", lambda *_: FakeService(assets=[asset]), upload, **request), 0)
            self.assertEqual((self.events[-1]["uploaded"], self.events[-1]["pending"]), (1, 0))
        self.assertEqual(calls, ["apple-asset-1:original", "apple-asset-1:live", "apple-asset-1:live"])

    def test_switching_google_account_does_not_skip_icloud_asset(self):
        asset = FakeAsset()
        uploads = []

        def upload(auth, item):
            uploads.append(auth)
            return "google-key", "uploaded"

        with patch.object(icloud_bridge, "_components", return_value=[("original", asset.version, asset.filename)]):
            for google in ("first@example.com", "second@example.com"):
                self.request("backup", lambda *_: FakeService(assets=[asset]), upload,
                             staging_dir=self.stage, auth_data="Email=" + google)
        self.assertEqual(len(uploads), 2)
        self.assertEqual(len(list(Path(self.state).glob("backup-*.sqlite3"))), 2)

    def test_stop_reports_stopped_and_retries_after_restart(self):
        asset = FakeAsset()
        calls = []

        def upload(auth, item):
            calls.append(item)
            if len(calls) == 1:
                raise icloud_bridge.StopRequested()
            return "google-key", "uploaded"

        with patch.object(icloud_bridge, "_components", return_value=[("original", asset.version, asset.filename)]):
            request = {"staging_dir": self.stage, "auth_data": "Email=google%40example.com"}
            self.assertEqual(self.request("backup", lambda *_: FakeService(assets=[asset]), upload, **request), 5)
            self.assertEqual(self.events[-1]["type"], "stopped")
            self.assertEqual(self.request("backup", lambda *_: FakeService(assets=[asset]), upload, **request), 0)
            self.assertEqual(self.events[-1]["uploaded"], 1)

    def test_accounts_have_separate_ledgers_and_reclaim_requires_preview(self):
        self.assertNotIn("delete", dir(icloud_bridge))
        self.assertEqual(icloud_bridge.run({"command": "reclaim-status"}, self.events.append), 0)
        self.assertTrue(self.events[-1]["requires_preview"])
        self.assertFalse(self.events[-1]["immediate_space_recovery"])
        self.assertNotEqual(icloud_bridge.account_key("one@example.com"),
                            icloud_bridge.account_key("two@example.com"))

    def test_macos_session_files_rest_only_in_keychain(self):
        secrets = {}
        class Keyring:
            keychain = None

            def get_password(self, service, key):
                return secrets.get((service, key))

            def set_password(self, service, key, value):
                secrets[(service, key)] = value

        keyring = types.SimpleNamespace(Keyring=Keyring)
        state = icloud_bridge.private_dir(self.state)
        with patch.dict(sys.modules, {"keyring.backends.macOS": keyring}), patch.object(icloud_bridge, "session_backend", return_value="macos"):
            with self.real_session_directory(state, "person@example.com") as cookies:
                (cookies / "personexamplecom.session").write_text("private-session-token")
            self.assertFalse(list(state.glob("session-tmp-*")))
            self.assertFalse(any("private-session-token" in p.read_text() for p in state.iterdir() if p.is_file()))
            self.assertTrue(icloud_bridge.has_saved_session(state, "person@example.com"))
            with self.real_session_directory(state, "person@example.com") as cookies:
                self.assertEqual((cookies / "personexamplecom.session").read_text(), "private-session-token")

    def test_keychain_denial_still_removes_plaintext_temporary_session(self):
        class DeniedKeyring:
            keychain = None

            def get_password(self, service, key):
                return None

            def set_password(self, service, key, value):
                raise RuntimeError("denied")

        state = icloud_bridge.private_dir(self.state)
        fake_module = types.SimpleNamespace(Keyring=DeniedKeyring)
        with patch.dict(sys.modules, {"keyring.backends.macOS": fake_module}), patch.object(icloud_bridge, "session_backend", return_value="macos"):
            with self.assertRaises(RuntimeError):
                with self.real_session_directory(state, "person@example.com") as cookies:
                    (cookies / "personexamplecom.session").write_text("private-session-token")
        self.assertFalse(list(state.glob("session-tmp-*")))

    @unittest.skipUnless(os.name == "nt", "Windows DPAPI only")
    def test_windows_session_round_trip_is_dpapi_protected(self):
        state = icloud_bridge.private_dir(self.state)
        with self.real_session_directory(state, "person@example.com") as cookies:
            (cookies / "personexamplecom.session").write_text("private-session-token")
        safe = state / ("session-" + icloud_bridge.account_key("person@example.com") + ".dpapi")
        self.assertTrue(safe.is_file())
        self.assertNotIn(b"private-session-token", safe.read_bytes())
        self.assertFalse(list(state.glob("session-tmp-*")))
        with self.real_session_directory(state, "person@example.com") as cookies:
            self.assertEqual((cookies / "personexamplecom.session").read_text(), "private-session-token")

    @unittest.skipUnless(os.name == "nt", "Windows DPAPI only")
    def test_windows_dpapi_failure_cleans_plaintext_temporary_session(self):
        state = icloud_bridge.private_dir(self.state)
        with patch.object(icloud_bridge, "_dpapi", side_effect=OSError("denied")):
            with self.assertRaises(OSError):
                with self.real_session_directory(state, "person@example.com") as cookies:
                    (cookies / "personexamplecom.session").write_text("private-session-token")
        self.assertFalse(list(state.glob("session-tmp-*")))



# Issue #60: one Google client per run, parallel downloads and uploads.

class SizedAsset:
    """An iCloud asset whose original is `size` bytes of its own."""

    def __init__(self, index, size=6, on_download=None, on_body=None):
        self.on_body = on_body
        self.id = f"asset-{index:03d}"
        self.filename = f"IMG_{index:03d}.HEIC"
        self.data = bytes([65 + index % 26]) * size
        self.version = types.SimpleNamespace(size=size, url=f"https://invalid.example/{index}",
                                             checksum=f"checksum-{index}")
        self._asset_record = {"recordName": "record-" + self.id, "recordChangeTag": "revision-1"}
        self.on_download = on_download

    def download(self, session, url):
        if self.on_download:
            self.on_download(self)
        response = FakeResponse(self.data)
        if self.on_body:
            def body(size, data=self.data):
                self.on_body(self)
                yield data
            response.iter_content = body
        return response


def originals(asset):
    return [("original", asset.version, asset.filename)]


class Uploads:
    """A fake `upload` that counts how many run at once.

    With `target`, the first uploads wait (up to two seconds) until that many
    are in flight, so a test sees the level the pipeline really reaches.
    """

    def __init__(self, target=None, hold=0.0, outcome=None):
        self.lock = threading.Lock()
        self.active = self.most = 0
        self.target, self.hold, self.outcome = target, hold, outcome
        self.reached = False
        self.calls, self.spans = [], []

    def __call__(self, auth, item):
        with self.lock:
            self.active += 1
            self.most = max(self.most, self.active)
            self.calls.append(item)
            started = time.monotonic()
        try:
            deadline = time.monotonic() + 2
            while self.target and not self.reached and time.monotonic() < deadline:
                with self.lock:
                    if self.active >= self.target:
                        self.reached = True
                time.sleep(0.002)
            time.sleep(self.hold)
            if self.outcome:
                return self.outcome(item)
            return "key-" + item["id"], "uploaded"
        finally:
            with self.lock:
                self.active -= 1
                self.spans.append((started, time.monotonic()))


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = str(Path(self.temp.name) / "state")
        self.stage = str(Path(self.temp.name) / "stage")
        self.events = []

        @contextlib.contextmanager
        def fake_session(state, account):
            yield Path(self.temp.name)

        for name, value in (("session_directory", fake_session), ("_components", originals)):
            patcher = patch.object(icloud_bridge, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def backup(self, assets, upload=None, **extra):
        self.events = []
        request = {"command": "backup", "account": "person@example.com", "state_dir": self.state,
                   "staging_dir": self.stage, "auth_data": "Email=google%40example.com&Token=google-secret", **extra}
        kwargs = {} if upload is None else {"upload": upload}
        return icloud_bridge.run(request, self.events.append, factory=lambda *_: FakeService(assets=assets), **kwargs)

    def of_type(self, kind):
        return [e for e in self.events if e["type"] == kind]

    def ledger_keys(self):
        ledger = next(Path(self.state).glob("backup-*.sqlite3"))
        with contextlib.closing(sqlite3.connect(ledger)) as connection:
            return {row[0] for row in connection.execute("SELECT asset_id FROM confirmed")}

    def test_manual_runs_exactly_the_chosen_number_at_once(self):
        for threads in (1, 3, 6, 12):
            with self.subTest(threads=threads):
                uploads = Uploads(target=threads, hold=0.01)
                assets = [SizedAsset(i) for i in range(3 * threads)]
                self.assertEqual(self.backup(assets, uploads, threads=threads, threads_automatic=False), 0)
                self.assertEqual(uploads.most, threads)
                self.assertEqual(self.of_type("done")[0]["uploaded"], 3 * threads)
                self.assertEqual({e["threads"] for e in self.of_type("progress")}, {threads})
                shutil.rmtree(self.state)

    def test_automatic_starts_at_four(self):
        uploads = Uploads(target=4, hold=0.01)
        self.assertEqual(self.backup([SizedAsset(i) for i in range(12)], uploads, threads=2, threads_automatic=True), 0)
        self.assertEqual(uploads.most, 4)

    def test_an_app_without_thread_settings_uploads_one_at_a_time(self):
        uploads = Uploads(target=2, hold=0.01)
        self.assertEqual(self.backup([SizedAsset(i) for i in range(5)], uploads), 0)
        self.assertEqual(uploads.most, 1)

    def test_thread_settings_are_validated_before_any_network(self):
        for extra in ({"threads": 0}, {"threads": 33}, {"threads": True}, {"threads_automatic": "yes"},
                      {"download_threads": 0}, {"download_threads": 9}):
            with self.subTest(**extra):
                factory_calls = []
                code = icloud_bridge.run({"command": "backup", "account": "person@example.com", "state_dir": self.state,
                                          "staging_dir": self.stage, "auth_data": "Email=google%40example.com", **extra},
                                         self.events.append, factory=lambda *a: factory_calls.append(a))
                self.assertEqual(code, 4)
                self.assertEqual(factory_calls, [])

    def test_downloads_run_ahead_of_uploads_within_the_download_pool(self):
        lock = threading.Lock()
        state = {}

        def track(key, hold):
            with lock:
                state[key] += 1
                state["most_" + key] = max(state["most_" + key], state[key])
                state.setdefault("starts_" + key, []).append(time.monotonic())
            time.sleep(hold)
            with lock:
                state[key] -= 1

        for download_threads in (2, 8):
            with self.subTest(download_threads=download_threads):
                state.clear()
                state.update(headers=0, most_headers=0, body=0, most_body=0)
                uploads = Uploads(hold=0.03)
                assets = [SizedAsset(i, on_download=lambda a: track("headers", 0.002),
                                     on_body=lambda a: track("body", 0.02)) for i in range(24)]
                self.assertEqual(self.backup(assets, uploads, threads=4, download_threads=download_threads,
                                             state_dir=str(Path(self.temp.name) / f"state-{download_threads}")), 0)
                self.assertEqual(self.of_type("done")[0]["uploaded"], 24)
                # Bodies stream in parallel, within the pool...
                self.assertLessEqual(state["most_body"], download_threads)
                self.assertGreater(state["most_body"], 1)
                # ...while pyicloud's session starts one request at a time.
                self.assertEqual(state["most_headers"], 1)
                # Pipelined: downloads start while uploads are in flight.
                overlapping = [s for s in state["starts_body"] if any(a < s < b for a, b in uploads.spans)]
                self.assertTrue(overlapping)

    def test_staged_bytes_stay_within_the_staging_limit(self):
        staging = Path(self.stage) / icloud_bridge.account_key("person@example.com")
        seen = []

        def measure(item):
            seen.append(sum(p.stat().st_size for p in staging.rglob("*") if p.is_file()))
            return "key-" + item["id"], "uploaded"

        assets = [SizedAsset(i, size=1000) for i in range(30)]
        uploads = Uploads(hold=0.005, outcome=measure)
        self.assertEqual(self.backup(assets, uploads, threads=8, max_staging_bytes=3000), 0)
        self.assertEqual(self.of_type("done")[0]["uploaded"], 30)
        self.assertLessEqual(max(seen), 3000)
        self.assertLessEqual(uploads.most, 3)

    def test_low_free_space_keeps_one_asset_in_the_pipeline(self):
        uploads = Uploads(hold=0.005)
        with patch.object(icloud_bridge, "_free_bytes", return_value=icloud_bridge.FREE_SPACE_FLOOR):
            self.assertEqual(self.backup([SizedAsset(i) for i in range(8)], uploads, threads=8), 0)
        self.assertEqual(uploads.most, 1)
        self.assertEqual(self.of_type("done")[0]["uploaded"], 8)

    def test_ledger_writes_stay_on_the_run_thread_in_order(self):
        writes = []
        real_ledger = icloud_bridge._ledger

        class Recorder:
            def __init__(self, connection):
                self.connection = connection

            def execute(self, sql, *args):
                if sql.startswith("INSERT"):
                    writes.append((threading.get_ident(), args[0][0]))
                return self.connection.execute(sql, *args)

            def __enter__(self):
                return self.connection.__enter__()

            def __exit__(self, *exc):
                return self.connection.__exit__(*exc)

            def close(self):
                self.connection.close()

        with patch.object(icloud_bridge, "_ledger", lambda *a: Recorder(real_ledger(*a))):
            self.assertEqual(self.backup([SizedAsset(i) for i in range(20)], Uploads(hold=0.002), threads=8), 0)
        self.assertEqual({thread for thread, _ in writes}, {threading.get_ident()})
        self.assertEqual(len(writes), 20)
        # Each item is written as it is confirmed, before its event.
        items = [e["id"] for e in self.of_type("item")]
        self.assertEqual([asset for _, asset in writes], items)

    def test_failed_and_unconfirmed_uploads_are_never_ledgered_or_reported_backed_up(self):
        def outcome(item):
            index = int(item["id"].split(":")[0].split("-")[1])
            if index % 3 == 0:
                raise ConnectionError("temporary")
            if index % 3 == 1:
                return "", "uploaded"
            return "key-" + item["id"], "uploaded"

        assets = [SizedAsset(i) for i in range(15)]
        self.assertEqual(self.backup(assets, Uploads(hold=0.002, outcome=outcome), threads=8), 0)
        confirmed = {a.id for i, a in enumerate(assets) if i % 3 == 2}
        self.assertEqual(self.ledger_keys(), confirmed)
        self.assertEqual({e["id"] for e in self.of_type("item")}, confirmed)
        self.assertEqual({e["id"] for e in self.of_type("source_asset")}, confirmed)
        self.assertEqual(len(self.of_type("item_failed")), 10)
        done = self.of_type("done")[0]
        self.assertEqual((done["uploaded"], done["failed"], done["pending"]), (5, 10, 10))
        staging = Path(self.stage) / icloud_bridge.account_key("person@example.com")
        self.assertEqual(list(staging.iterdir()), [])

    def test_a_429_halves_automatic_and_never_climbs_again(self):
        hits = []

        def outcome(item):
            if not hits:
                hits.append(item)
                raise icloud_bridge.UploadFailed("rate_limit", True)
            return "key-" + item["id"], "uploaded"

        uploads = Uploads(target=4, hold=0.01, outcome=outcome)
        self.assertEqual(self.backup([SizedAsset(i) for i in range(16)], uploads, threads_automatic=True), 0)
        self.assertEqual(uploads.most, 4)
        levels = [e["threads"] for e in self.of_type("progress")]
        self.assertEqual(set(levels), {2})
        # Once the four in flight at the 429 have drained, never more than 2.
        spans = sorted(uploads.spans)
        drained = max(end for _, end in spans[:4])
        later = [(a, b) for a, b in spans if a > drained]
        self.assertGreaterEqual(len(later), 6)
        self.assertLessEqual(max(sum(1 for a, b in later if a <= s < b) for s, _ in later), 2)

    def test_a_429_leaves_manual_at_the_chosen_number(self):
        def outcome(item):
            raise icloud_bridge.UploadFailed("rate_limit", True)

        self.assertEqual(self.backup([SizedAsset(i) for i in range(6)], Uploads(outcome=outcome), threads=5), 0)
        self.assertEqual({e["threads"] for e in self.of_type("progress")}, {5})

    def test_a_refused_google_credential_stops_the_run_and_keeps_what_was_confirmed(self):
        def outcome(item):
            if item["id"].startswith("asset-005"):
                raise icloud_bridge.GoogleAuthError()
            return "key-" + item["id"], "uploaded"

        assets = [SizedAsset(i) for i in range(12)]
        uploads = Uploads(outcome=outcome)
        self.assertEqual(self.backup(assets, uploads, threads=1), 2)
        self.assertEqual(self.events[-1]["kind"], "auth")
        # Downloads finish in any order, so uploads do too; one at a time,
        # every upload before the refused one was confirmed and kept.
        sent = [item["id"].split(":")[0] for item in uploads.calls]
        self.assertEqual(sent[-1], "asset-005")
        self.assertEqual(self.ledger_keys(), set(sent[:-1]))
        self.assertEqual(len(uploads.calls), len(set(sent)))

    def test_a_refused_icloud_session_stops_the_run(self):
        class Refused(Exception):
            code = 401

        def refuse(asset):
            if asset.id == "asset-003":
                raise Refused("private details")

        assets = [SizedAsset(i, on_download=refuse) for i in range(10)]
        self.assertEqual(self.backup(assets, Uploads(), threads=4), 2)
        self.assertEqual(self.events[-1], {"type": "fatal", "v": 1, "kind": "auth",
                                           "message": "iCloud or Google Photos sign-in expired or failed"})

    def test_a_stop_in_any_upload_ends_the_run_and_resumes_cleanly(self):
        def outcome(item):
            if item["id"].startswith("asset-004"):
                raise icloud_bridge.StopRequested()
            return "key-" + item["id"], "uploaded"

        assets = [SizedAsset(i) for i in range(12)]
        self.assertEqual(self.backup(assets, Uploads(hold=0.01, outcome=outcome), threads=6), 5)
        self.assertEqual(self.events[-1]["type"], "stopped")
        self.assertNotIn("asset-004", self.ledger_keys())
        self.assertEqual(self.backup(assets, Uploads(), threads=6), 0)
        self.assertEqual(self.ledger_keys(), {a.id for a in assets})

    def test_max_items_bounds_the_assets_a_run_starts(self):
        uploads = Uploads(hold=0.002)
        self.assertEqual(self.backup([SizedAsset(i) for i in range(30)], uploads, threads=8, max_items=7), 0)
        self.assertEqual(len(uploads.calls), 7)
        done = self.of_type("done")[0]
        self.assertEqual((done["uploaded"], done["pending"]), (7, 23))

    def test_progress_reports_bytes_sent_for_the_apps_speed(self):
        assets = [SizedAsset(i, size=500) for i in range(4)]
        self.assertEqual(self.backup(assets, Uploads(), threads=2), 0)
        progress = self.of_type("progress")
        self.assertEqual(progress[-1]["bytes_sent"], 2000)
        self.assertIn("bytes_per_second", progress[-1])
        self.assertEqual(self.of_type("done")[0]["bytes_sent"], 2000)


class UploadParallelismTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0

    def controller(self, threads=4, automatic=True):
        return icloud_bridge.UploadParallelism(threads, automatic, clock=lambda: self.now)

    def step(self, controller, rate):
        """One measured step at `rate` bytes a second."""
        controller.completed(0)  # the step's clock starts at its first answer
        self.now += 4
        controller.completed(int(rate * 4))

    def test_the_range_is_one_to_thirty_two(self):
        for threads in (0, 33, 1.5):
            with self.assertRaises(ValueError):
                self.controller(threads, automatic=False)
        self.assertEqual(self.controller(32, automatic=False).level, 32)
        self.assertEqual(self.controller(1, automatic=False).level, 1)
        self.assertEqual(self.controller(1).cap, 32)

    def test_automatic_climbs_while_ten_percent_faster(self):
        controller = self.controller()
        self.assertEqual(controller.level, 4)
        for rate in (10e6, 11.5e6, 13e6):
            self.step(controller, rate)
        self.assertEqual(controller.level, 7)
        self.assertTrue(controller.climbing)

    def test_one_noisy_step_does_not_lock_the_level(self):
        controller = self.controller()
        self.step(controller, 10e6)   # 4 -> 5
        self.step(controller, 9e6)    # noisy: measured again at 5
        self.assertEqual(controller.level, 5)
        self.assertTrue(controller.climbing)
        self.step(controller, 12e6)   # it was noise: 5 -> 6
        self.assertEqual(controller.level, 6)
        self.assertTrue(controller.climbing)

    def test_two_misses_go_back_to_the_best_level_and_stay(self):
        controller = self.controller()
        self.step(controller, 10e6)   # 4 -> 5
        self.step(controller, 10.5e6)
        self.step(controller, 10.2e6)
        self.assertEqual(controller.level, 4)
        self.assertFalse(controller.climbing)
        self.step(controller, 50e6)
        self.assertEqual(controller.level, 4)
        self.assertIn("no faster at 5", controller.summary)

    def test_a_step_is_judged_on_enough_bytes_and_time(self):
        controller = self.controller()
        controller.completed(0)
        self.now += 10
        controller.completed(1_000_000)  # 10 s but only 1 MB
        self.assertEqual(controller.level, 4)
        controller.completed(30_000_000)
        self.assertEqual(controller.level, 5)

    def test_a_429_halves_and_ends_the_climb(self):
        controller = self.controller()
        for rate in (10e6, 12e6, 14e6, 16e6):
            self.step(controller, rate)
        self.assertEqual(controller.level, 8)
        controller.rate_limited()
        self.assertEqual(controller.level, 4)
        self.step(controller, 90e6)
        self.assertEqual(controller.level, 4)
        controller.rate_limited()
        controller.rate_limited()
        controller.rate_limited()
        self.assertEqual(controller.level, 1)

    def test_two_retryable_failures_within_half_a_minute_take_one_off(self):
        controller = self.controller()
        controller.retryable_failure()
        self.now += 31
        controller.retryable_failure()   # the first is too old to count with it
        self.assertEqual(controller.level, 4)
        self.now += 5
        controller.retryable_failure()
        self.assertEqual(controller.level, 3)
        self.assertFalse(controller.climbing)

    def test_manual_never_moves(self):
        controller = self.controller(9, automatic=False)
        controller.rate_limited()
        controller.retryable_failure()
        controller.retryable_failure()
        self.step(controller, 10e6)
        self.step(controller, 20e6)
        self.assertEqual(controller.level, 9)

    def test_the_climb_ends_at_thirty_two(self):
        controller = self.controller()
        rate = 1e6
        while controller.climbing:
            self.step(controller, rate)
            rate *= 1.2
        self.assertEqual(controller.level, 32)
        self.assertIn("the most it uses", controller.summary)


def gated_client_type():
    """test_uplink's SessionClient whose first uploads wait until `target`
    of them are in flight, so every thread count is really exercised."""
    from test_uplink import SessionClient

    class Gated(SessionClient):
        def __init__(self, target, **kwargs):
            super().__init__(**kwargs)
            self.target, self.active, self.most, self.reached = target, 0, 0, False
            self.lock = threading.Lock()

        def upload(self, target, progress_callback=None, **kwargs):
            with self.lock:
                self.active += 1
                self.most = max(self.most, self.active)
            try:
                deadline = time.monotonic() + 2
                while not self.reached and time.monotonic() < deadline:
                    with self.lock:
                        if self.active >= self.target:
                            self.reached = True
                    time.sleep(0.001)
                return super().upload(target, progress_callback=progress_callback, **kwargs)
            finally:
                with self.lock:
                    self.active -= 1

    return Gated


class OneGoogleClientTests(unittest.TestCase):
    """The real Google path (GoogleRun over gpmc_bridge) with a fake gpmc client."""

    def setUp(self):
        PipelineTests.setUp(self)
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import test_uplink

        self.uplink = test_uplink
        self.made = []

    backup = PipelineTests.backup
    of_type = PipelineTests.of_type

    def run_with(self, client, assets, **extra):
        def factory(auth_data, timeout):
            self.made.append((auth_data, timeout))
            return client

        with patch.object(icloud_bridge, "_gpmc_client_factory", factory):
            return self.backup(assets, **extra)

    def test_original_reaches_gpmc_as_saver_false_use_quota_false_at_every_thread_count(self):
        # The hard constraint: Pixel XL at Original quality, free. Every
        # upload of every thread count 1-32, manual and automatic, reaches
        # gpmc with exactly these keywords and nothing else.
        gated = gated_client_type()
        expected = {"target", "saver", "use_quota", "threads", "force_upload"}
        self.assertEqual(expected, self.uplink.UPLOAD_KWARGS)
        for threads in range(1, 33):
            for automatic in (False, True):
                context = f"threads={threads} automatic={automatic}"
                self.made = []
                level = 4 if automatic else threads
                client = gated(level)
                assets = [SizedAsset(i) for i in range(level + 2)]
                code = self.run_with(client, assets, threads=threads, threads_automatic=automatic,
                                     state_dir=str(Path(self.temp.name) / f"state-{threads}-{automatic}"))
                self.assertEqual(code, 0, context)
                self.assertEqual(len(client.upload_calls), level + 2, context)
                self.assertEqual(client.most, level, context)
                for call in client.upload_calls:
                    self.assertEqual(set(call), expected, context)
                    self.assertIs(call["saver"], False, context)
                    self.assertIs(call["use_quota"], False, context)
                    self.assertEqual(call["threads"], 1, context)
                    self.assertIs(call["force_upload"], False, context)
                # One client, one sign-in, for the whole run.
                self.assertEqual(len(self.made), 1, context)

    def test_the_run_shares_one_client_and_its_kept_sessions(self):
        client = self.uplink.SessionClient()
        self.uplink.FakeSession.made = 0
        assets = [SizedAsset(i) for i in range(40)]
        self.assertEqual(self.run_with(client, assets, threads=6), 0)
        self.assertEqual(len(self.made), 1)
        self.assertEqual(len(client.upload_calls), 40)
        # Four gpmc calls a file over kept sessions, not 160 new ones.
        self.assertLessEqual(self.uplink.FakeSession.made, 6)
        self.assertEqual(len(client.api.sessions_seen), 160)
        self.assertEqual(self.of_type("done")[0]["uploaded"], 40)

    def test_a_429_from_gpmc_halves_the_automatic_level(self):
        client = self.uplink.FakeClient(failing={"IMG_000.HEIC": "429 Client Error: Too Many Requests"})
        self.assertEqual(self.run_with(client, [SizedAsset(i) for i in range(10)], threads_automatic=True), 0)
        self.assertEqual(self.of_type("progress")[-1]["threads"], 2)
        failed = self.of_type("item_failed")
        self.assertEqual([(e["id"], e["code"]) for e in failed], [("asset-000", "network")])

    def test_a_refused_google_account_fails_before_any_icloud_request(self):
        client = self.uplink.FakeClient(auth_error=RuntimeError("401 Client Error"))
        factory_calls = []
        with patch.object(icloud_bridge, "_gpmc_client_factory", lambda *a: client):
            code = icloud_bridge.run({"command": "backup", "account": "person@example.com", "state_dir": self.state,
                                      "staging_dir": self.stage, "auth_data": "Email=google%40example.com"},
                                     self.events.append, factory=lambda *a: factory_calls.append(a))
        self.assertEqual(code, 2)
        self.assertEqual(factory_calls, [])

    def test_every_upload_is_built_by_gpmc_bridge_at_original_quality(self):
        source = Path(icloud_bridge.__file__).read_text()
        self.assertNotIn("client.upload(", source)
        self.assertEqual(re.findall(r"\b(?:saver|use_quota|model|make)\s*=", source), [])
        requests = re.findall(r'\{"command": "upload".*?\}', source, re.DOTALL)
        self.assertEqual(len(requests), 1)
        self.assertIn('"quality": "original"', requests[0])
        self.assertIn('"threads": 1', requests[0])


def _real_gpmc_methods():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import test_original_real_gpmc as real

    return real


_REAL = _real_gpmc_methods()


@unittest.skipUnless(_REAL.SITE, "set GPMC_SITE_PACKAGES to a real gpmc install")
class ICloudOriginalOnRealGpmcTests(unittest.TestCase):
    """The iCloud path through the real gpmc 0.9.0, only HTTPAdapter.send
    answering like Google (test_original_real_gpmc's harness, borrowed)."""

    _base = _REAL.OriginalQualityOnRealGpmcTests.__dict__
    setUpClass = _base["setUpClass"]
    respond = _base["respond"]
    google = _base["google"]

    def setUp(self):
        self._base["setUp"](self)
        self.addCleanup(self._base["tearDown"], self)
        self.temp = self.scratch

        @contextlib.contextmanager
        def fake_session(state, account):
            yield self.root

        for name, value in (("session_directory", fake_session), ("_components", originals)):
            patcher = patch.object(icloud_bridge, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_an_icloud_run_commits_original_from_a_pixel_xl_after_one_sign_in(self):
        assets = [SizedAsset(i, size=4096) for i in range(24)]
        events = []
        request = {"command": "backup", "account": "person@example.com", "state_dir": str(self.root / "state"),
                   "staging_dir": str(self.root / "icloud-stage"), "auth_data": _REAL.AUTH, "threads": 8}
        with patch.object(self.adapter, "send", autospec=True, side_effect=self.google):
            code = icloud_bridge.run(request, events.append, factory=lambda *_: FakeService(assets=assets))
        self.assertEqual(code, 0, events[-3:])
        self.assertEqual([e for e in events if e["type"] == "item_failed"], [])
        self.assertEqual(len(self.commits), 24)
        for commit in self.commits:
            self.assertEqual(commit["2"]["3"], "Pixel XL")
            self.assertEqual(commit["1"]["7"], _REAL.QUALITY_FIELD["original"])
        self.assertEqual(self.sign_ins, 1)
        # The sign-in, check-auth's hash lookup, then four calls a file over
        # at most eight kept sessions.
        self.assertEqual(self.calls, 1 + 1 + 4 * 24)
        self.assertLessEqual(len(self.adapters_used), 8 + 2)


if __name__ == "__main__":
    unittest.main()
