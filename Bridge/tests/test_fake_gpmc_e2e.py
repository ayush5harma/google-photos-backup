"""The real bridge, in its own process, against Tests/E2E/fake_gpmc.

Each request is a separate `python3 -I -B gpmc_bridge.py`, as the app runs it,
with an isolated copy of the fake runtime on every platform. The fake keeps
what Google "holds" in a ledger file, so these runs also prove that state
carries from one bridge process to the next.
"""

import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AUTH = "androidId=abc&Email=someone%40example.com&lang=en_US&Token=aas_et%2Ffake"


class FakeGpmcEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        # 2026-10-15: Native Windows runners have no /bin/bash; copying the
        # same fixture in Python tests the real protocol on both platforms.
        runtime = self.root / "runtime"
        runtime.mkdir()
        shutil.copy2(REPO / "Bridge/gpmc_bridge.py", runtime / "gpmc_bridge.py")
        shutil.copytree(REPO / "Tests/E2E/fake_gpmc", runtime / "site-packages",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        self.bridge = self.root / "runtime/gpmc_bridge.py"
        self.scenario = self.root / "scenario.json"
        self.ledger = self.root / "ledger.json"
        self.staging = self.root / "staging"
        self.staging.mkdir()

    def tearDown(self):
        self.scratch.cleanup()

    def given(self, **scenario):
        self.scenario.write_text(json.dumps({"ledger": str(self.ledger), **scenario}))

    def stage(self, *names):
        items = []
        for index, name in enumerate(names):
            path = self.staging / str(index) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"pixels of {name}".encode())
            items.append({"id": f"asset-{name}", "path": str(path), "filename": name})
        return items

    def popen(self, request):
        env = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP") if key in os.environ}
        env.update(HOME=str(self.root), USERPROFILE=str(self.root), LANG="en_US.UTF-8",
                   FAKE_GPMC_SCENARIO=str(self.scenario))
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        process = subprocess.Popen([sys.executable, "-I", "-B", str(self.bridge)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, env=env, cwd=self.root, creationflags=flags)
        process.stdin.write(json.dumps(request))
        process.stdin.close()
        process.stdin = None
        return process

    def send(self, request):
        process = self.popen(request)
        out, err = process.communicate(timeout=60)
        events = [json.loads(line) for line in out.splitlines()]
        return process.returncode, events, err

    def upload(self, items, **extra):
        return self.send({"command": "upload", "auth_data": AUTH, "items": items, "threads": 2, **extra})

    def ledger_data(self):
        return json.loads(self.ledger.read_text())

    @staticmethod
    def of_type(events, kind):
        return [e for e in events if e["type"] == kind]

    def test_version_names_the_fake(self):
        self.given()
        code, events, _ = self.send({"command": "version"})
        self.assertEqual(code, 0)
        self.assertEqual(events[0]["gpmc"], "0.9.0+fake")

    def test_uploads_once_then_finds_the_same_bytes_already_there(self):
        self.given()
        items = self.stage("a.jpg", "b.heic")
        code, events, err = self.upload(items)
        self.assertEqual(code, 0, err)
        self.assertEqual({e["id"]: e["status"] for e in self.of_type(events, "item")}, {"asset-a.jpg": "uploaded", "asset-b.heic": "uploaded"})

        # A second process, as the next run would start: Google has both.
        code, events, _ = self.upload(items)
        self.assertEqual({e["id"]: e["status"] for e in self.of_type(events, "item")}, {"asset-a.jpg": "existing", "asset-b.heic": "existing"})
        self.assertEqual(len(self.ledger_data()["media"]), 2)

    @unittest.skipUnless(os.name == "nt", "requires native Windows filesystem")
    def test_long_windows_source_uploads_then_maps_existing_result_to_original_id(self):
        self.given()
        normal = self.staging.joinpath(*(["long-device-folder" * 3] * 5), "camera-original.jpg")
        self.assertGreater(len(str(normal)), 260)
        extended = Path("\\\\?\\" + str(normal))
        extended.parent.mkdir(parents=True)
        # Remove the deep fixture through the same extended namespace before
        # TemporaryDirectory cleanup (also works with long paths disabled).
        try:
            payload = b"fixture camera bytes beyond MAX_PATH"
            extended.write_bytes(payload)
            self.assertEqual(extended.read_bytes(), payload)
            item = dict(id="persisted-device-key", path=str(normal), filename="camera-original.jpg")
            for status in ("uploaded", "existing"):
                code, events, err = self.upload([item], album=dict(name="Device import"))
                self.assertEqual(code, 0, err)
                self.assertEqual([(e["id"], e["status"]) for e in self.of_type(events, "item")],
                                 [(item["id"], status)])
                self.assertTrue(self.of_type(events, "progress"))
                self.assertTrue(all(e["id"] == item["id"] for e in self.of_type(events, "progress")))
                self.assertEqual(self.of_type(events, "item_failed"), [])
            self.assertEqual(len(self.ledger_data()["media"]), 1)
            self.assertEqual({u["filename"] for u in self.ledger_data()["uploads"]}, {item["filename"]})
            self.assertEqual(item["path"], str(normal))
        finally:
            shutil.rmtree("\\\\?\\" + str(self.staging / ("long-device-folder" * 3)))

    def test_rate_limited_and_flaky_files_are_retryable_and_then_go_through(self):
        self.given(rate_limit_first=1, flaky={"b.jpg": {"times": 1, "error": "reset"}},
                   fail={"c.jpg": "413 Client Error: Request Entity Too Large for url: https://x"})
        items = self.stage("a.jpg", "b.jpg", "c.jpg")
        _, events, _ = self.send({"command": "upload", "auth_data": AUTH, "items": items, "threads": 1})
        failed = {e["id"]: (e["retryable"], e["message"]) for e in self.of_type(events, "item_failed")}
        self.assertEqual(set(failed), {"asset-a.jpg", "asset-b.jpg", "asset-c.jpg"})
        self.assertTrue(failed["asset-a.jpg"][0])
        self.assertIn("429 Client Error", failed["asset-a.jpg"][1])
        self.assertTrue(failed["asset-b.jpg"][0])
        self.assertFalse(failed["asset-c.jpg"][0])

        _, events, _ = self.send({"command": "upload", "auth_data": AUTH, "items": items, "threads": 1})
        self.assertEqual(sorted(e["id"] for e in self.of_type(events, "item")), ["asset-a.jpg", "asset-b.jpg"])
        self.assertEqual([e["id"] for e in self.of_type(events, "item_failed")], ["asset-c.jpg"])

    def test_sign_in_answers(self):
        cases = [("refuse", "auth", 2), ("network", "network", 3), ("rate_limit", "rate_limit", 6), ("no_token", "auth", 2)]
        for auth, kind, exit_code in cases:
            self.given(auth=auth)
            code, events, _ = self.upload(self.stage("a.jpg"))
            self.assertEqual((code, events[-1]["type"], events[-1]["kind"]), (exit_code, "fatal", kind), auth)

    def test_check_auth_accepts_the_account(self):
        self.given()
        code, events, _ = self.send({"command": "check-auth", "auth_data": AUTH})
        self.assertEqual((code, events), (0, [{"type": "auth", "v": 1, "email": "someone@example.com"}]))

    def test_album_is_created_then_appended_to(self):
        self.given()
        _, events, _ = self.upload(self.stage("a.jpg"), album={"name": "Trip"})
        album_id = self.of_type(events, "album")[0]["album_id"]
        _, events, _ = self.upload(self.stage("b.jpg", "c.jpg"), album={"id": album_id, "name": "Trip"})
        self.assertEqual(self.of_type(events, "album")[0]["album_id"], album_id)
        albums = self.ledger_data()["albums"]
        self.assertEqual(list(albums), [album_id])
        self.assertEqual(len(albums[album_id]["media_keys"]), 3)

    def test_stop_keeps_what_was_confirmed(self):
        self.given(delay=0.4)
        process = self.popen({"command": "upload", "auth_data": AUTH, "items": self.stage("a.jpg", "b.jpg", "c.jpg", "d.jpg"), "threads": 1})
        events = []
        for line in process.stdout:
            events.append(json.loads(line))
            if events[-1]["type"] == "item":
                process.send_signal(signal.CTRL_BREAK_EVENT if os.name == "nt" else signal.SIGTERM)
                break
        events += [json.loads(line) for line in process.stdout]
        process.wait(timeout=30)
        process.stderr.close()
        process.stdout.close()

        self.assertEqual(process.returncode, 5)
        self.assertEqual(events[-1]["type"], "stopped")
        confirmed = self.of_type(events, "item")
        self.assertGreaterEqual(len(confirmed), 1)
        self.assertLess(len(confirmed), 4)
        # Everything reported as confirmed is what the fake Google holds.
        uploaded = [u for u in self.ledger_data()["uploads"] if u["status"] == "uploaded"]
        self.assertGreaterEqual(len(uploaded), len(confirmed))


if __name__ == "__main__":
    unittest.main()
