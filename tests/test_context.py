"""Exact declared designs and figure-byte preservation, using installed clients."""
from pathlib import Path
import copy
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from biodataledger import ProjectBundle, BundleError
from biodataledger.core import canonical, STATE_PATH


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'data.csv').write_text('sample,value\nS1,1\n')
        (self.root / 'figure.svg').write_text('<svg>old</svg>')
        self.p = ProjectBundle.create('Synthetic', self.root)
        self.d = self.p.register_data('data.csv', 'input')
        self.low = self.p.set_design('treatment', ['Vehicle', 'LowDose', 'HighDose'], selected_levels=['Vehicle', 'LowDose'])
        self.d = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle', 'LowDose']}, 'declared', self.low)
        self.high = self.p.set_design('treatment', ['Vehicle', 'LowDose', 'HighDose'], selected_levels=['Vehicle', 'HighDose'])

    def test_contradictory_default_rejected_before_staging(self):
        before = canonical(self.p.state)
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.register_analysis('Wrong', [self.d])
        self.assertEqual(canonical(self.p.state), before)

    def test_strict_figure_rejects_overwrite_and_missing(self):
        a = self.p.register_analysis('Correct', [self.d], design_ref=self.low)
        f = self.p.register_figure('figure.svg', 'plot', analysis=a)
        original = self.p.get_figure(f).sha256
        self.assertEqual(self.p.resolve_figure(f, verify='sha256').path.read_text(), '<svg>old</svg>')
        (self.root / 'figure.svg').write_text('<svg>new</svg>')
        with self.assertRaisesRegex(BundleError, 'DIGEST_MISMATCH.*no preserved copy recorded'):
            self.p.resolve_figure(f, verify='sha256')
        (self.root / 'figure.svg').unlink()
        with self.assertRaisesRegex(BundleError, 'MISSING_FILE.*no preserved copy recorded'):
            self.p.resolve_figure(f, verify='sha256')
        self.assertEqual(self.p.get_figure(f).sha256, original)


    def test_explicit_design_default_pin_and_unknown(self):
        a = self.p.register_analysis('Low', [self.d], design_ref=self.low)
        f = self.p.register_figure('figure.svg', 'plot', analysis=a)
        self.assertEqual(self.p.get_analysis(a).design_ref, self.low)
        self.assertEqual(self.p.check_context(f)['status'], 'consistent')
        unknown = self.p.register_analysis('Unknown', [self.d], design_ref=None)
        self.assertEqual(self.p.check_context(unknown)['status'], 'unknown')
        self.p.set_design('different', ['one'])
        self.assertEqual(self.p.get_figure(f).design_ref, self.low)
        self.assertEqual(self.p.check_context(a)['status'], 'consistent')
        all_data = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle', 'LowDose', 'HighDose']}, 'all treatments', self.low)
        subset = self.p.register_analysis('Explicit subset', [all_data], design_ref=self.low)
        self.assertEqual(self.p.check_context(subset)['status'], 'consistent')
        no_scope = self.p.register_data('data.csv', 'unknown')
        uncertain = self.p.register_analysis('Uncertain', [no_scope], design_ref=self.low)
        self.assertEqual(self.p.check_context(uncertain)['status'], 'unknown')
        no_column = self.p.set_data_scope(no_scope, {'condition_values': ['Vehicle', 'LowDose']}, 'unknown condition')
        uncertain = self.p.register_analysis('Unknown column', [no_column], design_ref=self.low)
        self.assertEqual(self.p.check_context(uncertain)['status'], 'unknown')

    def test_combined_separate_and_different_condition(self):
        vehicle = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle']}, 'vehicle file', self.low)
        low = self.p.set_data_scope(self.d, {'condition_values': ['LowDose']}, 'low file', self.low)
        before = canonical(self.p.state)
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.register_analysis('Separate', [vehicle, low], design_ref=self.low)
        self.assertEqual(canonical(self.p.state), before)
        a = self.p.register_analysis('Comparison', [vehicle, low], design_ref=self.low, input_mode='combined')
        self.assertEqual(self.p.check_context(a)['status'], 'consistent')
        figure = self.p.register_figure('figure.svg', 'plot', analysis=a)
        self.assertEqual(self.p.get_figure(figure).input_mode, 'combined')
        self.assertEqual(self.p.get_analysis(a).inputs, [vehicle, low])
        uncertain = self.p.register_analysis('Incomplete', [vehicle, self.p.register_data('data.csv', 'unknown')], design_ref=self.low, input_mode='combined')
        self.assertEqual(self.p.check_context(uncertain)['status'], 'unknown')
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.register_analysis('Missing level', [vehicle], design_ref=self.low, input_mode='combined')
        other = self.p.set_design('cell_type', ['Vehicle', 'LowDose'])
        other_data = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle', 'LowDose']}, 'different meaning', other)
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.register_analysis('Wrong column', [other_data], design_ref=self.low)

    def test_standalone_and_generic_corrections(self):
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.register_figure('figure.svg', 'plot', inputs=[self.d])
        f = self.p.register_figure('figure.svg', 'plot', inputs=[self.d], design_ref=self.low)
        a = self.p.register_analysis('Low', [self.d], design_ref=self.low)
        linked = self.p.register_figure('figure.svg', 'plot', a, 'positional name')
        self.assertEqual(self.p.get_figure(linked).name, 'positional name')
        before = canonical(self.p.state)
        for ref, change in [(f, {'design_ref': self.high}), (a, {'design_ref': self.high}),
                            (linked, {'inputs': [self.d]}), (linked, {'design_ref': self.high}),
                            (f, {'input_mode': 'invalid'}), (f, {'analysis': a, 'inputs': [self.d]}),
                            (self.d, {'design_ref': self.high}), (self.d, {'input_mode': 'combined'}), (a, {'details': {'artifact_role': 'preserved_copy'}})]:
            with self.subTest(change=change), self.assertRaises(BundleError):
                self.p.update_record(ref, change, 'invalid correction')
            self.assertEqual(canonical(self.p.state), before)
        incompatible = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle', 'HighDose']}, 'incompatible input', self.high)
        with self.assertRaisesRegex(BundleError, 'SCOPE_CONFLICT'):
            self.p.update_record(a, {'inputs': [incompatible]}, 'wrong revised input')
        unknown_data = self.p.register_data('data.csv', 'unknown')
        revision = self.p.update_record(a, {'inputs': [unknown_data]}, 'explicit unknown input')
        self.assertEqual(self.p.check_context(revision)['status'], 'unknown')
        self.assertEqual(self.p.get_analysis(a).inputs, [self.d])
        revised = self.p.update_record(f, {'analysis': revision}, 'link exact analysis')
        self.assertEqual(self.p.get_figure(revised).analysis, revision)
        self.assertEqual(self.p.get_figure(revised).inputs, [unknown_data])

    def test_legacy_inconsistency_readable_and_metadata_correctable(self):
        a = self.p.register_analysis('Legacy wrong', [self.d], design_ref=self.low)
        self.p.set_current(self.d, 'comparison', 'preserve pointer')
        self.p.save()
        raw = json.loads((self.root / STATE_PATH).read_text())
        raw['schema_version'] = '0.3.0'
        for rec in raw['records']:
            rec.pop('input_mode', None)
            if rec['id'] == a['id']: rec['design'] = self.high
        (self.root / STATE_PATH).write_bytes(canonical(raw))
        original = (self.root / STATE_PATH).read_bytes()
        legacy = ProjectBundle.open(self.root)
        self.assertEqual(legacy.check_context(a)['status'], 'inconsistent')
        self.assertEqual((self.root / STATE_PATH).read_bytes(), original)
        named = legacy.update_record(a, {'name': 'Corrected title'}, 'metadata only')
        self.assertEqual(legacy.check_context(named)['status'], 'inconsistent')
        fixed = legacy.update_record(named, {'design_ref': self.low}, 'scientist correction')
        legacy.save()
        self.assertEqual(legacy.check_context(fixed)['status'], 'consistent')
        self.assertEqual(legacy.get_analysis(a).design_ref, self.high)
        self.assertEqual(legacy.get_data(purpose='comparison').ref, self.d)

    def test_managed_versions_preserve_bytes_and_exact_history(self):
        a = self.p.register_analysis('Low', [self.d], design_ref=self.low)
        external = self.p.register_figure('figure.svg', 'plot', analysis=a)
        first = self.p.save_figure('figure.svg', ref=external)
        first_view = self.p.resolve_figure(first, verify='sha256')
        first_path = first_view.path
        self.assertEqual(first_view.preservation['artifact_role'], 'preserved_copy')
        (self.root / 'figure.svg').write_text('<svg>new</svg>')
        second = self.p.save_figure('figure.svg', ref=first)
        self.assertEqual(second['revision'], first['revision'] + 1)
        self.assertNotEqual(self.p.get_figure(second).path, first_path)
        self.assertEqual(self.p.resolve_figure(first, verify='sha256').path.read_text(), '<svg>old</svg>')
        self.assertEqual(self.p.resolve_figure(second, verify='sha256').path.read_text(), '<svg>new</svg>')
        with self.assertRaisesRegex(BundleError, 'no preserved copy recorded'):
            self.p.resolve_figure(external, verify='sha256')
        before = canonical(self.p.state)
        for change in [{'path': 'figure.svg'}, {'details': {'preservation': {'artifact_role': 'preserved_copy'}}}]:
            with self.assertRaises(BundleError): self.p.update_record(first, change, 'invalid')
        self.assertEqual(canonical(self.p.state), before)
        self.p.save()
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.resolve_figure(first, verify='sha256').path, first_path)
        first_path.unlink()
        with self.assertRaisesRegex(BundleError, 'preserved copy unavailable'):
            reopened.resolve_figure(first, verify='sha256')

    def test_managed_registration_failure_and_stale_writers(self):
        before = canonical(self.p.state)
        with self.assertRaises(BundleError):
            self.p.save_figure('figure.svg', 'plot', inputs=[self.d])
        self.assertEqual(canonical(self.p.state), before)
        output = self.root / '.nb_project_bundle/outputs'
        self.assertFalse(list(output.iterdir()))
        with patch('biodataledger.core.shutil.copyfileobj', side_effect=OSError('copy failure')):
            with self.assertRaises(OSError): self.p.save_figure('figure.svg', 'plot')
        self.assertFalse(list(output.iterdir()))
        self.p.save()
        one, two = ProjectBundle.open(self.root), ProjectBundle.open(self.root)
        with ThreadPoolExecutor(max_workers=2) as workers:
            first, second = list(workers.map(lambda p: p.save_figure('figure.svg', 'plot', design_ref=None), [one, two]))
        self.assertNotEqual(one.get_figure(first).path, two.get_figure(second).path)
        one.save()
        with self.assertRaises(BundleError): two.save()
        self.assertTrue(two.unsaved)
        self.assertEqual(one.resolve_figure(first, verify='sha256').path.read_text(), '<svg>old</svg>')
        self.assertEqual(two.resolve_figure(second, verify='sha256').path.read_text(), '<svg>old</svg>')

    def r_call(self, action, *args, root=None):
        script = Path(__file__).with_name('r_context_exchange.R')
        result = subprocess.run(['Rscript', '--vanilla', str(script), os.environ['BDL_R_LIB'],
                                 action, str(root or self.root), *map(str, args)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_standalone_managed_copy_reuses_exact_code_snapshot(self):
        script = self.root / 'plot.R'; script.write_text('# preserved original\n')
        f = self.p.register_figure('figure.svg', 'plot', code='plot.R', design_ref=None)
        script.unlink()
        pending = self.p.save_figure('figure.svg', ref=f)
        self.p.save()
        persisted = self.p.save_figure('figure.svg', ref=pending)
        self.assertEqual(self.p.get_figure(persisted).code, self.p.get_figure(f).code)
        self.p.save()
        native = self.r_call('copy', f['id'] + '@' + str(f['revision']))
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_figure(native['figure']).code, reopened.get_figure(f).code)
        archive = self.root / 'standalone-working.zip'
        reopened.export_zip(reopened.preview_export('working', include=[f]), archive)
        imported = self.r_call('import_copy', archive, f['id'] + '@' + str(f['revision']), root=self.root / 'standalone-import')
        self.assertEqual(imported['code'], reopened.get_figure(f).code)

    def test_managed_working_zip_both_native_directions(self):
        a = self.p.register_analysis('Low', [self.d], design_ref=self.low)
        f = self.p.save_figure('figure.svg', 'plot', analysis=a)
        self.p.save()
        original = self.p.get_figure(f)
        archive = self.root / 'python-working.zip'
        self.p.export_zip(self.p.preview_export('working', include=[f]), archive)
        native_root = self.root / 'native-import'
        native_archive = self.root / 'R-working.zip'
        key = f['id'] + '@' + str(f['revision'])
        observed = self.r_call('archive', archive, key, native_archive, root=native_root)
        self.assertEqual(observed['preservation'], original.preservation)
        self.assertEqual(observed['verification']['file_integrity'], 'match')
        restored = ProjectBundle.import_zip(native_archive, self.root / 'python-import')
        figure = restored.resolve_figure(f, verify='sha256')
        self.assertEqual(figure.path.read_bytes(), original.path.read_bytes())
        self.assertEqual(figure.sha256, original.sha256)
        self.assertEqual(figure.preservation, original.preservation)
        self.assertEqual(figure.design_ref, self.low)

    def test_legacy_multi_input_mode_stays_unknown(self):
        vehicle = self.p.set_data_scope(self.d, {'condition_values': ['Vehicle']}, 'vehicle', self.low)
        low = self.p.set_data_scope(self.d, {'condition_values': ['LowDose']}, 'low', self.low)
        a = self.p.register_analysis('comparison', [vehicle, low], design_ref=self.low, input_mode='combined')
        self.p.save()
        raw = json.loads((self.root / STATE_PATH).read_text())
        raw['schema_version'] = '0.3.0'
        for rec in raw['records']: rec.pop('input_mode', None)
        (self.root / STATE_PATH).write_bytes(canonical(raw))
        legacy = ProjectBundle.open(self.root)
        report = legacy.check_context(a)
        self.assertEqual(report['status'], 'unknown')
        self.assertEqual(report['unknown'], ['input_mode'])
        key = a['id'] + '@' + str(a['revision'])
        self.assertEqual(self.r_call('context', key)['context'], report)
        fixed = legacy.update_record(a, {'input_mode': 'combined'}, 'declare combined comparison')
        self.assertEqual(legacy.check_context(fixed)['status'], 'consistent')

    def test_native_roundtrip_validation_and_managed_saves(self):
        a = self.p.register_analysis('Low', [self.d], design_ref=self.low)
        f = self.p.save_figure('figure.svg', 'plot', analysis=a)
        self.p.save()
        result = self.r_call('append', a['id'] + '@1', f['id'] + '@1', self.d['id'] + '@' + str(self.d['revision']))
        self.assertEqual(result['context'], self.p.check_context(a))
        self.assertTrue(result['rejected'])
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_analysis(result['analysis']).design_ref, self.low)
        self.assertEqual(reopened.resolve_figure(result['figure'], verify='sha256').path.read_text(), '<svg>old</svg>')
        other = self.root / 'r-created'; other.mkdir()
        created = self.r_call('create', root=other)
        native = ProjectBundle.open(other)
        self.assertEqual(native.check_context(created['analysis'])['status'], 'consistent')
        self.assertEqual(native.get_analysis(created['analysis']).input_mode, 'combined')
        with self.assertRaises(BundleError): native.update_record(created['analysis'], {'input_mode': 'separate'}, 'invalid')
        revision = native.save_figure('figure.svg', ref=created['figure']); native.save()
        observed = self.r_call('inspect', revision['id'] + '@' + str(revision['revision']), root=other)
        self.assertEqual(observed['verification']['file_integrity'], 'match')


if __name__ == '__main__':
    unittest.main()
