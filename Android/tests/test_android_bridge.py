"""No network, credentials, Android runtime or installed gpmc needed."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
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
if __name__ == '__main__': unittest.main()
