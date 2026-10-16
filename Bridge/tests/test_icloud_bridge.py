"""Protocol and crash-resume behavior without live Apple or Google accounts."""

import sqlite3
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
