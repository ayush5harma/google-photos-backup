"""The paths issue #50 added for throughput: serve sessions and kept sessions,
held to the one thing they must not change, the flags every upload sends.

`quality: "original"` reaches gpmc as saver=False, use_quota=False, which
gpmc 0.9.0 commits as a Pixel XL at original quality: the upload does not
count against the account's storage. QualityGuardTests fail if any upload,
on any path, reaches gpmc with other flags or with anything that could pick
another device or quality.
"""

import io
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import gpmc_bridge  # noqa: E402
from test_bridge import AUTH, FakeApi, FakeClient, items, of_type, run  # noqa: E402

OTHER_AUTH = AUTH.replace("someone", "another")
# Everything the bridge may hand gpmc's Client.upload besides the progress
# callback; a key outside this set (a model, a make, a quality) fails.
UPLOAD_KWARGS = {"target", "saver", "use_quota", "threads", "force_upload"}


class FakeSession:
    """Counts what a kept session must keep clean between calls."""

    made = 0

    def __init__(self):
        FakeSession.made += 1
        self.cookies = {}
        self.uses = 0
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        self.closed = True


class SessionApi(FakeApi):
    """A FakeApi whose upload calls go through _new_session like gpmc's."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.sessions_seen = []

    def _new_session(self):
        return FakeSession()


class SessionClient(FakeClient):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        api = SessionApi()
        api.client = self
        self.api = api

    def upload(self, target, progress_callback=None, **kwargs):
        # Four calls per file, as gpmc 0.9.0 makes them.
        for _ in range(4):
            with self.api._new_session() as session:
                self.api.sessions_seen.append(session)
                if session.cookies:
                    raise AssertionError("a kept session carried cookies into another call")
                session.cookies["NID"] = "set-by-google"
                session.uses += 1
        return super().upload(target, progress_callback=progress_callback, **kwargs)


def serve(lines, client=None, clients=None, stop=None, on_event=None):
    """Run a serve session over `lines` in process; returns code, events, factory calls."""
    events, calls = [], []
    clients = clients or [client]

    def factory(auth_data, timeout):
        calls.append((auth_data, timeout))
        made = clients[min(len(calls), len(clients)) - 1]
        if isinstance(made, Exception):
            raise made
        return made

    def write(event):
        events.append(event)
        if on_event:
            on_event(event)

    text = "".join((line if isinstance(line, str) else json.dumps(line)) + "\n" for line in lines)
    code = gpmc_bridge.serve(io.StringIO(text), write, stop or gpmc_bridge.StopSignal(), client_factory=factory)
    return code, events, calls


def answers(events):
    """Split a session's events into one list per request, at each served."""
    out, current = [], []
    for event in events:
        if event["type"] == "served":
            out.append((event["code"], current))
            current = []
        else:
            current.append(event)
    return out


def upload(names, **extra):
    return {"command": "upload", "auth_data": AUTH, "items": items(*names), **extra}


class QualityGuardTests(unittest.TestCase):
    def test_original_is_the_free_pixel_xl_path(self):
        self.assertEqual(gpmc_bridge.QUALITIES["original"], (False, False))
        self.assertEqual(gpmc_bridge.upload_flags("original"), {"saver": False, "use_quota": False})

    def assert_original(self, client, context):
        self.assertTrue(client.upload_calls, context)
        for call in client.upload_calls:
            self.assertEqual((call["saver"], call["use_quota"]), (False, False), context)
            self.assertLessEqual(set(call), UPLOAD_KWARGS, context)
            self.assertEqual(call["threads"], 1, context)

    def test_the_thread_ceiling_is_sixteen(self):
        # A literal, so the ceiling cannot move without this guard being read:
        # every count up to it is exercised below, and one past it is refused.
        self.assertEqual(gpmc_bridge.MAX_THREADS, 16)
        for threads in (0, 17):
            client = FakeClient()
            _, events, _ = serve([upload(["a.jpg"], threads=threads)], client)
            self.assertEqual(client.upload_calls, [], threads)
            self.assertEqual(answers(events)[0][0], gpmc_bridge.EXIT_REQUEST, threads)

    def test_no_upload_path_sends_other_flags_for_original(self):
        for threads in range(1, 17):
            for quality in ({}, {"quality": "original"}):
                for force in ({}, {"force": True}):
                    request = upload(["a.jpg", "b.jpg", "c.jpg"], threads=threads, **quality, **force)
                    request["items"][1]["force"] = True
                    context = f"threads={threads} {quality} {force}"
                    for client_type in (FakeClient, SessionClient):
                        client = client_type()
                        run(request, client)
                        self.assert_original(client, f"one-shot {client_type.__name__} {context}")
                        client = client_type()
                        code, _, _ = serve([request, request, upload(["d.jpg"], album={"name": "Trip"}, **quality)], client)
                        self.assertEqual(code, gpmc_bridge.EXIT_OK)
                        self.assertEqual(len(client.upload_calls), 7)
                        self.assert_original(client, f"serve {client_type.__name__} {context}")

    def test_the_guard_notices_a_different_quality(self):
        # The same check, pointed at the paid path, must fail: it is not vacuous.
        client = FakeClient()
        serve([upload(["a.jpg"], quality="quota")], client)
        with self.assertRaises(AssertionError):
            self.assert_original(client, "quota")

    def test_one_call_site_builds_every_upload_from_upload_flags(self):
        source = Path(gpmc_bridge.__file__).read_text()
        calls = re.findall(r"\bclient\.upload\((.*?)\n\s*\)", source, re.DOTALL)
        self.assertEqual(len(calls), 1)
        self.assertIn("**flags,", calls[0])
        self.assertEqual(re.findall(r"\b(?:saver|use_quota|quality|model|make)\s*=", calls[0]), [])
        self.assertIn("flags = upload_flags(quality)", source)


class ServeTests(unittest.TestCase):
    def test_requests_share_one_client_and_each_ends_with_served(self):
        client = FakeClient(existing={"b.jpg"})
        code, events, calls = serve([upload(["a.jpg"]), upload(["b.jpg"]), {"command": "version"}], client)

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual(calls, [(AUTH, 60)])
        replies = answers(events)
        self.assertEqual([code for code, _ in replies], [0, 0, 0])
        self.assertEqual([e["status"] for e in of_type(replies[0][1], "item")], ["uploaded"])
        self.assertEqual([e["status"] for e in of_type(replies[1][1], "item")], ["existing"])
        self.assertEqual(replies[1][1][-1]["type"], "done")
        self.assertEqual(replies[2][1][0]["type"], "version")

    def test_each_answer_is_what_a_one_shot_bridge_says(self):
        request = upload(["a.jpg", "b.jpg"], album={"name": "Trip"})
        _, one_shot, _ = run(request, FakeClient(failing={"b.jpg"}))
        _, events, _ = serve([request], FakeClient(failing={"b.jpg"}))
        self.assertEqual(answers(events), [(0, one_shot)])

    def test_a_line_that_is_not_a_request_is_refused_and_the_session_goes_on(self):
        code, events, _ = serve(["{not json", {"command": "serve"}, upload(["a.jpg"])], FakeClient())
        replies = answers(events)
        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual([code for code, _ in replies], [gpmc_bridge.EXIT_REQUEST, gpmc_bridge.EXIT_REQUEST, 0])
        self.assertEqual([e["kind"] for _, reply in replies[:2] for e in reply], ["request", "request"])

    def test_a_failed_sign_in_is_not_kept(self):
        client = FakeClient()
        code, events, calls = serve([upload(["a.jpg"]), upload(["a.jpg"])], clients=[ConnectionError("unreachable"), client])
        replies = answers(events)
        self.assertEqual([code for code, _ in replies], [gpmc_bridge.EXIT_NETWORK, 0])
        self.assertEqual(len(calls), 2)

    def test_another_credential_gets_its_own_client(self):
        first, second = SessionClient(), SessionClient()
        other = dict(upload(["b.jpg"]), auth_data=OTHER_AUTH)
        serve([upload(["a.jpg"]), other], clients=[first, second])
        self.assertEqual(len(first.upload_calls), 1)
        self.assertEqual(len(second.upload_calls), 1)
        # The first account's connections close when its client is replaced.
        self.assertTrue(all(session.closed for session in first.api.sessions_seen))

    def test_a_stop_ends_the_session_after_reporting_what_was_confirmed(self):
        stop = gpmc_bridge.StopSignal()

        def stop_after_first_item(event):
            if event["type"] == "item":
                stop.request()

        client = FakeClient()
        code, events, _ = serve([upload(["a.jpg", "b.jpg"]), upload(["c.jpg"])], client, stop=stop, on_event=stop_after_first_item)

        self.assertEqual(code, gpmc_bridge.EXIT_STOPPED)
        replies = answers(events)
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0][0], gpmc_bridge.EXIT_STOPPED)
        self.assertEqual(replies[0][1][-1]["type"], "stopped")
        # The request after the stop is never read, let alone uploaded.
        sent = [options["filename"] for call in client.upload_calls for options in call["target"].values()]
        self.assertNotIn("c.jpg", sent)

    def test_nothing_reaches_a_request_after_its_answer_ended(self):
        written = []
        gate = gpmc_bridge._Gate(written.append)
        gate.emit({"type": "done"})
        gate.emit({"type": "item"})
        gate.close()
        gate.emit({"type": "progress"})
        self.assertEqual(written, [{"type": "done"}])


class KeptSessionTests(unittest.TestCase):
    def setUp(self):
        FakeSession.made = 0

    def test_files_and_requests_reuse_sessions_without_their_cookies(self):
        client = SessionClient()
        names = [f"{n}.jpg" for n in range(12)]
        code, _, _ = serve([upload(names[:6], threads=3), upload(names[6:], threads=3)], client)

        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual(len(client.api.sessions_seen), 48)
        # At most one session per thread, across both requests.
        self.assertLessEqual(FakeSession.made, 3)
        self.assertGreater(max(session.uses for session in client.api.sessions_seen), 4)
        # The session ended with the serve session.
        self.assertTrue(all(session.closed for session in client.api.sessions_seen))

    def test_outside_uploads_the_api_makes_fresh_sessions_again(self):
        client = SessionClient()
        serve([upload(["a.jpg"])], client)
        # verify_original clears a session's headers and retries: it must
        # never get, or give back, a kept one.
        self.assertNotIn("_new_session", vars(client.api))
        self.assertIsInstance(client.api._new_session(), FakeSession)

    def test_sixteen_threads_keep_sixteen_sessions_without_reopening_any(self):
        # Every thread holds its own session while it works; all of them must
        # fit in the idle list when the round ends, or the surplus is closed
        # and a new connection opened for the next round.
        pool = gpmc_bridge.SessionPool(FakeSession)
        held = [pool.checkout() for _ in range(gpmc_bridge.MAX_THREADS)]
        for session in held:
            session.close()
        self.assertEqual(FakeSession.made, 16)
        self.assertFalse(any(session.closed for session in held))
        again = [pool.checkout() for _ in range(gpmc_bridge.MAX_THREADS)]
        self.assertEqual(FakeSession.made, 16)
        self.assertEqual({id(s) for s in again}, {id(s) for s in held})

    def test_sixteen_upload_threads_make_at_most_sixteen_sessions(self):
        client = SessionClient()
        names = [f"{n}.jpg" for n in range(48)]
        code, _, _ = serve([upload(names, threads=16)], client)
        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual(len(client.api.sessions_seen), 48 * 4)
        self.assertLessEqual(FakeSession.made, 16)

    def test_a_one_shot_request_keeps_gpmcs_fresh_sessions(self):
        # PR #52 review: the Windows app and the Android app's run() are one
        # request each, and they stay as they were: a session per call.
        client = SessionClient()
        code, _, _ = run(upload(["a.jpg", "b.jpg"], threads=2), client)
        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual(FakeSession.made, 8)
        self.assertEqual(len({id(session) for session in client.api.sessions_seen}), 8)
        self.assertFalse(hasattr(client, gpmc_bridge._POOL_ATTRIBUTE))
        self.assertTrue(all(session.closed for session in client.api.sessions_seen))

    def test_a_session_idle_too_long_is_closed_not_reused(self):
        # PR #52 review: a connection Google closed while the app exported
        # the next batch failed its next POST, which urllib3 does not retry.
        pool = gpmc_bridge.SessionPool(FakeSession)
        clock = [1000.0]
        with mock.patch.object(gpmc_bridge, "_monotonic", lambda: clock[0]):
            first = pool.checkout()
            first.close()
            clock[0] += gpmc_bridge.MAX_IDLE_SECONDS - 1
            again = pool.checkout()
            self.assertIs(again, first, "a session idle for less than the limit is reused")
            again.close()
            clock[0] += gpmc_bridge.MAX_IDLE_SECONDS + 1
            fresh = pool.checkout()
        self.assertIsNot(fresh, first)
        self.assertTrue(first.closed, "the stale session's connection is closed, not left open")
        self.assertFalse(fresh.closed)

    def test_an_api_without_new_session_still_uploads(self):
        client = FakeClient()
        code, _, _ = run(upload(["a.jpg"]), client)
        self.assertEqual(code, gpmc_bridge.EXIT_OK)
        self.assertEqual(len(client.upload_calls), 1)


class ExpiringApi:
    """gpmc 0.9.0's bearer_token as it is (gpmc/api.py): whichever thread
    finds the token expired renews it, with no lock."""

    def __init__(self):
        self.auth_response_cache = {"Expiry": "0", "Auth": ""}
        self.sign_ins = 0
        self._count = threading.Lock()

    @property
    def bearer_token(self):
        if int(self.auth_response_cache.get("Expiry", "0")) <= int(time.time()):
            self.auth_response_cache = self._get_auth_token()
        if token := self.auth_response_cache.get("Auth", ""):
            return token
        raise RuntimeError("Auth response does not contain bearer token")

    def _get_auth_token(self):
        with self._count:
            self.sign_ins += 1
        # Google takes a moment to answer; the threads meet meanwhile.
        time.sleep(0.1)
        return {"Expiry": str(int(time.time()) + 3600), "Auth": "bearer"}


class TokenRenewalTests(unittest.TestCase):
    """PR #52 review: a serve session outlives its token, and every upload
    thread that found it expired signed in again at once."""

    def read_from_threads(self, api, threads=gpmc_bridge.MAX_THREADS):
        barrier = threading.Barrier(threads)

        def read(_):
            barrier.wait()
            return api.bearer_token

        with ThreadPoolExecutor(max_workers=threads) as pool:
            return list(pool.map(read, range(threads)))

    def test_an_expired_token_is_renewed_once_for_every_thread(self):
        api = ExpiringApi()
        gpmc_bridge._renew_one_at_a_time(api)
        tokens = self.read_from_threads(api)
        self.assertEqual(api.sign_ins, 1)
        self.assertEqual(tokens, ["bearer"] * gpmc_bridge.MAX_THREADS)

    def test_the_new_token_is_in_place_before_the_next_thread_looks(self):
        # Review of the fix: gpmc stores the token only after the renewal
        # returns, so a thread let in before that renewed again.
        api = ExpiringApi()
        gpmc_bridge._renew_one_at_a_time(api)
        api._get_auth_token()
        self.assertEqual(api.auth_response_cache["Auth"], "bearer")
        api._get_auth_token()
        self.assertEqual(api.sign_ins, 1)

    def test_gpmc_alone_signs_in_from_every_thread(self):
        # The fake has gpmc's race, so the test above is not vacuous.
        api = ExpiringApi()
        self.read_from_threads(api)
        self.assertGreater(api.sign_ins, 1)

    def test_every_request_of_a_session_connects_through_it_once(self):
        client = FakeClient()
        client.api = ExpiringApi()
        request = {"auth_data": AUTH}
        gpmc_bridge._connect(request, lambda auth_data, timeout: client)
        renew = client.api._get_auth_token
        gpmc_bridge._connect(request, lambda auth_data, timeout: client)
        self.assertIs(client.api._get_auth_token, renew, "wrapped once, not once per request")
        self.assertEqual(client.api.sign_ins, 1)

    def test_an_api_without_gpmcs_renewal_is_left_alone(self):
        api = FakeApi()
        gpmc_bridge._renew_one_at_a_time(api)
        self.assertFalse(hasattr(api, "_get_auth_token"))


class ServeProcessTests(unittest.TestCase):
    """main() over a real pipe."""

    def bridge(self, text):
        script = Path(gpmc_bridge.__file__)
        return subprocess.run([sys.executable, "-I", str(script)], input=text, capture_output=True, text=True, timeout=60)

    def test_a_serve_session_answers_line_by_line_until_stdin_closes(self):
        lines = [{"command": "serve"}, {"command": "version"}, {"command": "version"}]
        proc = self.bridge("".join(json.dumps(line) + "\n" for line in lines))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        events = [json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual([e["type"] for e in events], ["version", "served", "version", "served"])
        self.assertEqual([e["code"] for e in of_type(events, "served")], [0, 0])

    @unittest.skipIf(os.name == "nt", "a console read is not interrupted by CTRL_BREAK on Windows")
    def test_a_stop_between_requests_ends_the_session_with_stopped(self):
        script = Path(gpmc_bridge.__file__)
        process = subprocess.Popen([sys.executable, "-I", str(script)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        process.stdin.write(json.dumps({"command": "serve"}) + "\n" + json.dumps({"command": "version"}) + "\n")
        process.stdin.flush()
        answered = [json.loads(process.stdout.readline()) for _ in range(2)]
        # Idle in readline, stdin still open: what a run's Stop finds.
        process.send_signal(signal.SIGTERM)
        rest = [json.loads(line) for line in process.stdout]
        process.wait(timeout=30)
        process.stdin.close()
        process.stdout.close()
        process.stderr.close()

        self.assertEqual([e["type"] for e in answered], ["version", "served"])
        self.assertEqual([e["type"] for e in rest], ["stopped"])
        self.assertEqual(process.returncode, gpmc_bridge.EXIT_STOPPED)

    def test_a_request_spread_over_lines_is_still_one_request(self):
        proc = self.bridge(json.dumps({"command": "version"}, indent=2))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([json.loads(line)["type"] for line in proc.stdout.splitlines()], ["version"])


if __name__ == "__main__":
    unittest.main()
