"""Reclaim must never turn a failed/ambiguous verification into source removal."""
import contextlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import icloud_bridge as bridge
from test_icloud_bridge import FakeAsset, FakeService, SizedAsset, Uploads


class ReclaimTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / 'state'
        self.state.mkdir()
        self.asset = FakeAsset()
        self.asset._asset_record = {'recordName': 'record-1', 'recordChangeTag': 'revision-1'}
        self.service = FakeService(assets=[self.asset])
        self.events, self.deletes, self.verifications = [], [], []
        self.request = dict(account='apple@example.com', auth_data='Email=google@example.com',
                            state_dir=str(self.state), staging_dir=str(Path(self.temp.name)/'stage'))
        @contextlib.contextmanager
        def session(*_): yield self.state
        for name, value in [('session_directory', session), ('_components', lambda a: [('original', a.version, 'original.heic')])]:
            p = patch.object(bridge, name, value)
            p.start()
            self.addCleanup(p.stop)
        with contextlib.closing(bridge._ledger(self.state, 'apple@example.com', 'google@example.com')) as db, db:
            db.execute('INSERT INTO confirmed VALUES (?,?,?,?,?)', (self.asset.id, 'original', 'checksum-1', 'google-key', 'uploaded'))
    def verify(self, auth, item):
        self.verifications.append(item)
        self.assertEqual(Path(item['path']).read_bytes(), b'pixels')
        return dict(bytes=6, media_key='google-key', sha256='a'*64)
    def run_command(self, command, **kwargs):
        self.events = []
        return bridge.run(dict(self.request, command=command, **kwargs), self.events.append,
                          factory=lambda *_: self.service, verify=self.verify,
                          delete=lambda library, snapshot: self.deletes.append(snapshot))
    def preview(self):
        self.assertEqual(self.run_command('reclaim-preview', asset_ids=[self.asset.id]), 0)
        return self.events[-1]['token']
    def test_only_verified_components_can_be_deleted(self):
        token = self.preview()
        self.assertEqual(self.deletes, [])
        self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 0)
        self.assertEqual(len(self.deletes), 1)
        self.assertEqual(len(self.verifications), 1)
        self.assertEqual(self.events[-1]['soft_deleted'], 1)
        self.assertFalse(self.events[-1]['immediate_space_recovery'])
        self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True)
        self.assertEqual(len(self.deletes), 1)  # completed intent isn't repeated
    def test_no_confirmation_means_no_verification_or_deletion(self):
        token = self.preview()
        self.assertEqual(self.run_command('reclaim', preview_token=token), 4)
        self.assertEqual(self.deletes, [])
        self.assertEqual(self.verifications, [])
    def test_source_changed_since_preview(self):
        token = self.preview()
        self.asset._asset_record['recordChangeTag'] = 'revision-2'
        self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 1)
        self.assertEqual(self.deletes, [])
        self.assertEqual(self.verifications, [])
    def test_account_switch_invalidates_preview(self):
        token = self.preview()
        self.request['auth_data'] = 'Email=another@example.com'
        self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 4)
        self.assertEqual(self.deletes, [])
    def test_expired_preview(self):
        token = self.preview()
        with patch.object(bridge.time, 'time', return_value=10**12):
            self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 4)
        self.assertEqual(self.deletes, [])
    def test_readback_failure_retains_source(self):
        token = self.preview()
        def fail(*args): raise ValueError('mismatch')
        self.verify = fail
        self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 1)
        self.assertEqual(self.deletes, [])
    def test_ambiguous_delete_is_never_replayed(self):
        token = self.preview()
        with contextlib.closing(bridge._ledger(self.state, 'apple@example.com', 'google@example.com')) as db, db:
            db.execute('INSERT INTO reclaim_actions VALUES (?,?,?)', (token, self.asset.id, 'delete_requested'))
        self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 1)
        self.assertEqual(self.events[-1]['uncertain'], 1)
        self.assertEqual(self.deletes, [])
    def test_unbacked_component_not_offered(self):
        self.asset.version.checksum = 'new-version'
        self.preview()
        self.assertEqual(self.events[-1]['count'], 0)
        self.assertEqual(self.deletes, [])

    def test_new_preview_cannot_bypass_ambiguous_delete(self):
        token = self.preview()
        with contextlib.closing(bridge._ledger(self.state, 'apple@example.com', 'google@example.com')) as db, db:
            db.execute('INSERT INTO reclaim_actions VALUES (?,?,?)', (token, self.asset.id, 'delete_requested'))
        self.preview()
        self.assertEqual(self.events[-1]['count'], 0)

    def test_live_component_failure_keeps_whole_asset(self):
        components = lambda a: [('original', a.version, 'still.heic'), ('live', a.version, 'motion.mov')]
        with contextlib.closing(bridge._ledger(self.state, 'apple@example.com', 'google@example.com')) as db, db:
            db.execute('INSERT INTO confirmed VALUES (?,?,?,?,?)', (self.asset.id, 'live', 'checksum-1', 'motion-key', 'uploaded'))
        with patch.object(bridge, '_components', components):
            token = self.preview()
            self.assertEqual(self.run_command('reclaim', preview_token=token, confirm_recently_deleted=True), 1)
        self.assertEqual(self.deletes, [])

    def test_automatic_reclaim_requires_confirmation_before_upload(self):
        called = []
        code = bridge.run(dict(self.request, command='backup', reclaim_after_backup=True), self.events.append,
                          factory=lambda *_: self.service, upload=lambda *_: called.append(True))
        self.assertEqual(code, 4)
        self.assertEqual(called, [])

    def test_automatic_reclaim_rejects_unbounded_batch(self):
        code = bridge.run(dict(self.request, command='backup', reclaim_after_backup=True,
                              confirm_recently_deleted=True, max_items=101), self.events.append,
                          factory=lambda *_: self.service, upload=lambda *_: ('key', 'uploaded'))
        self.assertEqual(code, 4)

    def test_soft_delete_validates_record_level_success(self):
        from types import SimpleNamespace
        class Reply:
            def raise_for_status(self): pass
            def json(self): return {'records': [{'recordName': 'record-1', 'serverErrorCode': 'CONFLICT'}]}
            def close(self): pass
        requests = []
        library = SimpleNamespace(service_endpoint='https://example.invalid/photos', params={}, zone_id={'zoneName':'primary'},
                                  session=SimpleNamespace(post=lambda url, **kwargs: (requests.append(kwargs) or Reply())))
        with self.assertRaises(ValueError):
            bridge._soft_delete(library, dict(record_name='record-1', change_tag='revision-1'))
        import json
        record = json.loads(requests[0]['data'])['operations'][0]['record']
        self.assertEqual(record['recordChangeTag'], 'revision-1')
        self.assertEqual(record['fields']['isDeleted']['value'], 1)


class ConcurrentAutomaticReclaimTests(unittest.TestCase):
    """Issue #60: uploads now run many at once. Automatic reclaim must still
    reach only assets whose every component Google confirmed, and only after
    a fresh readback verified each one."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.events, self.deletes, self.verifications = [], [], []
        self.live = {}
        @contextlib.contextmanager
        def session(*_): yield self.root
        def components(asset):
            parts = [('original', asset.version, asset.filename)]
            if asset.id in self.live:
                parts.append(('live', self.live[asset.id], asset.filename + '.MOV'))
            return parts
        for name, value in [('session_directory', session), ('_components', components)]:
            p = patch.object(bridge, name, value)
            p.start()
            self.addCleanup(p.stop)

    def verify(self, auth, item):
        self.verifications.append(item['id'])
        return dict(bytes=item['expected_bytes'], media_key=item['media_key'], sha256='a' * 64)

    def backup(self, assets, upload, **extra):
        request = dict(dict(command='backup', account='apple@example.com', auth_data='Email=google@example.com',
                            state_dir=str(self.root / 'state'), staging_dir=str(self.root / 'stage'),
                            reclaim_after_backup=True, confirm_recently_deleted=True), **extra)
        return bridge.run(request, self.events.append, factory=lambda *_: FakeService(assets=assets), upload=upload,
                          verify=self.verify, delete=lambda library, snapshot: self.deletes.append(snapshot['id']))

    def test_failed_or_unconfirmed_uploads_are_never_reclaimed(self):
        def outcome(item):
            index = int(item['id'].split(':')[0].split('-')[1])
            if index % 4 == 0:
                raise ConnectionError('temporary')
            if index % 4 == 1:
                return '', 'uploaded'              # no media key: not confirmed
            if index % 4 == 2 and item['id'].endswith(':live'):
                raise bridge.UploadFailed('transfer', False)
            return 'key-' + item['id'], 'uploaded'

        assets = [SizedAsset(i) for i in range(40)]
        for asset in assets[2::4]:
            self.live[asset.id] = type('Version', (), {'size': 6, 'url': 'https://invalid.example/live',
                                                       'checksum': 'live-' + asset.id})()
        for threads in (1, 8, 32):
            with self.subTest(threads=threads):
                self.events, self.deletes, self.verifications = [], [], []
                code = self.backup(assets, Uploads(hold=0.002, outcome=outcome), threads=threads,
                                   state_dir=str(self.root / f'state-{threads}'))
                confirmed = {a.id for i, a in enumerate(assets) if i % 4 == 3}
                self.assertEqual(code, 0)
                self.assertEqual(set(self.deletes), confirmed)
                self.assertEqual(len(self.deletes), len(confirmed))
                self.assertEqual({v.split(':')[0] for v in self.verifications}, confirmed)
                self.assertEqual(self.events[-1]['type'], 'reclaim_done')
                self.assertEqual(self.events[-1]['soft_deleted'], len(confirmed))

    def test_the_hundred_item_cap_holds_at_thirty_two_uploads_at_once(self):
        assets = [SizedAsset(i) for i in range(130)]
        uploads = Uploads(target=32, hold=0.002)
        self.assertEqual(self.backup(assets, uploads, threads=32), 0)
        self.assertEqual(uploads.most, 32)
        self.assertEqual(len(uploads.calls), 100)
        self.assertEqual(len(self.deletes), 100)
        self.assertEqual(set(self.deletes), {item['id'].split(':')[0] for item in uploads.calls})

    def test_a_failed_readback_retains_every_source_under_concurrency(self):
        def fail(auth, item):
            self.verifications.append(item['id'])
            raise ValueError('mismatch')
        self.verify = fail
        assets = [SizedAsset(i) for i in range(12)]
        self.assertEqual(self.backup(assets, Uploads(hold=0.002), threads=8), 1)
        self.assertEqual(self.deletes, [])
        self.assertEqual(self.events[-1]['retained'], 12)

    def test_a_stopped_run_reclaims_nothing(self):
        def outcome(item):
            if item['id'].startswith('asset-006'):
                raise bridge.StopRequested()
            return 'key-' + item['id'], 'uploaded'
        assets = [SizedAsset(i) for i in range(12)]
        self.assertEqual(self.backup(assets, Uploads(hold=0.002, outcome=outcome), threads=8), 5)
        self.assertEqual(self.deletes, [])
        self.assertEqual(self.verifications, [])


if __name__ == '__main__': unittest.main()
