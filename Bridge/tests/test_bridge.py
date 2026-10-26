"""Tests for gpmc_bridge against a fake gpmc client.

The fake reproduces the parts of gpmc 0.9.0 the bridge leans on: upload()
takes a {Path: {"hash", "filename"}} mapping and reports through
progress_callback with gpmc's own event shape, a failed file is logged as
"Error uploading file <path>: <reason>" and left out of the result, and the
bearer token is fetched lazily by touching client.api.bearer_token.
"""


import json
import logging
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gpmc_bridge  # noqa: E402

AUTH = "androidId=abc&Email=someone%40example.com&lang=en_US&Token=t"


class FakeHTTPError(Exception):
    """Shaped like requests.HTTPError: the status is on .response."""

    def __init__(self, status):
        super().__init__(f"{status} Client Error")
        self.response = type("Response", (), {"status_code": status})()


class FakeApi:
    def __init__(self, fail_with=None, photos_error=None):
        self.fail_with = fail_with
        self.photos_error = photos_error
        self.hash_lookups = []

    @property
    def bearer_token(self):
        if self.fail_with:
            raise self.fail_with
        return "token"

    def add_media_to_album(self, album_media_key, media_keys):
        # gpmc 0.9.0 appends to an existing album here; its Client has no
        # add_to_existing_album (that is on gpmc's main branch only).
        self.client.album_calls.append(("id", album_media_key, list(media_keys)))
        if self.client.album_error:
            raise self.client.album_error
        return {}

    def find_remote_media_by_hash(self, sha1_hash):
        self.hash_lookups.append(sha1_hash)
        if self.photos_error:
            raise self.photos_error
        return None


class FakeClient:
    """Behaves like gpmc.Client for the calls the bridge makes."""

    def __init__(self, existing=(), failing=(), auth_error=None, album_error=None, on_album=None):
        self.api = FakeApi(auth_error)
        self.api.client = self
        self.existing = set(existing)
        self.failing = dict(failing) if isinstance(failing, dict) else set(failing)
        self.album_error = album_error
        self.on_album = on_album
        self.upload_calls = []
        self.album_calls = []

    @property
    def upload_kwargs(self):
        return self.upload_calls[-1] if self.upload_calls else None

    def upload(self, target, progress_callback=None, **kwargs):
        self.upload_calls.append(dict(kwargs, target=target))
        results = {}
        for path, options in target.items():
            path = path.absolute().as_posix()
            name = options["filename"]

            def event(phase, done=0, path=path, name=name):
                progress_callback({"version": 1, "type": "progress", "operation": "upload", "phase": phase, "path": path, "filename": name, "bytes_completed": done, "bytes_total": 10})

            event("hashing", 10)
            if name in self.failing:
                reason = self.failing[name] if isinstance(self.failing, dict) else "413 too large"
                logging.getLogger().error(f"Error uploading file {path}: {reason}")
                event("error")
                continue
            if name in self.existing:
                event("skipped", 10)
                results[path] = f"key-{name}"
                continue
            event("uploading", 5)
            event("complete", 10)
            results[path] = f"key-{name}"
        return results

    def add_to_album(self, media_keys, album_name, show_progress):
        self.album_calls.append(("name", album_name, list(media_keys)))
        if self.on_album:
            self.on_album()
        if self.album_error:
            raise self.album_error
        return ["album-new"]



def run(request, client=None, factory_error=None, stop=None, on_event=None):
    events = []
    calls = []

    def factory(auth_data, timeout):
        calls.append((auth_data, timeout))
        if factory_error:
            raise factory_error
        return client

    def emit(event):
        events.append(event)
        if on_event:
            on_event(event)

    code = gpmc_bridge.run(request, emit, client_factory=factory, stop=stop)
    return code, events, calls


def items(*names):
    return [{"id": f"asset-{n}", "path": f"/tmp/stage/{n}", "filename": n} for n in names]


def of_type(events, kind):
    return [e for e in events if e["type"] == kind]


class UploadTests(unittest.TestCase):
    def test_new_and_existing_items_are_reported_by_asset_id(self):
        client = FakeClient(existing={"b.heic"})
        code, events, calls = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "b.heic")}, client)

        self.assertEqual(code, 0)
        self.assertEqual(calls, [(AUTH, 60)])
        done = {e["id"]: (e["status"], e["media_key"]) for e in of_type(events, "item")}
        self.assertEqual(done, {"asset-a.jpg": ("uploaded", "key-a.jpg"), "asset-b.heic": ("existing", "key-b.heic")})
        self.assertEqual(of_type(events, "done"), [{"type": "done", "v": 1, "uploaded": 1, "existing": 1, "failed": 0}])
        self.assertTrue(all(e["id"].startswith("asset-") for e in of_type(events, "progress")))

    def test_custom_filename_and_default_options_reach_gpmc(self):
        client = FakeClient()
        run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, client)

        target = client.upload_kwargs["target"]
        self.assertEqual(target, {Path(gpmc_bridge._filesystem_path("/tmp/stage/a.jpg")): {"hash": None, "filename": "a.jpg"}})
        self.assertEqual(client.upload_kwargs["saver"], False)
        self.assertEqual(client.upload_kwargs["use_quota"], False)
        self.assertEqual(client.upload_kwargs["force_upload"], False)
        self.assertEqual(client.upload_kwargs["threads"], 1)

    def test_quality_maps_onto_gpmc_flags(self):
        for quality, saver, quota in [("original", False, False), ("saver", True, False), ("quota", False, True)]:
            client = FakeClient()
            run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "quality": quality, "threads": 3}, client)
            self.assertEqual((client.upload_kwargs["saver"], client.upload_kwargs["use_quota"]), (saver, quota), quality)

    def test_each_file_is_its_own_gpmc_call_so_results_stream(self):
        client = FakeClient()
        _, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "b.jpg", "c.jpg"), "threads": 2, "album": {"name": "Trip"}}, client)

        self.assertEqual(len(client.upload_calls), 3)
        self.assertTrue(all(len(call["target"]) == 1 and call["threads"] == 1 for call in client.upload_calls))
        kinds = [e["type"] for e in events if e["type"] != "progress"]
        self.assertEqual(kinds, ["item", "item", "item", "album", "done"])

    def test_stop_between_files_keeps_what_was_confirmed(self):
        stop = gpmc_bridge.StopSignal()

        def stop_after_first_item(event):
            if event["type"] == "item":
                stop.request()  # what the SIGTERM handler does, in the main thread

        client = FakeClient()
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "b.jpg"), "album": {"name": "Trip"}},
                              client, stop=stop, on_event=stop_after_first_item)

        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        self.assertEqual(len(of_type(events, "item")), 1)
        self.assertEqual(events[-1], {"type": "stopped", "v": 1})
        self.assertEqual(client.album_calls, [])

    def test_stop_during_album_creation_waits_for_its_id(self):
        stop = gpmc_bridge.StopSignal()
        client = FakeClient(on_album=stop.request)
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "album": {"name": "Trip"}}, client, stop=stop)

        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        self.assertEqual([e["type"] for e in events if e["type"] != "progress"], ["item", "album", "stopped"])
        self.assertEqual(of_type(events, "album")[0]["album_id"], "album-new")

    def test_only_the_first_stop_signal_acts(self):
        stop = gpmc_bridge.StopSignal()
        with self.assertRaises(gpmc_bridge.StopRequested):
            stop.request()
        stop.request()  # a second SIGTERM while the first is handled: no raise

    def test_a_vanished_app_ends_the_run_quietly(self):
        def broken(event):
            if event["type"] == "item":
                raise BrokenPipeError
        code, _, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "b.jpg")}, FakeClient(), on_event=broken)
        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)

    def test_stop_during_auth_is_not_an_auth_failure(self):
        stop = gpmc_bridge.StopSignal()
        client = FakeClient()
        client.api = type("Api", (), {"bearer_token": property(lambda self: stop.request())})()
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, client, stop=stop)
        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        self.assertEqual(events, [{"type": "stopped", "v": 1}])

    def test_failed_file_carries_the_reason_gpmc_logged(self):
        client = FakeClient(failing={"big.mov"})
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "big.mov")}, client)

        self.assertEqual(code, 0)
        self.assertEqual(of_type(events, "item_failed"), [{"type": "item_failed", "v": 1, "id": "asset-big.mov", "message": "413 too large", "retryable": False}])
        self.assertEqual(of_type(events, "done")[0]["failed"], 1)

    def test_failed_file_says_whether_sending_it_again_can_help(self):
        reasons = {
            "busy.jpg": "503 Server Error: Service Unavailable for url: https://photos.googleapis.com/x",
            "slow.jpg": "429 Client Error: Too Many Requests for url: https://photos.googleapis.com/x",
            "gone.jpg": "HTTPSConnectionPool(host='photos.googleapis.com', port=443): Read timed out. (read timeout=60)",
            "big.jpg": "413 Client Error: Request Entity Too Large for url: https://photos.googleapis.com/x",
            "odd.jpg": "File upload rejected by api",
        }
        client = FakeClient(failing=reasons)
        _, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items(*reasons)}, client)

        retryable = {e["id"]: e["retryable"] for e in of_type(events, "item_failed")}
        self.assertEqual(retryable, {"asset-busy.jpg": True, "asset-slow.jpg": True, "asset-gone.jpg": True,
                                     "asset-big.jpg": False, "asset-odd.jpg": False})
        self.assertEqual(of_type(events, "item_failed")[0]["message"], reasons[of_type(events, "item_failed")[0]["id"][6:]])

    def test_an_escaped_network_exception_is_retryable(self):
        client = FakeClient()
        client.upload = lambda **kwargs: (_ for _ in ()).throw(ConnectionError("no route"))
        _, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, client)
        self.assertEqual(of_type(events, "item_failed")[0]["retryable"], True)

    def test_new_album_is_created_with_new_and_existing_items(self):
        client = FakeClient(existing={"b.jpg"})
        _, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "b.jpg"), "album": {"name": "Trip"}}, client)

        self.assertEqual(client.album_calls, [("name", "Trip", ["key-a.jpg", "key-b.jpg"])])
        self.assertEqual(of_type(events, "album"), [{"type": "album", "v": 1, "album_id": "album-new", "added": 2}])

    def test_known_album_is_appended_to(self):
        client = FakeClient()
        _, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "album": {"id": "album-1", "name": "Trip"}}, client)

        self.assertEqual(client.album_calls, [("id", "album-1", ["key-a.jpg"])])
        self.assertEqual(of_type(events, "album")[0]["album_id"], "album-1")

    def test_known_album_is_appended_to_in_batches_of_500(self):
        client = FakeClient()
        keys = [f"k{i}" for i in range(1200)]
        code, events, _ = run({"command": "add-to-album", "auth_data": AUTH, "media_keys": keys, "album": {"id": "album-1"}}, client)

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual([len(call[2]) for call in client.album_calls], [500, 500, 200])
        self.assertEqual({call[1] for call in client.album_calls}, {"album-1"})
        self.assertEqual(sum((call[2] for call in client.album_calls), []), keys)
        self.assertEqual(of_type(events, "album"), [{"type": "album", "v": 1, "album_id": "album-1", "added": 1200}])

    def test_album_failure_does_not_undo_the_uploads(self):
        client = FakeClient(album_error=RuntimeError("500 backend"))
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "album": {"name": "Trip"}}, client)

        self.assertEqual(code, 0)
        self.assertEqual(len(of_type(events, "item")), 1)
        self.assertEqual(of_type(events, "album_failed"), [{"type": "album_failed", "v": 1, "message": "500 backend"}])

    def test_no_album_call_when_nothing_uploaded(self):
        client = FakeClient(failing={"a.jpg"})
        run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "album": {"name": "Trip"}}, client)
        self.assertEqual(client.album_calls, [])

    def test_auth_failure_is_fatal_before_any_upload(self):
        client = FakeClient(auth_error=FakeHTTPError(403))
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, client)

        self.assertEqual(code, gpmc_bridge.EXIT_AUTH)
        self.assertIsNone(client.upload_kwargs)
        self.assertEqual(events, [{"type": "fatal", "v": 1, "kind": "auth", "message": "403 Client Error"}])

    def test_only_a_definite_no_counts_as_refused(self):
        # The app throws away a refused credential, so a busy Google or a bug
        # must not look like a refusal.
        cases = [
            (FakeHTTPError(401), "auth"),
            (RuntimeError("Auth response does not contain bearer token"), "auth"),
            (FakeHTTPError(503), "network"),
            (FakeHTTPError(501), "network"),
            (FakeHTTPError(505), "network"),
            (FakeHTTPError(520), "network"),
            (FakeHTTPError(599), "network"),
            (FakeHTTPError(408), "network"),
            (FakeHTTPError(400), "internal"),
            (FakeHTTPError(429), "rate_limit"),
            (type("RetryError", (Exception,), {})("max retries"), "network"),
            (RuntimeError("something odd"), "internal"),
        ]
        for error, kind in cases:
            _, events, _ = run({"command": "check-auth", "auth_data": AUTH}, FakeClient(auth_error=error))
            self.assertEqual(events[0]["kind"], kind, repr(error))

    def test_a_credential_missing_fields_is_refused(self):
        _, events, _ = run({"command": "check-auth", "auth_data": AUTH}, factory_error=KeyError("client_sig"))
        self.assertEqual(events[0]["kind"], "auth")

    def test_rate_limit_while_signing_in_is_its_own_kind(self):
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, FakeClient(auth_error=FakeHTTPError(429)))
        self.assertEqual(code, gpmc_bridge.EXIT_RATE_LIMIT)
        self.assertEqual(events, [{"type": "fatal", "v": 1, "kind": "rate_limit", "message": "429 Client Error"}])

    def test_unreachable_network_is_not_an_auth_failure(self):
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, factory_error=ConnectionError("no route"))

        self.assertEqual(code, gpmc_bridge.EXIT_NETWORK)
        self.assertEqual(events[0]["kind"], "network")


class OtherCommandTests(unittest.TestCase):
    def test_check_auth_reports_the_account(self):
        client = FakeClient()
        code, events, _ = run({"command": "check-auth", "auth_data": AUTH}, client)
        self.assertEqual(code, 0)
        self.assertEqual(events, [{"type": "auth", "v": 1, "email": "someone@example.com"}])
        self.assertEqual(client.api.hash_lookups, [bytes(20)])

    def test_check_auth_fails_when_photos_refuses_the_account(self):
        client = FakeClient()
        client.api = FakeApi(photos_error=FakeHTTPError(401))
        code, events, _ = run({"command": "check-auth", "auth_data": AUTH}, client)
        self.assertEqual(code, gpmc_bridge.EXIT_AUTH)
        self.assertEqual(events[0]["kind"], "auth")
        self.assertIn("Google Photos refused the account", events[0]["message"])

    def test_email_is_fully_decoded(self):
        auth = "Email=some.one%2Btag%40gmail.com&Token=aas_et%2Fx&androidId=1"
        _, events, _ = run({"command": "check-auth", "auth_data": auth}, FakeClient())
        self.assertEqual(events[0]["email"], "some.one+tag@gmail.com")

    def test_add_to_album_uses_media_keys_directly(self):
        client = FakeClient()
        code, events, _ = run({"command": "add-to-album", "auth_data": AUTH, "media_keys": ["k1", "k2"], "album": {"name": "Trip"}}, client)

        self.assertEqual(code, 0)
        self.assertEqual(client.album_calls, [("name", "Trip", ["k1", "k2"])])
        self.assertEqual(of_type(events, "album")[0]["album_id"], "album-new")

    def test_add_to_album_rate_limit_is_its_own_kind(self):
        client = FakeClient(album_error=FakeHTTPError(429))
        code, events, _ = run({"command": "add-to-album", "auth_data": AUTH, "media_keys": ["k1"], "album": {"id": "a"}}, client)
        self.assertEqual(code, gpmc_bridge.EXIT_RATE_LIMIT)
        self.assertEqual(events[-1]["kind"], "rate_limit")

    def test_add_to_album_failure_is_fatal(self):
        client = FakeClient(album_error=RuntimeError("500"))
        code, events, _ = run({"command": "add-to-album", "auth_data": AUTH, "media_keys": ["k1"], "album": {"id": "a"}}, client)
        self.assertEqual(code, gpmc_bridge.EXIT_INTERNAL)
        self.assertEqual(events[-1]["type"], "fatal")

    def test_malformed_requests_are_rejected(self):
        bad = [
            {"command": "upload", "auth_data": AUTH},
            {"command": "upload", "auth_data": AUTH, "items": [{"id": "x"}]},
            {"command": "upload", "auth_data": "", "items": items("a.jpg")},
            {"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "quality": "best"},
            {"command": "add-to-album", "auth_data": AUTH, "media_keys": ["k"], "album": {}},
            {"command": "explode"},
        ]
        for request in bad:
            code, events, _ = run(request, FakeClient())
            self.assertEqual(code, gpmc_bridge.EXIT_REQUEST, request)
            self.assertEqual(events[0]["kind"], "request", request)


class ProcessTests(unittest.TestCase):
    """main() over a real pipe: stdout must carry nothing but protocol lines."""

    def bridge(self, request):
        script = Path(gpmc_bridge.__file__)
        return subprocess.run([sys.executable, "-I", str(script)], input=json.dumps(request), capture_output=True, text=True, timeout=60)

    def test_version_answers_without_auth(self):
        proc = self.bridge({"command": "version"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]["type"], "version")
        self.assertEqual(lines[0]["protocol"], gpmc_bridge.PROTOCOL_VERSION)

    def test_garbage_on_stdin_is_a_request_error(self):
        proc = subprocess.run([sys.executable, "-I", gpmc_bridge.__file__], input="{not json", capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, gpmc_bridge.EXIT_REQUEST)
        self.assertEqual(json.loads(proc.stdout)["kind"], "request")

    def test_stray_prints_go_to_stderr(self):
        # gpmc logs through rich, whose console writes to stdout; inside
        # protocol_stdout() that must land on stderr instead.
        code = (
            "import sys; sys.path.insert(0, sys.argv[1]); import gpmc_bridge\n"
            "with gpmc_bridge.protocol_stdout() as out:\n"
            "    print('rich console noise')\n"
            "    out.write('{}\\n')\n"
        )
        proc = subprocess.run([sys.executable, "-I", "-c", code, str(Path(gpmc_bridge.__file__).parent)], capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "{}\n")
        self.assertIn("rich console noise", proc.stderr)


class FailureLogPathTests(unittest.TestCase):
    def test_native_logged_path_matches_posix_result_key(self):
        path = Path("fixture photos") / "retry.jpg"
        handler = gpmc_bridge.FailureLog()
        record = logging.LogRecord("gpmc", logging.ERROR, "", 0,
                                   f"Error uploading file {path}: 429 Client Error", (), None)
        handler.emit(record)
        self.assertEqual(handler.reasons[gpmc_bridge._path_key(str(path))], "429 Client Error")


if __name__ == "__main__":
    unittest.main()
