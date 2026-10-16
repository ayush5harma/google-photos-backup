"""Windows I/O paths may be extended; protocol identity must stay unchanged."""
import hashlib
import logging
import ntpath
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gpmc_bridge as bridge
from test_bridge import AUTH, FakeClient, of_type, run
from test_original_verification import Response, Session


class WindowsPathTests(unittest.TestCase):
    def test_filesystem_normalization_accepts_drive_unc_and_extended_paths(self):
        with patch.object(bridge.sys, 'platform', 'win32'):
            cases = [
                (r'C:\stage\folder\..\photo.jpg', r'\\?\C:\stage\photo.jpg'),
                ('C:/stage/photo.jpg', r'\\?\C:\stage\photo.jpg'),
                (r'\\server\share\folder\..\photo.jpg', r'\\?\UNC\server\share\photo.jpg'),
                ('//server/share/photo.jpg', r'\\?\UNC\server\share\photo.jpg'),
                (r'\\?\C:\stage\photo.jpg', r'\\?\C:\stage\photo.jpg'),
                (r'\\?\UNC\server\share\photo.jpg', r'\\?\UNC\server\share\photo.jpg'),
            ]
            for original, expected in cases:
                with self.subTest(original=original):
                    self.assertEqual(bridge._filesystem_path(original), expected)

    def test_posix_filesystem_paths_are_unchanged(self):
        with patch.object(bridge.sys, 'platform', 'darwin'):
            for path in ('/tmp/a/../photo.jpg', 'relative/photo.jpg', r'/tmp/a\b.jpg'):
                self.assertEqual(bridge._filesystem_path(path), path)

    def test_device_namespace_is_rejected_instead_of_becoming_a_unc_share(self):
        with patch.object(bridge.sys, 'platform', 'win32'):
            for path in (r'\\.\PhysicalDrive0', '//./C:/photo.jpg'):
                with self.subTest(path=path), self.assertRaisesRegex(bridge.RequestError, 'device namespace'):
                    bridge._filesystem_path(path)

    def test_native_posix_and_extended_windows_spellings_share_a_key(self):
        with patch.object(bridge.sys, 'platform', 'win32'):
            for native, extended in [
                (r'C:\Stage\photo.jpg', '//?/C:/stage/photo.jpg'),
                (r'\\SERVER\Share\photo.jpg', '//?/UNC/server/share/photo.jpg'),
            ]:
                self.assertEqual(bridge._path_key(native), bridge._path_key(extended))
                self.assertEqual(bridge._path_key(native.replace('\\', '/')), bridge._path_key(extended))

    def test_upload_maps_progress_results_and_failures_to_original_ids(self):
        class SpellingClient(FakeClient):
            def upload(self, target, progress_callback=None, **kwargs):
                self.upload_calls.append(dict(kwargs, target=target))
                path, options = next(iter(target.items()))
                native = str(path)
                self_test.assertTrue(native.startswith('\\\\?\\'))
                # Exercise gpmc native failure logs, normal POSIX progress,
                # and extended POSIX result keys within the same request.
                normal = native[8:] if native.startswith('\\\\?\\UNC\\') else native[4:]
                if native.startswith('\\\\?\\UNC\\'):
                    normal = '\\\\' + normal
                event_path = normal.replace('\\', '/')
                progress_callback(dict(path=event_path, phase='skipped'))
                if options['filename'] == 'failed.jpg':
                    logging.getLogger().error('Error uploading file %s: 429 Client Error', native)
                    return {}
                return {native.replace('\\', '/'): 'confirmed-key'}

        self_test = self
        for original in (r'C:\Stage\photo.jpg', r'\\server\share\photo.jpg'):
            with self.subTest(path=original), patch.object(bridge.sys, 'platform', 'win32'):
                selected = [dict(id='persisted-device-key', path=original, filename='original-name.jpg'),
                            dict(id='persisted-failed-key', path=ntpath.join(ntpath.dirname(original), 'failed.jpg'), filename='failed.jpg')]
                before = [dict(item) for item in selected]
                client = SpellingClient()
                code, events, _ = run(dict(command='upload', auth_data=AUTH, items=selected, album=dict(name='Trip')), client)
                self.assertEqual(code, 0)
                self.assertEqual(selected, before)
                self.assertEqual([(e['id'], e['status'], e['media_key']) for e in of_type(events, 'item')],
                                 [('persisted-device-key', 'existing', 'confirmed-key')])
                failed = of_type(events, 'item_failed')
                self.assertEqual([(e['id'], e['message'], e['retryable']) for e in failed],
                                 [('persisted-failed-key', '429 Client Error', True)])
                self.assertEqual({e['id'] for e in of_type(events, 'progress')}, {item['id'] for item in selected})
                self.assertEqual({next(iter(call['target'].values()))['filename'] for call in client.upload_calls},
                                 {'original-name.jpg', 'failed.jpg'})
                self.assertEqual(client.album_calls, [('name', 'Trip', ['confirmed-key'])])


@unittest.skipUnless(os.name == 'nt', 'requires native Windows filesystem')
class WindowsLongPathVerificationTests(unittest.TestCase):
    def test_original_verification_opens_and_reopens_a_source_over_260_characters(self):
        import shutil
        import tempfile
        from types import SimpleNamespace

        with tempfile.TemporaryDirectory() as scratch:
            # Create using an explicit extended path, even with longPathsEnabled=0.
            normal = ntpath.join(scratch, *(['source-segment' * 4] * 5), 'photo.jpg')
            extended = Path('\\\\?\\' + normal)
            self.assertGreater(len(normal), 260)
            extended.parent.mkdir(parents=True)
            try:
                payload = b'original bytes at a Windows long path'
                extended.write_bytes(payload)
                session = Session([Response(payload)])
                client = SimpleNamespace(api=SimpleNamespace(
                    get_download_urls=lambda key: {'1': {'5': {'2': {'6': 'https://lh3.googleusercontent.com/original'}}}},
                    _new_session=lambda: session))
                item = dict(id='persisted-device-key', path=normal, media_key='confirmed-key',
                            expected_bytes=len(payload), expected_sha256=hashlib.sha256(payload).hexdigest())
                self.assertEqual(bridge.verify_original(client, item), dict(
                    id=item['id'], media_key=item['media_key'], bytes=len(payload), sha256=item['expected_sha256']))
                self.assertEqual(item['path'], normal)
            finally:
                shutil.rmtree('\\\\?\\' + ntpath.join(scratch, 'source-segment' * 4))
