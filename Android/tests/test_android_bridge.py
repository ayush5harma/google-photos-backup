"""No network, credentials, Android runtime or installed gpmc needed."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Bridge"), str(ROOT / "Android/app/src/main/python")]
import gpmc_bridge
import android_bridge
class Listener:
    def __init__(self): self.events=[]
    def event(self,event): self.events.append(json.loads(event))
class Cancellation:
    def __init__(self,value=False): self.value=value
    def get(self): return self.value
class AdapterTests(unittest.TestCase):
    def test_cancelled_request_never_authenticates(self):
        listener=Listener()
        with patch.object(gpmc_bridge,"run") as run:
            self.assertEqual(android_bridge.run('{"command":"upload"}',listener,Cancellation(True)),gpmc_bridge.EXIT_STOPPED)
            run.assert_not_called()
    def test_midflight_cancel_persists_confirmation(self):
        listener=Listener(); cancellation=Cancellation()
        def fake_run(request,emit,stop):
            cancellation.value=True
            with self.assertRaises(gpmc_bridge.StopRequested): emit({"type":"item","media_key":"confirmed"})
            return gpmc_bridge.EXIT_STOPPED
        with patch.object(gpmc_bridge,"run",fake_run): android_bridge.run('{}',listener,cancellation)
        self.assertEqual(listener.events[0]["media_key"],"confirmed")
    def test_malformed_request_rejected_before_factory(self):
        listener=Listener()
        self.assertEqual(android_bridge.run('{"command":"upload","items":[]}',listener,Cancellation()),gpmc_bridge.EXIT_REQUEST)
        self.assertEqual(listener.events[-1]["type"],"fatal")
    def test_mocked_auth_accepts_only_after_photos_check(self):
        from types import SimpleNamespace
        listener=Listener()
        checked=[]
        client=SimpleNamespace(api=SimpleNamespace(bearer_token="synthetic", find_remote_media_by_hash=lambda value:checked.append(value)))
        result=gpmc_bridge.run({"command":"check-auth","auth_data":"Email=synthetic%40example.test&Token=synthetic"},lambda event:listener.event(json.dumps(event)),client_factory=lambda auth,timeout:client)
        self.assertEqual(result,gpmc_bridge.EXIT_OK)
        self.assertEqual(len(checked),1)
        self.assertEqual(listener.events[-1]["type"],"auth")
    def test_mocked_auth_error_never_emits_auth_success(self):
        listener=Listener()
        def refused(auth,timeout): raise ValueError("synthetic refusal")
        result=gpmc_bridge.run({"command":"check-auth","auth_data":"Email=synthetic%40example.test&Token=synthetic"},lambda event:listener.event(json.dumps(event)),client_factory=refused)
        self.assertNotEqual(result,gpmc_bridge.EXIT_OK)
        self.assertNotIn("auth",[event["type"] for event in listener.events])
class FakeSession:
    """A requests.Session stand-in: what gpmc's Api._new_session hands back."""
    def __init__(self, made):
        self.cookies = SimpleNamespace(clear=lambda: None)
        self.closed = False
        made.append(self)
    def __enter__(self): return self
    def __exit__(self, *exc): self.close()
    def close(self): self.closed = True


class FakeApi:
    bearer_token = "synthetic-not-a-credential"
    def __init__(self):
        self.made = []
        self.used = []
    def _new_session(self):
        return FakeSession(self.made)


class FakeClient:
    """Records every upload call. gpmc 0.9.0 makes about four calls per file,
    each through `with api._new_session()`, and so does this fake."""
    def __init__(self, barrier=None):
        self.api = FakeApi()
        self.calls = []
        self.barrier = barrier
        self._lock = threading.Lock()
    def upload(self, target, progress_callback, **kwargs):
        path = next(iter(target))
        with self._lock:
            self.calls.append(dict(kwargs, target=target, progress_callback=progress_callback))
        for _ in range(4):
            with self.api._new_session() as session:
                with self._lock:
                    self.api.used.append(session)
        if self.barrier is not None:
            # Every thread of the request must be busy at once, or this times out.
            self.barrier.wait(timeout=10)
        progress_callback({"path": path.as_posix(), "phase": "upload", "bytes_completed": 4, "bytes_total": 4})
        return {path.as_posix(): "key-" + path.name}


def upload_request(paths, threads, quality="original"):
    request = {"command": "upload", "auth_data": "Email=synthetic%40example.test&Token=synthetic",
               "threads": threads, "timeout": 60,
               "items": [{"id": path.name, "path": str(path), "filename": path.name} for path in paths]}
    if quality is not None:
        request["quality"] = quality
    return json.dumps(request)


class SessionTests(unittest.TestCase):
    """One BackupWorker run: one gpmc client and its kept connections (issue #59)."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def files(self, count, prefix="item"):
        paths = []
        for index in range(count):
            path = pathlib.Path(self.directory.name, f"{prefix}-{index}.jpg")
            path.write_bytes(b"synthetic")
            paths.append(path)
        return paths

    def test_original_commits_free_at_every_thread_count(self):
        # The hard constraint: Original quality is gpmc saver=False,
        # use_quota=False (Pixel XL, free) for every upload however many go at
        # once, through the kept client, and no other keyword reaches gpmc.
        for threads in range(1, 9):
            for quality in ("original", None):
                with self.subTest(threads=threads, quality=quality):
                    client = FakeClient(threading.Barrier(threads))
                    session = android_bridge.session(client_factory=lambda auth, timeout: client)
                    listener = Listener()
                    paths = self.files(2 * threads, prefix=f"t{threads}-{quality}")
                    try:
                        code = session.run(upload_request(paths, threads, quality), listener, Cancellation())
                    finally:
                        session.close()
                    self.assertEqual(code, gpmc_bridge.EXIT_OK)
                    self.assertEqual(sum(event["type"] == "item" for event in listener.events), len(paths))
                    self.assertEqual(len(client.calls), len(paths))
                    for call in client.calls:
                        self.assertEqual(set(call), {"target", "progress_callback", "saver", "use_quota", "threads", "force_upload"})
                        self.assertIs(call["saver"], False)
                        self.assertIs(call["use_quota"], False)
                        self.assertEqual(call["threads"], 1)
                        self.assertIs(call["force_upload"], False)

    def test_one_client_and_kept_connections_across_a_run(self):
        clients = []
        def factory(auth, timeout):
            clients.append(FakeClient())
            return clients[-1]
        session = android_bridge.session(client_factory=factory)
        for batch in range(3):
            listener = Listener()
            code = session.run(upload_request(self.files(6, prefix=f"b{batch}"), 3), listener, Cancellation())
            self.assertEqual(code, gpmc_bridge.EXIT_OK)
            self.assertEqual(sum(event["type"] == "item" for event in listener.events), 6)
        self.assertEqual(len(clients), 1, "a run signs in once")
        api = clients[0].api
        self.assertEqual(len(api.used), 3 * 6 * 4)
        # Kept connections: no more sessions than threads for 72 calls, none
        # closed while the run lasts, gpmc's own _new_session back between requests.
        self.assertLessEqual(len(api.made), 3)
        self.assertFalse(any(made.closed for made in api.made))
        self.assertNotIn("_new_session", vars(api))
        session.close()
        self.assertTrue(all(made.closed for made in api.made), "the worker's end closes the kept connections")

    def test_a_closed_session_signs_in_again(self):
        clients = []
        def factory(auth, timeout):
            clients.append(FakeClient())
            return clients[-1]
        session = android_bridge.session(client_factory=factory)
        session.run(upload_request(self.files(1, "first"), 1), Listener(), Cancellation())
        session.close()
        session.run(upload_request(self.files(1, "second"), 1), Listener(), Cancellation())
        session.close()
        self.assertEqual(len(clients), 2)

    def test_cancelled_session_request_never_authenticates(self):
        made = []
        session = android_bridge.session(client_factory=lambda auth, timeout: made.append(1))
        code = session.run(upload_request(self.files(1), 1), Listener(), Cancellation(True))
        session.close()
        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        self.assertEqual(made, [])

    def test_session_cancel_midflight_keeps_the_confirmation(self):
        cancellation = Cancellation()
        client = FakeClient()
        upload = client.upload
        def cancelling_upload(target, progress_callback, **kwargs):
            # Google has committed the file when the cancel arrives.
            result = upload(target, progress_callback, **kwargs)
            cancellation.value = True
            return result
        client.upload = cancelling_upload
        session = android_bridge.session(client_factory=lambda auth, timeout: client)
        listener = Listener()
        code = session.run(upload_request(self.files(1), 1), listener, cancellation)
        session.close()
        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        self.assertEqual([event["media_key"] for event in listener.events if event["type"] == "item"], ["key-item-0.jpg"])


if __name__ == '__main__': unittest.main()
