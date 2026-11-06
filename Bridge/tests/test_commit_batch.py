"""CommitBatcher: upload threads' commits go to Google as one call.

The api here is a stand-in whose module offers what gpmc.api offers the
batcher (encode_message, decode_message, message_types.COMMIT_UPLOAD), with
JSON for protobuf. What real gpmc puts on the wire is pinned by
test_original_real_gpmc.py.
"""

import json
import sys
import threading
import time
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gpmc_bridge  # noqa: E402

message_types = types.SimpleNamespace(COMMIT_UPLOAD={})


def _plain(value):
    if isinstance(value, bytes):
        return {"bytes": value.hex()}
    if isinstance(value, dict):
        return {key: _plain(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_plain(item) for item in value]
    return value


def encode_message(body, typedef):
    return json.dumps(_plain(body)).encode()


def decode_message(content, typedef=None):
    return json.loads(content), typedef


class Response:
    def __init__(self, status, body):
        self.status_code, self.content = status, json.dumps(body).encode()

    def raise_for_status(self):
        if self.status_code >= 400:
            raise gpmc_bridge.RequestError(f"{self.status_code} Server Error")


class Session:
    def __init__(self, api):
        self.api = api

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def post(self, url, headers, data, timeout):
        return self.api.google(url, headers, json.loads(data))


class BatchApi:
    model, make, android_api_version = "Pixel XL", "Google", 28
    language, user_agent, timeout, bearer_token = "en_US", "photos", 60, "bearer"

    def __init__(self, answer=None, single_error=None):
        self.answer = answer or self.in_reverse
        self.single_error = single_error or {}
        self.batches, self.singles = [], []
        self.lock = threading.Lock()

    def _new_session(self):
        return Session(self)

    def commit_upload(self, upload_response_decoded, file_name, sha1_hash, quality="original", make=None,
                      model=None, upload_timestamp=None):
        with self.lock:
            self.singles.append(file_name)
        if file_name in self.single_error:
            raise self.single_error[file_name]
        return f"single-{file_name}"

    def google(self, url, headers, body):
        self.assertions(url, headers, body)
        with self.lock:
            self.batches.append([item["2"] for item in body["1"]])
        return self.answer(body["1"])

    @staticmethod
    def assertions(url, headers, body):
        assert url == gpmc_bridge.COMMIT_URL, url
        assert headers["Authorization"] == "Bearer bearer"
        assert body["2"] == {"3": "Pixel XL", "4": "Google", "5": 28}, body["2"]
        assert all(item["7"] == 3 for item in body["1"])

    @staticmethod
    def in_reverse(items):
        # Answered out of order, so only the echoed token can match them up.
        results = [{"1": item["1"], "2": 0, "3": {"1": f"batch-{item['2']}"}} for item in items]
        return Response(200, {"1": results[::-1]})


class Client:
    def __init__(self, api):
        self.api = api


def commit_all(client, names, threads=None, keep=True):
    """Commit `names` from as many threads as there are names; return each
    name's key or the exception it raised."""
    threads = threads or len(names)

    def commit(name):
        try:
            return client.api.commit_upload(upload_response_decoded={"1": 1, "2": name}, file_name=name,
                                             sha1_hash=name.encode(), quality="original", model="Pixel XL")
        except Exception as error:
            return error

    with gpmc_bridge._batched_commits(client, threads, keep):
        with ThreadPoolExecutor(len(names)) as pool:
            return dict(zip(names, pool.map(commit, names)))


class CommitBatcherTests(unittest.TestCase):
    def test_threads_commits_go_out_as_one_call_and_each_gets_its_own_key(self):
        api = BatchApi()
        names = [f"IMG_{n}.JPG" for n in range(6)]
        keys = commit_all(Client(api), names)

        self.assertEqual(keys, {name: f"batch-{name}" for name in names})
        self.assertEqual([sorted(b) for b in api.batches], [sorted(names)])
        self.assertEqual(api.singles, [])

    def test_a_batch_never_exceeds_the_measured_size(self):
        api = BatchApi()
        names = [f"IMG_{n}.JPG" for n in range(45)]
        keys = commit_all(Client(api), names, threads=32)

        self.assertEqual(keys, {name: f"batch-{name}" for name in names})
        self.assertLessEqual(max(len(b) for b in api.batches), gpmc_bridge.COMMIT_BATCH)
        self.assertEqual(sum(len(b) for b in api.batches), 45)

    def test_a_refused_batch_is_committed_one_at_a_time(self):
        error = gpmc_bridge.RequestError("500 Server Error: Internal Server Error for url: commit")
        api = BatchApi(answer=lambda items: Response(500, {}), single_error={"IMG_2.JPG": error})
        names = [f"IMG_{n}.JPG" for n in range(4)]
        keys = commit_all(Client(api), names)

        self.assertEqual(len(api.batches), 1)
        self.assertEqual(sorted(api.singles), sorted(names))
        # Each file gets what gpmc's own commit gave it, its error included.
        self.assertIs(keys.pop("IMG_2.JPG"), error)
        self.assertEqual(keys, {name: f"single-{name}" for name in keys})

    def test_an_item_answered_without_a_key_is_committed_alone(self):
        def one_refused(items):
            return Response(200, {"1": [{"1": item["1"], "2": 3} if item["2"] == "IMG_1.JPG"
                                        else {"1": item["1"], "2": 0, "3": {"1": f"batch-{item['2']}"}} for item in items]})

        api = BatchApi(answer=one_refused)
        names = [f"IMG_{n}.JPG" for n in range(3)]
        keys = commit_all(Client(api), names)

        self.assertEqual(api.singles, ["IMG_1.JPG"])
        self.assertEqual(keys, {"IMG_0.JPG": "batch-IMG_0.JPG", "IMG_1.JPG": "single-IMG_1.JPG", "IMG_2.JPG": "batch-IMG_2.JPG"})

    def test_an_answer_without_tokens_is_matched_by_position(self):
        api = BatchApi(answer=lambda items: Response(200, {"1": [{"3": {"1": f"batch-{item['2']}"}} for item in items]}))
        names = [f"IMG_{n}.JPG" for n in range(3)]
        self.assertEqual(commit_all(Client(api), names), {name: f"batch-{name}" for name in names})

    def test_one_shot_requests_and_one_thread_keep_gpmcs_own_commit(self):
        for threads, keep in ((4, False), (1, True)):
            api = BatchApi()
            with gpmc_bridge._batched_commits(Client(api), threads, keep) as batcher:
                self.assertIsNone(batcher)
                self.assertNotIn("commit_upload", vars(api))

    def test_an_api_without_gpmcs_codec_is_left_alone(self):
        import test_bridge

        client = test_bridge.FakeClient()
        with gpmc_bridge._batched_commits(client, 8, True) as batcher:
            self.assertIsNone(batcher)

    def test_the_request_ending_releases_a_waiting_commit_and_restores_gpmcs(self):
        api = BatchApi()
        client = Client(api)
        outcome = []

        def commit():
            try:
                outcome.append(client.api.commit_upload(upload_response_decoded={"1": 1}, file_name="IMG_0.JPG", sha1_hash=b"x"))
            except Exception as error:
                outcome.append(error)

        # A stop: the request ends while one commit is still gathering (one of
        # eight threads, inside COMMIT_GATHER_SECONDS).
        with gpmc_bridge._batched_commits(client, 8, True) as batcher:
            waiter = threading.Thread(target=commit)
            waiter.start()
            while not batcher._pending:
                time.sleep(0.001)
        waiter.join(5)

        self.assertFalse(waiter.is_alive())
        self.assertIsInstance(outcome[0], RuntimeError)
        self.assertEqual(api.batches, [])
        self.assertNotIn("commit_upload", vars(api))


if __name__ == "__main__":
    unittest.main()
