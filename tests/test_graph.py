"""Installed-package tests for exact scientific graph export and native parity."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle

ROOT = Path(__file__).resolve().parents[1]
CREATE_EXAMPLE = runpy.run_path(str(ROOT / 'examples/dependency_graph.py'))['create_example']
REGISTRY = '.nb_project_bundle/project.json'


def exact(ref):
    return ref['id'] + '@' + str(ref['revision'])


def types(report):
    return {edge['type'] for edge in report['edges']}


def refs(report):
    return [exact(node['ref']) for node in report['nodes']]


class GraphTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='biodataledger-graph-')
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.p, self.original, self.fig = CREATE_EXAMPLE(self.root)

    def graph(self, **opts):
        return self.p.export_graph(format='structured', **opts)

    def native_parity(self, requests):
        if not shutil.which('Rscript'):
            self.skipTest('Rscript unavailable')
        request_file = self.root / 'requests.json'
        request_file.write_text(json.dumps(requests), encoding='utf-8')
        env = dict(os.environ)
        lib = env.get('BDL_R_LIB', str(ROOT / '.r-library'))
        env['R_LIBS_USER'] = os.pathsep.join(filter(None, (lib, env.get('R_LIBS_USER'))))
        result = subprocess.run(['Rscript', '--vanilla', str(Path(__file__).with_name('r_graph_exchange.R')),
                                 str(self.root), str(request_file)], env=env, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        native = json.loads(result.stdout)
        self.assertEqual(native, [{'report': self.graph(**opts), 'dot': self.p.export_graph(**opts)} for opts in requests])

    def edit_fixture(self, edit):
        path = self.root / REGISTRY
        state = json.loads(path.read_text())
        edit(state)
        path.write_text(json.dumps(state), encoding='utf-8')
        self.p = ProjectBundle.open(self.root)

    def test_exact_lineage_and_branching(self):
        branch = self.p.register_analysis('independent synthetic branch', [self.original])
        down = self.graph(ref=self.original, direction='downstream', depth=6)
        up = self.graph(ref=self.fig, depth=6)
        self.assertEqual(set(refs(up)), {'DATA-001@1', 'DATA-002@1', 'DATA-003@1', 'ANA-001@1', 'ANA-002@1', 'FIG-001@1'})
        self.assertEqual(set(refs(down)) - set(refs(up)), {exact(branch)})
        expected = [
            ('DATA-001@1', 'ANA-001@1', 'input_to_analysis'), ('ANA-001@1', 'DATA-002@1', 'produced_result'),
            ('DATA-002@1', 'ANA-002@1', 'input_to_analysis'), ('ANA-002@1', 'DATA-003@1', 'produced_result'),
            ('DATA-003@1', 'FIG-001@1', 'rendered_in_figure'),
            ('ANA-002@1', 'FIG-001@1', 'analytical_association')]
        self.assertEqual(set(expected), {(exact(e['from']), exact(e['to']), e['type']) for e in up['edges']})
        self.assertTrue(all(e['basis'] == 'declared' for e in up['edges']))
        self.assertTrue(all(n['execution']['evidence'] == 'unknown' for n in up['nodes']))
        self.assertEqual(self.graph(ref=self.fig, depth=1)['truncation'], ['depth'])
        self.assertEqual(self.graph(ref=self.original, direction='downstream', limit=1)['truncation'], ['node_limit'])
        self.assertEqual(self.p.dependencies(self.fig, 'upstream', depth=3)['execution'], 'unknown')
        self.p.save()
        self.native_parity([{}, {'ref': self.fig, 'depth': 6}, {'ref': self.original, 'direction': 'downstream', 'depth': 6}])

    def test_overview_filters_pages_and_revision_context(self):
        branch = self.p.register_analysis('Neutral name', [self.original], purpose='Synthetic CD8 subset')
        revision = self.p.update_record(self.original, {'name': 'Corrected GEX', 'status': 'inactive'}, 'synthetic correction')
        child = self.p.register_data('original-gex.txt', 'subset', name='Explicit parent', parent=self.original)
        child_scoped = self.p.set_data_scope(child, {'transformation_ref': branch}, 'declared context')
        design = self.p.set_design('condition', ['A', 'B'], context=[self.original])
        designed = self.p.register_analysis('Design-pinned', [self.original])
        dec = self.p.record_scientific_decision('Proposed interpretation', 'synthetic reasoning',
                                               [{'ref': child_scoped}, {'ref': design}], 'provisional')
        self.assertEqual(refs(self.graph(filters={'asset_type': 'ANA', 'query': 'cd8 subset'})), [exact(branch)])
        self.assertEqual(refs(self.graph(filters={'record_status': 'inactive'})), [exact(revision)])
        self.assertEqual(refs(self.graph(filters={'revision': 'historical'})), [exact(self.original), exact(child)])
        selected = self.graph(filters={'anchor': branch})
        self.assertEqual(set(refs(selected)), {exact(branch), exact(self.original), exact(child_scoped)})
        self.assertEqual(types(selected), {'input_to_analysis', 'transformation_context', 'parent_data'})
        decision = self.graph(ref=dec, depth=1)
        self.assertEqual(types(decision), {'decision_concerns'})
        self.assertEqual(decision['nodes'][0]['scientific_status'], 'provisional')
        self.assertEqual(decision['nodes'][0]['approval'], 'not_authenticated')
        self.assertTrue({'design_context', 'design_subject'} <= types(self.graph(ref=designed, depth=2)))
        self.assertIsNone(self.graph(ref=self.original)['nodes'][0]['superseded_at_utc'])
        all_nodes, offset = [], 0
        while offset is not None:
            page = self.graph(limit=3, offset=offset)
            self.assertEqual(page['edge_scope'], 'induced_page')
            if page['next_offset'] is not None:
                self.assertGreater(page['next_offset'], offset)
                self.assertTrue(page['truncated'])
            all_nodes.extend(refs(page))
            offset = page['next_offset']
        self.assertEqual(all_nodes, refs(self.graph()))
        self.assertEqual(len(set(all_nodes)), len(all_nodes))
        self.assertTrue(self.graph()['snapshot']['unsaved'])
        registration_day = self.graph(ref=self.original)['nodes'][0]['registration_at_utc'][:10]
        self.assertIn(exact(self.original), refs(self.graph(filters={'registered_on': registration_day})))
        with self.assertRaises(BundleError):
            self.graph(ref={**self.original, 'project_id': '00000000-0000-0000-0000-000000000000'})
        self.p.save()
        self.native_parity([{}, {'filters': {'anchor': branch}}, {'filters': {'asset_type': 'RESULT'}},
                            {'filters': {'revision': 'historical'}}, {'limit': 3, 'offset': 3}])

    def test_read_only_escaping_and_receipt_timing(self):
        code = self.root / 'entry.py'
        code.write_text('def run(inputs, params, seeds, outputs):\n    pass\n')
        template = self.p.register_analysis('α "quote" \\N\n<IMG SRC="bad">', [], code='entry.py', params={})
        first, second = [self.p.run_analysis(template, 'run') for _ in range(2)]
        for filename in ('original-gex.txt', 'analysis-ready-gex.txt', 'umap.csv', 'figure.svg', 'entry.py'):
            (self.root / filename).unlink()
        def timing(state):
            for rec in state['records']:
                if rec['id'] in (first['receipt_ref']['id'], second['receipt_ref']['id']):
                    receipt = rec['details']['execution_receipt']
                    receipt['started_at_utc'] = '2020-01-02T00:00:00Z'
                    if rec['revision'] == 2:
                        receipt['ended_at_utc'] = '2020-01-02T00:00:01Z'
                if rec['id'] == self.original['id']:
                    rec['created_at'] = 'unknown'
        self.edit_fixture(timing)
        path = self.root / REGISTRY
        before = path.read_bytes()
        with patch.object(Path, 'open', side_effect=AssertionError('unexpected payload or registry I/O')), \
                patch.object(Path, 'stat', side_effect=AssertionError('unexpected path probe')):
            dot = self.p.export_graph()
            self.assertEqual(dot, self.p.export_graph())
            report = self.graph(filters={'executed_on': '2020-01-02'})
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(refs(report), [exact(first['receipt_ref']), exact(second['receipt_ref'])])
        self.assertEqual(report['nodes'][0]['execution'], report['nodes'][1]['execution'])
        self.assertEqual(report['nodes'][0]['execution']['timing_status'], 'valid_interval')
        self.assertIsNone(self.graph(ref=self.original)['nodes'][0]['registration_at_utc'])
        self.assertIn(r'α \"quote\" \\N\n<IMG SRC=\"bad\">', dot)
        self.assertIn('registered: unknown', dot)
        self.native_parity([{}, {'filters': {'executed_on': '2020-01-02'}}, {'ref': template}])

    def test_optional_unknowns_cycles_and_core_validation(self):
        dec = self.p.record_decision('Legacy targets', 'synthetic', [self.original])
        self.p.save()
        missing = {**self.original, 'id': 'DATA-999'}
        def fixture(state):
            for rec in state['records']:
                if rec['id'] == dec['id']:
                    rec['details']['targets'] += [missing, ['bad']]
                if rec['id'] == self.original['id']:
                    rec['details']['parent'] = self.original
        self.edit_fixture(fixture)
        report = self.graph(ref=self.original)
        self.assertEqual(report['cycle'], 'detected')
        self.assertEqual(types(report), {'parent_data'})
        item = self.graph(ref=dec)['nodes'][0]['issue']
        self.assertEqual((item['reason'], item['related_ref'], item['count']), ('unresolved_decision_target', missing, 2))
        self.native_parity([{}, {'ref': dec}, {'ref': self.original}])
        def long_target(state):
            rec = next(r for r in state['records'] if r['id'] == dec['id'])
            rec['details']['targets'] = [{**missing, 'id': 'DATA-' + '9' * 140000}]
        self.edit_fixture(long_target)
        self.assertTrue(self.graph(ref=dec)['nodes'][0]['issue']['identity_omitted'])
        self.native_parity([{'filters': {'asset_type': 'DEC'}, 'limit': 1}, {'ref': dec}])
        def truncated_targets(state):
            rec = next(r for r in state['records'] if r['id'] == dec['id'])
            rec['details']['targets'] = [missing] * 1000 + [self.original]
        self.edit_fixture(truncated_targets)
        self.assertIn('decision_target_limit', self.graph(ref=self.original, direction='downstream')['truncation'])
        self.native_parity([{'ref': self.original, 'direction': 'downstream'}, {'ref': dec}])
        with self.assertRaisesRegex(BundleError, 'dangling'):
            self.edit_fixture(lambda state: state['records'][0]['details'].update(parent=missing))
        with self.assertRaises(BundleError):
            self.graph(ref='FIG-999@1')
        legacy = json.loads((ROOT / 'tests/fixtures/minimal.json').read_text())
        self.assertEqual(legacy['schema_version'], '0.1.0')
        (self.root / REGISTRY).write_text(json.dumps(legacy))
        self.p = ProjectBundle.open(self.root)
        self.native_parity([{}])

    def test_bounded_scan_and_long_labels(self):
        for i in range(1000):
            self.p.register_data('s3://synthetic-placeholder/never-read', 'synthetic', name='µ' * 300 if i == 0 else f'Slot {i}')
        page = self.graph(filters={'asset_type': 'DEC'})
        self.assertEqual(page['scanned_record_slots'], 1000)
        self.assertEqual(page['next_offset'], 1000)
        self.assertEqual(page['truncation'], ['scan_limit'])
        self.assertEqual(self.graph(filters={'asset_type': 'DEC'}, offset=1000)['nodes'], [])
        selected = self.graph(filters={'query': 'µµµ'})
        self.assertTrue(selected['nodes'][0]['label_truncated'])
        self.assertLessEqual(len(selected['nodes'][0]['label'].encode('utf-8')), 192)
        for kwargs in ({'depth': 11}, {'limit': 101}, {'filters': {'registered_on': '2020-02-31'}},
                       {'ref': self.fig, 'filters': {}}, {'filters': {'asset_type': 'unknown'}}):
            with self.assertRaises(BundleError):
                self.graph(**kwargs)


if __name__ == '__main__':
    unittest.main()
