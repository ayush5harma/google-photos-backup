"""Reclaim must never turn a failed/ambiguous verification into source removal."""
import contextlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import icloud_bridge as bridge
from test_icloud_bridge import FakeAsset, FakeService


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


if __name__ == '__main__': unittest.main()
