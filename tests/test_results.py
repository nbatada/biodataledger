"""Synthetic exact-result identity, byte checks and bounded lineage."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import ProjectBundle, BundleError
from biodataledger.core import canonical

KEY = 'biodataledger.result'


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.csv = 'sample_id,cell_id,UMAP_1,UMAP_2\nS1,001,1.1,2\nS1,002,2,3\nS2,001,4,5\nS2,003,6,7\n'
        (self.root / 'umap.csv').write_text(self.csv)
        (self.root / 'members.csv').write_text('sample_id,cell_id\nS1,001\nS1,002\nS2,001\nS2,003\n')
        (self.root / 'input.h5ad').write_text('Opaque synthetic input, never deserialized')
        (self.root / 'plot.svg').write_text('<svg/>')
        self.p = ProjectBundle.create('PRMT5 synthetic lineage', self.root)
        self.d = self.p.register_data('input.h5ad', 'input', hash=True)
        self.members = self.p.register_data('members.csv', 'observations', hash=True)
        self.a = self.p.register_analysis('Declared synthetic UMAP', [self.d], method='synthetic fixture', params={'seed': 1})
        self.embedding = {'format': 'csv', 'coordinate_columns': ['UMAP_1', 'UMAP_2'], 'membership_ref': self.members}

    def result(self, **kwargs):
        return self.p.register_result('umap.csv', self.a, embedding=self.embedding, **kwargs)

    def test_reference_default_exact_chain_and_no_query_io(self):
        with patch('biodataledger.core.fingerprint', side_effect=AssertionError('unexpected hash')), patch.object(Path, 'open', side_effect=AssertionError('unexpected payload open')):
            result = self.result()
        view = self.p.get_data(ref=result)
        self.assertEqual(view.path, self.root / 'umap.csv')
        self.assertIsNone(view.sha256)
        self.assertEqual(view.scope['transformation_ref'], self.a)
        self.assertEqual(view.details['membership'], self.members)
        self.assertFalse((self.root / '.nb_project_bundle/outputs').exists())
        fig = self.p.register_figure('plot.svg', 'umap', analysis=self.a,
                    figure_sources={'rendering_inputs': [result], 'relationship': 'declared'})
        with patch.object(Path, 'open', side_effect=AssertionError('query I/O')), patch('os.scandir', side_effect=AssertionError('directory scan')):
            forward = self.p.dependencies(self.d, 'downstream', depth=3)
            backward = self.p.dependencies(fig, 'upstream', depth=3)
            self.p.get_data(ref=result)
        def edge_set(report):
            return {(e['from']['id'], e['to']['id'], e['type']) for e in report['edges']}
        chain = {(self.d['id'], self.a['id'], 'input_to_analysis'), (self.a['id'], result['id'], 'produced_result'), (result['id'], fig['id'], 'rendered_in_figure')}
        self.assertTrue(chain <= edge_set(forward))
        self.assertTrue(chain <= edge_set(backward))
        self.assertEqual(forward['execution'], 'unknown')
        self.assertEqual(self.p.save_and_confirm()['status'], 'persisted')
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.dependencies(self.d, 'downstream', depth=3), forward)

    def test_csv_measurements_membership_negative_controls_and_readonly(self):
        result = self.result(hash=True)
        self.p.save_and_confirm()
        before = canonical(self.p.state)
        report = self.p.check_result(result)
        self.assertEqual(report['overall'], 'PASS')
        self.assertEqual(report['rows'], 4)
        self.assertEqual(report['execution'], 'UNKNOWN')
        self.assertEqual(canonical(self.p.state), before)
        self.assertFalse(self.p.unsaved)
        # Equal numbers and labels do not establish the same qualified cells.
        (self.root / 'different.csv').write_text(self.csv.replace('S2,003', 'S2,999'))
        different = self.p.register_result('different.csv', self.a, embedding=self.embedding, hash=True)
        self.assertEqual(self.p.check_result(different)['fields']['membership']['status'], 'FAIL')
        no_authority = dict(self.embedding, membership_ref=None)
        no_member = self.p.register_result('umap.csv', self.a, embedding=no_authority, hash=True)
        self.assertEqual(self.p.check_result(no_member)['fields']['membership']['status'], 'UNKNOWN')
        no_hash = self.result()
        self.assertEqual(self.p.check_result(no_hash)['fields']['file_integrity']['status'], 'UNKNOWN')
        (self.root / 'umap.csv').write_text(self.csv.replace('1.1', '9.1'))
        self.assertEqual(self.p.check_result(result)['fields']['file_integrity']['status'], 'FAIL')

    def test_native_selectors_are_metadata_only_and_reuse_pinned_container(self):
        for fmt, selector in [('seurat', 'umap'), ('anndata', 'X_umap')]:
            with patch.object(Path, 'open', side_effect=AssertionError('native payload read')):
                result = self.p.register_result(self.d, self.a,
                    embedding={'format': fmt, 'selector': selector, 'membership_ref': self.members})
                report = self.p.check_result(result)
            self.assertEqual(report['overall'], 'UNKNOWN')
            self.assertEqual(report['fields']['alignment']['reason'], 'adapter_not_available')
            view = self.p.get_data(ref=result)
            self.assertEqual(view.sha256, self.p.get_data(ref=self.d).sha256)
            self.assertEqual(view.details[KEY]['artifact_source_ref'], self.d)
            self.assertEqual(view.details[KEY]['embedding']['selector'], selector)
        (self.root / 'input.h5ad').write_text('changed synthetic container')
        before = canonical(self.p.state)
        with self.assertRaises(BundleError):
            self.p.register_result(self.d, self.a, hash=True)
        self.assertEqual(before, canonical(self.p.state))

    def test_optional_copy_revisions_and_failed_mutations(self):
        first = self.result(copy=True)
        first_view = self.p.get_data(ref=first)
        self.assertNotEqual(first_view.path, self.root / 'umap.csv')
        self.assertEqual(first_view.path.read_text(), self.csv)
        (self.root / 'umap.csv').write_text(self.csv.replace('1.1', '8.1'))
        second = self.p.register_result('umap.csv', self.a, ref=first, embedding=self.embedding, copy=True)
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(second['revision'], first['revision'] + 1)
        self.assertEqual(first_view.path.read_text(), self.csv)
        self.p.resolve_data(ref=first, verify='sha256')
        before = canonical(self.p.state)
        for operation in [lambda: self.p.update_record(first, {'path': 'umap.csv'}, 'unsafe'),
                          lambda: self.p.register_result('umap.csv', self.d),
                          lambda: self.p.register_result('umap.csv', self.a, embedding={'format': 'anndata'}),
                          lambda: self.p.register_result('umap.csv', self.a, ref=self.d)]:
            with self.assertRaises(BundleError): operation()
            self.assertEqual(before, canonical(self.p.state))
        first_view.path.write_text('tampered')
        with self.assertRaises(BundleError): self.p.resolve_data(ref=first, verify='sha256')

    def test_csv_invalid_keys_coordinates_order_and_limits(self):
        cases = [('duplicate', self.csv.replace('S1,002', 'S1,001'), 'observation_identity'),
                 ('emptykey', self.csv.replace('S1,002', 'S1,'), 'observation_identity'),
                 ('nan', self.csv.replace('1.1', 'NaN'), 'coordinates'),
                 ('header', self.csv.replace('UMAP_2', 'UMAP_1'), 'coordinates'),
                 ('ragged', self.csv.replace('S1,001,1.1,2', 'S1,001,1.1'), 'coordinates')]
        for name, text, field in cases:
            (self.root / (name + '.csv')).write_text(text)
            ref = self.p.register_result(name + '.csv', self.a, embedding=self.embedding, hash=True)
            self.assertEqual(self.p.check_result(ref)['fields'][field]['status'], 'FAIL', name)
        lines = self.csv.splitlines()
        (self.root / 'reverse.csv').write_text('\n'.join([lines[0]] + lines[:0:-1]) + '\n')
        for comparison, status in [('set_keys', 'PASS'), ('ordered_keys', 'FAIL')]:
            ref = self.p.register_result('reverse.csv', self.a, embedding=dict(self.embedding, comparison=comparison), hash=True)
            self.assertEqual(self.p.check_result(ref)['fields']['membership']['status'], status)

    def test_unknown_legacy_and_bounded_fanout(self):
        unknown = self.p.register_result('umap.csv', None)
        self.assertEqual(self.p.check_result(unknown)['overall'], 'UNKNOWN')
        legacy = self.p.register_data('umap.csv', 'result', parent=self.d)
        legacy = self.p.set_data_scope(legacy, {'transformation_ref': self.a}, 'historical hint')
        report = self.p.dependencies(legacy, 'upstream')
        self.assertFalse(any(e['type'] == 'produced_result' for e in report['edges']))
        for _ in range(30): self.result()
        bounded = self.p.dependencies(self.a, 'downstream', limit=2)
        self.assertEqual(len(bounded['edges']), 2)
        self.assertTrue(bounded['truncated'])
        self.assertLessEqual(len(canonical(bounded)), 16384)
        for args in [('bad', 1, 20), ('upstream', 0, 20), ('upstream', 1, 101)]:
            with self.assertRaises(BundleError): self.p.dependencies(self.a, args[0], depth=args[1], limit=args[2])

    def test_copy_failure_stale_save_and_future_metadata(self):
        before = canonical(self.p.state)
        with patch('biodataledger.results.fingerprint', side_effect=['a'*64, 'b'*64]):
            with self.assertRaises(BundleError): self.result(copy=True)
        self.assertEqual(before, canonical(self.p.state))
        self.assertEqual(list((self.root / '.nb_project_bundle/outputs').iterdir()), [])
        self.p.save_and_confirm()
        stale = ProjectBundle.open(self.root)
        result = self.result(copy=True)
        copied = self.p.get_data(ref=result).path
        stale.set_context({'next_task': 'another writer'})
        stale.save_and_confirm()
        with self.assertRaises(BundleError): self.p.save_and_confirm()
        self.assertTrue(self.p.unsaved)
        self.assertTrue(copied.is_file())
        # A future optional contract remains readable; no automatic interpretation.
        raw = json.loads((self.root / '.nb_project_bundle/project.json').read_bytes())
        raw['records'][0]['details'][KEY] = {'version':'future/result/9'}
        path = self.root / '.nb_project_bundle/project.json'
        path.write_bytes(canonical(raw))
        original = path.read_bytes()
        future = ProjectBundle.open(self.root)
        self.assertEqual(future.get_data(ref=self.d).result['status'], 'unknown')
        self.assertEqual(future.check_result(self.d)['overall'], 'UNKNOWN')
        self.assertFalse(any(e['type'] == 'produced_result' for e in future.dependencies(self.d,'upstream')['edges']))
        self.assertEqual(path.read_bytes(), original)
        with self.assertRaises(BundleError): future.register_result('umap.csv',self.a,ref=self.d)

    def test_size_cap_and_source_observation_evidence(self):
        result = self.result(hash=True)
        with patch('biodataledger.results.MAX_CHECK_BYTES', 10):
            report = self.p.check_result(result)
        self.assertEqual(report['overall'], 'UNKNOWN')
        self.assertEqual(report['fields']['file_integrity']['reason'], 'size_limit')
        (self.root / 'members.csv').write_text('tampered independent evidence')
        report = self.p.check_result(result)
        self.assertEqual(report['fields']['membership']['status'], 'FAIL')
        self.assertEqual(report['fields']['alignment']['status'], 'PASS')
