"""Installed-client reusable implementation identity, revisions and trust boundaries."""
import copy
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from biodataledger import BundleError, ProjectBundle
from biodataledger.core import STATE_PATH, canonical, digest_bytes, validate_state

V1 = '''def validate_required_columns(table, required):
    return [name for name in required if any(name not in row for row in table)]
'''
V2 = '''def validate_required_columns(table, required, expected_types=None):
    missing = [name for name in required if any(name not in row for row in table)]
    if expected_types and not missing:
        for row in table:
            for name, kind in expected_types.items():
                if not isinstance(row[name], kind):
                    raise TypeError(name)
    return missing
'''


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'helper.py'
        self.source.write_text(V1)
        self.p = ProjectBundle.create('Synthetic reusable functions', self.root)
        self.contract = dict(inputs='List of row dictionaries', parameters='Required column names',
                             outputs='Missing column names', example="validate_required_columns(table, ['id'])",
                             limitations='Column presence only; no scientific validity check')

    def register(self, **changes):
        args = dict(language='Python', purpose='Check required columns', contract=self.contract,
                    source=self.source, function='validate_required_columns', tags=['table', 'columns'])
        args.update(changes)
        return self.p.register_helper('Required columns', **args)

    def test_actual_reuse_extension_and_historical_pins(self):
        first = self.register()
        namespace = {}
        exec(compile(V1, str(self.source), 'exec'), namespace)  # Explicit trusted synthetic fixture.
        check = namespace['validate_required_columns']
        tables = [[{'sample_id': 'a', 'measurement': 2}], [{'item': 'x', 'price': 4.5}]]
        requirements = [['sample_id', 'measurement'], ['item', 'price']]
        analyses = []
        for i, (table, required) in enumerate(zip(tables, requirements)):
            self.assertEqual(check(table, required), [])
            self.assertEqual(check(table, required + ['absent']), ['absent'])
            path = self.root / f'table-{i}.json'
            path.write_text(json.dumps(table))
            data = self.p.register_data(path, 'input', hash=True)
            analyses.append(self.p.register_analysis(f'Check table {i}', [data], params={'required': required}, helper_refs=[first]))
        self.source.write_text(V2)
        second = self.register(ref=first, reason='General optional type check')
        exec(compile(V2, str(self.source), 'exec'), namespace)
        extended = namespace['validate_required_columns']
        for table, required in zip(tables, requirements):
            self.assertEqual(extended(table, required), check(table, required))
        self.assertEqual(extended(tables[1], requirements[1], {'price': float}), [])
        with self.assertRaises(TypeError):
            extended(tables[1], requirements[1], {'price': str})
        self.assertEqual(second['revision'], 2)
        for ana in analyses:
            self.assertEqual(self.p.get_analysis(ana).details['bl_helper_refs'], [first])
        self.assertEqual(self.p.get_helper(first, 'sha256')['verification']['status'], 'fail')
        self.assertEqual(self.p.get_helper(second, 'sha256')['verification']['status'], 'pass')
        graph = self.p.export_graph(ref=first, direction='downstream', format='structured')
        for ana in analyses:
            self.assertTrue(any(e['type'] == 'declared_helper_use' and e['from'] == first and e['to'] == ana for e in graph['edges']))
        self.p.save()
        reopened = ProjectBundle.open(self.root)
        original_code = reopened.get_helper(first)['code'][0]
        self.assertEqual((self.root / original_code['snapshot']).read_text(), V1)
        with self.assertRaises(BundleError):
            self.register(ref=first)

    def test_package_identity_without_import_and_explicit_promotion(self):
        package = 'bdl_synthetic_helper_package'
        info = self.root / f'{package}-1.2.0.dist-info'
        info.mkdir()
        (info / 'METADATA').write_text(f'Metadata-Version: 2.1\nName: {package}\nVersion: 1.2.0\n')
        (self.root / f'{package}.py').write_text('raise RuntimeError("must not import target")\n')
        first = self.register()
        helper = self.register(ref=first, source=None, package=package, version='1.2.0')
        with patch.object(sys, 'path', [str(self.root), *sys.path]):
            self.assertEqual(self.p.get_helper(helper, 'identity')['verification']['status'], 'qualified_match')
            mismatch = self.register(source=None, package=package, version='9.9.9')
            self.assertEqual(self.p.get_helper(mismatch, 'identity')['verification']['status'], 'mismatch')
        self.assertNotIn(package, sys.modules)
        missing = self.register(source=None, package='definitely_missing_bdl_package', version='1.0')
        self.assertEqual(self.p.get_helper(missing, 'identity')['verification']['status'], 'missing')
        self.assertEqual(self.p.get_helper(helper, 'sha256')['verification']['status'], 'unavailable')
        self.assertEqual(self.p.get_helper(first)['descriptor']['location']['kind'], 'source')

    def test_selected_sources_export_without_implicit_analysis_payloads(self):
        support = self.root / 'support.py'
        support.write_text('DEFAULT = None\n')
        helper = self.register(source=[self.source, support])
        ana = self.p.register_analysis('Declared use', [], helper_refs=[helper])
        self.p.save()
        self.assertEqual(self.p.preview_export('working', include=[ana])['files'], [])
        plan = self.p.preview_export('working', include=[helper])
        self.assertEqual(len(plan['files']), 2)
        archive = self.root / 'helper.zip'
        self.p.export_zip(plan, archive)
        imported = ProjectBundle.import_zip(archive, self.root / 'imported')
        card = imported.get_helper(helper, 'snapshot')
        self.assertEqual(card['verification']['status'], 'pass')
        self.assertEqual(card['verification']['basis'], 'retained_snapshot')
        self.assertEqual(imported.get_helper(helper, 'sha256')['verification']['status'], 'fail')
        self.assertTrue(all(Path(f['path']).is_file() for f in card['verification']['files']))
        self.assertEqual(card['ref'], helper)
        for code in card['code']:
            path = Path(next(f['path'] for f in card['verification']['files'] if f['sha256'] == code['sha256']))
            self.assertEqual(digest_bytes(path.read_bytes()), code['sha256'])
        self.assertEqual(imported.get_analysis(ana).details['bl_helper_refs'], [helper])

    def test_discovery_metadata_only_reports_scan_and_result_limits(self):
        helper = self.register()
        with patch('biodataledger.core.fingerprint', side_effect=AssertionError('no hash')), patch.object(Path, 'read_bytes', side_effect=AssertionError('no read')):
            report = self.p.find_helpers('  REQUIRED columns  ')
            self.assertEqual(report['helpers'][0]['ref'], helper)
            self.p.get_helper(helper)
        self.assertFalse(report['coverage']['incomplete'])
        self.assertEqual(self.p.find_helpers('columns', language='R')['helpers'], [])
        self.p.update_record(helper, {'status': 'inactive'}, 'Retired fixture')
        self.assertEqual(self.p.find_helpers('columns')['helpers'], [])
        for i in range(100):
            self.p.record_decision(f'Ordinary {i}', 'synthetic', [])
        later = self.register()
        report = self.p.find_helpers('columns')
        self.assertTrue(report['coverage']['incomplete'])
        self.assertEqual(report['coverage']['scanned_latest_records'], 100)
        self.assertNotIn(later, [c['ref'] for c in report['helpers']])

    def test_discovery_byte_bounds_and_registration_limits(self):
        for i in range(20):
            self.register(purpose='columns ' + 'é' * 1900)
        report = self.p.find_helpers('columns', limit=20)
        self.assertLessEqual(len(canonical(report)), 16 * 1024)
        self.assertTrue(all('purpose' in c['shortened_fields'] for c in report['helpers']))
        self.assertTrue(self.p.find_helpers('columns', limit=1)['coverage']['incomplete'])
        with self.assertRaises(BundleError):
            self.register(purpose='x' * 4097)
        with self.assertRaises(BundleError):
            self.p.find_helpers('x' * 257)

    def test_invalid_typed_mutations_and_persisted_links(self):
        helper = self.register()
        ordinary = self.p.record_decision('ordinary', 'synthetic', [])
        with self.assertRaises(BundleError):
            self.p.register_analysis('bad', [], helper_refs=[ordinary])
        with self.assertRaises(BundleError):
            self.p.register_analysis('bad', [], helper_refs=[helper, helper])
        with self.assertRaises(BundleError):
            self.p.register_analysis('bad', [], helper_refs=[helper['id']])
        with self.assertRaises(BundleError):
            self.p.update_record(helper, {'details': {}}, 'Bypass')
        with self.assertRaises(BundleError):
            self.p.record_scientific_decision('fake approval', 'No', [], 'approved', ref=helper)
        descriptor = self.p.get_helper(helper)['descriptor']
        with self.assertRaises(BundleError):
            self.p.update_record(ordinary, {'details': {'bl_helper': descriptor}}, 'Bypass')
        ana = self.p.register_analysis('valid', [], helper_refs=[helper])
        before = copy.deepcopy(self.p.state)
        for corrupt in ('descriptor', 'link', 'source', 'kind'):
            state = copy.deepcopy(before)
            h = next(r for r in state['records'] if r['id'] == helper['id'])
            a = next(r for r in state['records'] if r['id'] == ana['id'])
            if corrupt == 'descriptor': h['details']['bl_helper'] = {'version': 'biodataledger-helper/1'}
            if corrupt == 'link': a['details']['bl_helper_refs'] = [ordinary]
            if corrupt == 'source': h['code'] = []
            if corrupt == 'kind': h['details']['bl_helper_refs'] = [helper]
            with self.assertRaises(BundleError, msg=corrupt):
                validate_state(state)
        # Existing arbitrary user metadata is not appropriated by the new typed fields.
        self.p.register_data(self.source, 'source', helper='user metadata', helper_refs=['custom'])

    def test_malformed_import_rejected_before_destination_creation(self):
        helper = self.register()
        self.p.save()
        archive = self.root / 'valid.zip'
        self.p.export_zip(self.p.preview_export('context'), archive)
        with zipfile.ZipFile(archive) as z:
            payload = {name: z.read(name) for name in z.namelist()}
        state = json.loads(payload[STATE_PATH])
        state['records'][0]['details']['bl_helper']['contract'] = {}
        payload[STATE_PATH] = canonical(state)
        manifest = json.loads(payload['manifest.json'])
        for entry in manifest['files']:
            if entry['path'] == STATE_PATH:
                entry.update(size=len(payload[STATE_PATH]), sha256=digest_bytes(payload[STATE_PATH]))
        payload['manifest.json'] = canonical(manifest)
        hostile = self.root / 'hostile.zip'
        with zipfile.ZipFile(hostile, 'w') as z:
            for name, content in payload.items(): z.writestr(name, content)
        dest = self.root / 'rejected'
        with self.assertRaises(BundleError):
            ProjectBundle.import_zip(hostile, dest)
        self.assertFalse(dest.exists())

    @unittest.skipUnless(os.environ.get('BDL_R_LIB'), 'installed R library required')
    def test_cross_native_exact_helper_roundtrip(self):
        helper = self.register()
        ana = self.p.register_analysis('Cross-native declaration', [], helper_refs=[helper])
        self.p.save()
        request = self.root / 'refs.json'
        request.write_text(json.dumps({'helper': helper, 'analysis': ana}))
        code = """a <- commandArgs(TRUE); library(BioDataLedger, lib.loc=a[[2]])
p <- ProjectBundle$open(a[[1]]); refs <- jsonlite::fromJSON(a[[3]], simplifyVector=FALSE)
stopifnot(identical(p$get_helper(refs$helper, 'snapshot')$verification$status, 'pass'))
linked <- p$get_analysis(refs$analysis)$details$bl_helper_refs
stopifnot(length(linked)==1L, linked[[1L]]$id==refs$helper$id, linked[[1L]]$project_id==refs$helper$project_id, linked[[1L]]$revision==refs$helper$revision)
h <- p$register_helper('R package', 'R', 'Native package example', p$get_helper(refs$helper)$descriptor$contract, package='stats', version=as.character(packageVersion('stats')), function_name='median')
p$save(); cat(jsonlite::toJSON(h, auto_unbox=TRUE))
"""
        run = subprocess.run(['Rscript', '--vanilla', '-e', code, str(self.root), os.environ['BDL_R_LIB'], str(request)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        # save() may print a receipt, so use the last JSON line for the returned reference.
        reference = json.loads(run.stdout.splitlines()[-1])
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_helper(reference)['descriptor']['language'], 'R')
        self.assertEqual(reopened.get_analysis(ana).details['bl_helper_refs'], [helper])

    @unittest.skipUnless(os.environ.get('BDL_R_LIB'), 'installed R library required')
    def test_native_helper_suite(self):
        script = Path(__file__).with_name('r_helpers.R')
        run = subprocess.run(['Rscript', '--vanilla', str(script), os.environ['BDL_R_LIB']], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
