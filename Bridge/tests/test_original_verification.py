"""Destructive consumers must fail closed on wrong, partial or changed originals."""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gpmc_bridge as bridge


class Response:
    def __init__(self, data=b'original', status=200, location=None):
        self.data, self.status_code = data, status
        self.headers = {'Location': location} if location else {}
        self.closed = False
    def iter_content(self, size):
        yield self.data
    def close(self):
        self.closed = True


class Session:
    def __init__(self, responses):
        self.responses = responses
        self.headers, self.cookies, self.calls = {}, {}, []
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self.responses.pop(0)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'original.png'
        self.path.write_bytes(b'original')
        self.item = dict(id='fixture', path=str(self.path), media_key='key')
    def client(self, responses=None, url='https://lh3.googleusercontent.com/original?secret=hidden'):
        self.session = Session(responses or [Response()])
        return SimpleNamespace(api=SimpleNamespace(bearer_token='secret',
            get_download_urls=lambda key: {'1': {'5': {'2': {'6': url, '5': 'https://evil.test/edited'}}}},
            _new_session=lambda: self.session))
    def test_exact_original_matches(self):
        proof = bridge.verify_original(self.client(), self.item)
        self.assertEqual(proof['bytes'], 8)
        self.assertEqual(proof['sha256'], hashlib.sha256(b'original').hexdigest())
        self.assertNotIn('Authorization', self.session.calls[0][1]['headers'])
        self.assertFalse(self.session.calls[0][1]['allow_redirects'])
    def test_partial_extra_and_wrong_bytes_retain_source(self):
        for data in (b'orig', b'originalextra', b'changed!'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                bridge.verify_original(self.client([Response(data)]), self.item)
        self.assertEqual(self.path.read_bytes(), b'original')
    def test_untrusted_initial_urls(self):
        for url in ('http://lh3.googleusercontent.com/x', 'https://googleusercontent.com.evil.test/x',
                    'https://user:pass@lh3.googleusercontent.com/x', 'https://localhost/x'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                bridge.verify_original(self.client(url=url), self.item)
            self.assertEqual(self.session.calls, [])
    def test_redirect_is_checked_before_request(self):
        response = Response(status=302, location='https://evil.test/private')
        with self.assertRaises(ValueError):
            bridge.verify_original(self.client([response]), self.item)
        self.assertEqual(len(self.session.calls), 1)
        self.assertTrue(response.closed)
    def test_missing_original_does_not_fall_back_to_edited(self):
        client = self.client()
        client.api.get_download_urls = lambda key: {'1': {'5': {'2': {'5': 'edited'}}}}
        with self.assertRaises(KeyError): bridge.verify_original(client, self.item)
        self.assertEqual(self.session.calls, [])
    def test_changed_preview(self):
        with self.assertRaises(ValueError):
            bridge.verify_original(self.client(), dict(self.item, expected_sha256='0'*64))
        self.assertEqual(self.session.calls, [])
    def test_changed_source_during_readback(self):
        response = Response()
        def chunks(size):
            self.path.write_bytes(b'replaced')
            yield b'original'
        response.iter_content = chunks
        with self.assertRaises(ValueError): bridge.verify_original(self.client([response]), self.item)
    def test_cancellation(self):
        stop = bridge.StopSignal()
        stop.requested = True
        with self.assertRaises(bridge.StopRequested): bridge.verify_original(self.client(), self.item, stop)
    def test_protocol_failure_is_sanitized_and_nonzero(self):
        events = []
        client = self.client(url='https://evil.test/?secret=do-not-log')
        result = bridge.run(dict(command='verify-original', auth_data='Email=test@example.com', items=[self.item]),
                            events.append, client_factory=lambda *_: client)
        self.assertNotEqual(result, 0)
        self.assertEqual(events[-1]['failed'], 1)
        self.assertNotIn('do-not-log', str(events))


if __name__ == '__main__': unittest.main()
