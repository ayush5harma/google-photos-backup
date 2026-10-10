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


class FakeApi:
    def __init__(self, fail_with=None):
        self.fail_with = fail_with

    @property
    def bearer_token(self):
        if self.fail_with:
            raise self.fail_with
        return "token"


class FakeClient:
    """Behaves like gpmc.Client for the calls the bridge makes."""

    def __init__(self, existing=(), failing=(), auth_error=None, album_error=None):
        self.api = FakeApi(auth_error)
        self.existing = set(existing)
        self.failing = set(failing)
        self.album_error = album_error
        self.upload_kwargs = None
        self.album_calls = []

    def upload(self, target, progress_callback=None, **kwargs):
        self.upload_kwargs = dict(kwargs, target=target)
        results = {}
        for path, options in target.items():
            path = path.absolute().as_posix()
            name = options["filename"]

            def event(phase, done=0, path=path, name=name):
                progress_callback({"version": 1, "type": "progress", "operation": "upload", "phase": phase, "path": path, "filename": name, "bytes_completed": done, "bytes_total": 10})

            event("hashing", 10)
            if name in self.failing:
                logging.getLogger().error(f"Error uploading file {path}: 413 too large")
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
        if self.album_error:
            raise self.album_error
        return ["album-new"]

    def add_to_existing_album(self, media_keys, album_id, show_progress=False):
        self.album_calls.append(("id", album_id, list(media_keys)))
        if self.album_error:
            raise self.album_error
        return album_id


def run(request, client=None, factory_error=None):
    events = []
    calls = []

    def factory(auth_data, timeout):
        calls.append((auth_data, timeout))
        if factory_error:
            raise factory_error
        return client

    code = gpmc_bridge.run(request, events.append, client_factory=factory)
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
        self.assertEqual(target, {Path("/tmp/stage/a.jpg"): {"hash": None, "filename": "a.jpg"}})
        self.assertEqual(client.upload_kwargs["saver"], False)
        self.assertEqual(client.upload_kwargs["use_quota"], False)
        self.assertEqual(client.upload_kwargs["force_upload"], False)
        self.assertEqual(client.upload_kwargs["threads"], 1)

    def test_quality_maps_onto_gpmc_flags(self):
        for quality, saver, quota in [("original", False, False), ("saver", True, False), ("quota", False, True)]:
            client = FakeClient()
            run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg"), "quality": quality, "threads": 3}, client)
            self.assertEqual((client.upload_kwargs["saver"], client.upload_kwargs["use_quota"], client.upload_kwargs["threads"]), (saver, quota, 3), quality)

    def test_failed_file_carries_the_reason_gpmc_logged(self):
        client = FakeClient(failing={"big.mov"})
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg", "big.mov")}, client)

        self.assertEqual(code, 0)
        self.assertEqual(of_type(events, "item_failed"), [{"type": "item_failed", "v": 1, "id": "asset-big.mov", "message": "413 too large"}])
        self.assertEqual(of_type(events, "done")[0]["failed"], 1)

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
        client = FakeClient(auth_error=RuntimeError("403 BadAuthentication"))
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, client)

        self.assertEqual(code, gpmc_bridge.EXIT_AUTH)
        self.assertIsNone(client.upload_kwargs)
        self.assertEqual(events, [{"type": "fatal", "v": 1, "kind": "auth", "message": "403 BadAuthentication"}])

    def test_unreachable_network_is_not_an_auth_failure(self):
        code, events, _ = run({"command": "upload", "auth_data": AUTH, "items": items("a.jpg")}, factory_error=ConnectionError("no route"))

        self.assertEqual(code, gpmc_bridge.EXIT_NETWORK)
        self.assertEqual(events[0]["kind"], "network")


class OtherCommandTests(unittest.TestCase):
    def test_check_auth_reports_the_account(self):
        code, events, _ = run({"command": "check-auth", "auth_data": AUTH}, FakeClient())
        self.assertEqual(code, 0)
        self.assertEqual(events, [{"type": "auth", "v": 1, "email": "someone@example.com"}])

    def test_add_to_album_uses_media_keys_directly(self):
        client = FakeClient()
        code, events, _ = run({"command": "add-to-album", "auth_data": AUTH, "media_keys": ["k1", "k2"], "album": {"name": "Trip"}}, client)

        self.assertEqual(code, 0)
        self.assertEqual(client.album_calls, [("name", "Trip", ["k1", "k2"])])
        self.assertEqual(of_type(events, "album")[0]["album_id"], "album-new")

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


if __name__ == "__main__":
    unittest.main()
