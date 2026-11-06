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
from xml.etree import ElementTree

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
        self.assertEqual(native, [
            {'report': self.graph(**{k: v for k, v in opts.items() if k not in ('style', 'lineage_roots')}),
             'dot': self.p.export_graph(**opts)} for opts in requests])

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

    def diagram(self, **opts):
        return self.p.export_graph(style='presentation', **opts)

    def split_branches(self):
        a = self.p.register_data('original-gex.txt', 'subset', name='Assigned only', parent=self.original)
        b = self.p.register_data('original-gex.txt', 'subset', name='Assigned plus unassigned', parent=self.original)
        analysis = self.p.register_analysis('Compare cohorts', [a, b])
        result = self.p.register_result('umap.csv', analysis)
        figure = self.p.register_figure('figure.svg', 'umap', analysis=analysis, name='Combined comparison',
                                        figure_sources={'rendering_inputs': [result], 'relationship': 'declared'})
        return a, b, analysis, result, figure

    def test_presentation_uses_the_same_report_and_matches_native_r(self):
        a, b, _, _, figure = self.split_branches()
        self.p.save()
        opts = {'ref': figure, 'depth': 7}
        default_dot = self.p.export_graph(**opts)
        self.assertEqual(self.p.export_graph(style='detailed', **opts), default_dot)
        self.assertEqual(self.p.export_graph(style='detailed', format='structured', **opts), self.graph(**opts))
        self.assertNotIn('rankdir=', default_dot)
        styled = self.diagram(lineage_roots=[a, exact(b)], **opts)
        self.assertIn('rankdir=TB', styled)
        record_nodes = {line.split('"')[1] for line in styled.splitlines()
                        if line.startswith(('  "DATA-', '  "ANA-', '  "FIG-')) and ' [shape=' in line}
        record_edges = {tuple(line.split('"')[i] for i in (1, 3)) for line in styled.splitlines() if ' -> ' in line}
        report = self.graph(**opts)
        self.assertEqual(record_nodes, set(refs(report)))
        self.assertEqual(record_edges, {(exact(e['from']), exact(e['to'])) for e in report['edges']})
        shallow = self.diagram(ref=figure, depth=1, lineage_roots=[a, b])
        self.assertIn(f'Source 1: {exact(a)} (not in view)', shallow)
        self.assertNotIn('#17628D', shallow)
        self.native_parity([opts, {**opts, 'style': 'presentation', 'lineage_roots': [a, exact(b)]},
                            {'ref': figure, 'depth': 1, 'style': 'presentation', 'lineage_roots': [a, b]},
                            {'style': 'presentation', 'limit': 2, 'lineage_roots': [a, b]}])
        revised_a = self.p.update_record(a, {'name': 'New cohort name'}, 'synthetic rename')
        revised_figure = self.p.update_record(figure, {'name': 'New figure name'}, 'synthetic rename')
        self.p.save()
        focus_opts = {'ref': revised_figure, 'depth': 8}
        self.assertIn(exact(figure), refs(self.graph(**focus_opts)))
        styled = self.diagram(lineage_roots=[a, b], **focus_opts)
        self.assertIn(f'FIGURE  ·  {exact(revised_figure)}', styled)
        self.assertIn(f'DATA  ·  {exact(a)}', styled)
        self.assertNotIn(exact(revised_a), styled)
        self.assertNotIn(exact(figure), styled)
        self.assertIn('Revision history omitted (records: 1; links: 3). See detailed view.', styled)
        down = self.diagram(ref=figure, direction='downstream', depth=1)
        self.assertNotIn(exact(revised_figure), down)
        self.native_parity([{**focus_opts, 'style': 'presentation', 'lineage_roots': [a, b]},
                            {'ref': figure, 'direction': 'downstream', 'style': 'presentation'}])

    def test_presentation_colors_stop_at_roots_and_context_edges(self):
        a, b, analysis, result, figure = self.split_branches()
        subset = self.p.register_figure('figure.svg', 'umap', analysis=analysis, name='One cohort only',
                                        figure_sources={'rendering_inputs': [a], 'relationship': 'declared'})
        unknown = self.p.register_figure('figure.svg', 'umap', analysis=analysis,
                                         figure_sources={'rendering_inputs': [b], 'relationship': 'unknown'})
        revised = self.p.update_record(a, {'name': 'New revision'}, 'synthetic rename')
        explicit = self.p.register_data('umap.csv', 'result', name='Explicit transformation')
        explicit = self.p.set_data_scope(explicit, {'transformation_ref': analysis}, 'record transformation')
        standalone = self.p.register_figure('figure.svg', 'umap', inputs=[a],
                                            figure_sources={'rendering_inputs': [b], 'relationship': 'declared'})
        legacy = self.p.register_figure('figure.svg', 'umap', inputs=[a])
        self.p.save()
        dot = self.diagram(lineage_roots=[a, b])

        def node(ref, text=dot):
            return next(line for line in text.splitlines() if line.startswith(f'  "{exact(ref)}" [shape='))

        def edge(source, target, text=dot):
            return next(line for line in text.splitlines() if line.startswith(f'  "{exact(source)}" -> "{exact(target)}"'))

        self.assertNotIn('Source ', node(self.original))
        self.assertIn('Source boundary 1', node(a))
        self.assertIn('Source boundary 2', node(b))
        for mixed in (analysis, result, figure, explicit):
            self.assertIn('Sources 1 + 2 (mixed)', node(mixed))
        self.assertIn('color="#17628D:#A24520"', edge(result, figure))
        self.assertIn('style=dashed, constraint=false, color="#64748B"', edge(analysis, subset))
        self.assertIn(r'\nSource 1\n', node(subset))
        self.assertIn(r'\nSource 2\n', node(standalone))
        self.assertNotIn('mixed', node(standalone))
        self.assertNotIn('Rendering inputs unknown', node(standalone))
        self.assertIn('style=dashed, constraint=false, color="#64748B", label="analytical input"', edge(a, standalone))
        self.assertIn('color="#A24520"', edge(b, standalone))
        self.assertNotIn('Source ', node(legacy))
        self.assertIn('Rendering inputs unknown', node(legacy))
        self.assertIn('label="analytical input"', edge(a, legacy))
        self.assertNotIn('Source ', node(unknown))
        self.assertIn('Rendering link unconfirmed', node(unknown))
        self.assertNotIn('Rendering inputs unknown', node(unknown))
        self.assertIn('label="rendering unconfirmed"', edge(b, unknown))
        self.assertNotIn('Source ', node(revised))
        self.assertIn('label="revision"', edge(a, revised))
        reset = self.diagram(lineage_roots=[self.original, a, b])
        self.assertIn('color="#17628D"', edge(self.original, a, reset))
        self.assertIn('color="#A24520"', edge(a, analysis, reset))
        self.assertIn('Sources 2 + 3 (mixed)', node(analysis, reset))
        self.native_parity([{'style': 'presentation', 'lineage_roots': [self.original, a, b]},
                            *[{'ref': fig, 'style': 'presentation', 'lineage_roots': [a, b]}
                              for fig in (standalone, legacy, unknown)]])

    def test_presentation_notes_use_exact_declarations_and_flag_clipping(self):
        (self.root / 'private-scripts').mkdir()
        (self.root / 'private-scripts' / 'plot_α.py').write_text('pass\n')
        analysis = self.p.register_analysis('With candidate code', [self.original], code='private-scripts/plot_α.py')
        figure = self.p.register_figure(
            'figure.svg', 'umap', analysis=analysis, name='µ' * 100,
            figure_sources={'generating_code': {'record': analysis, 'index': 0}})
        no_selector = self.p.register_figure('figure.svg', 'umap', analysis=analysis)
        fields = {'primary_topic': 'Cohort', 'description': 'Summary', 'generated_on': '2026-11-05', 'reason': 'Context'}
        first = 'What does α "mean" \\N <IMG SRC="bogus">? ' + 'µ' * 55
        annotated = self.p.set_presentation(figure, questions=[first, first] + [f'Question {i}' for i in range(6)], **fields)
        self.p.set_presentation(no_selector, questions=[first, 'Keep this', 'Omit this'], **fields)
        self.p.save()
        dot = self.diagram()
        self.assertEqual(dot.count('Question context'), 8)
        self.assertIn(r'α \"mean\" \\N <IMG SRC=\"bogus\">?', dot)
        self.assertIn('µ…', dot)
        self.assertNotIn('Omit this', dot)
        self.assertIn('Annotation links omitted: questions 1; plotting code 0', dot)
        self.assertIn(f'Declared plotting code\\nplot_α.py\\n{exact(analysis)} · entry 0 · sha256 ', dot)
        self.assertEqual(dot.count('Declared plotting code'), 1)
        self.assertIn('Plotting code unknown', dot)
        self.assertNotIn('private-scripts', dot)
        self.assertEqual(self.p.get_info(annotated)['presentation']['questions'][0], first)
        self.native_parity([{'style': 'presentation'}, {'ref': annotated, 'style': 'presentation'}])

    def test_presentation_preserves_bounds_and_does_no_query_io(self):
        for opts in ({'style': 'not-a-style'}, {'format': 'structured', 'style': 'presentation'},
                     {'lineage_roots': []}, {'style': 'presentation', 'lineage_roots': 'DATA-001@1'},
                     {'style': 'presentation', 'lineage_roots': [self.original] * 7},
                     {'style': 'presentation', 'lineage_roots': [self.original, exact(self.original)]},
                     {'style': 'presentation', 'lineage_roots': ['DATA-001']},
                     {'style': 'presentation', 'lineage_roots': ['DATA-999@1']},
                     {'style': 'presentation', 'lineage_roots': [self.fig]},
                     {'style': 'presentation', 'lineage_roots': [{**self.original, 'project_id': 'foreign'}]}):
            with self.subTest(opts=opts), self.assertRaises(BundleError):
                self.p.export_graph(**opts)
        def cycle(state):
            state['records'][0]['details']['parent'] = self.original
            state['imported'] = True
        self.edit_fixture(cycle)
        self.p.register_analysis('Unsaved', [self.original])
        with patch.object(Path, 'open', side_effect=AssertionError('unexpected file I/O')), \
                patch.object(Path, 'stat', side_effect=AssertionError('unexpected path probe')), \
                patch.object(Path, 'resolve', side_effect=AssertionError('unexpected path resolution')), \
                patch.object(subprocess, 'Popen', side_effect=AssertionError('unexpected process')):
            cycle_dot = self.diagram(ref=self.original, lineage_roots=[self.original])
            cut_dot = self.diagram(ref=self.fig, depth=1)
        self.assertIn('Visible cycle check: detected', cycle_dot)
        self.assertIn('Imported records; execution claims unverified', cycle_dot)
        self.assertIn('Includes unsaved edits', cycle_dot)
        self.assertIn('Omissions: depth', cut_dot)
        self.assertLessEqual(len(cycle_dot.encode('utf-8')), 128 * 1024)
        with patch('biodataledger.diagram.BYTE_LIMIT', 300), self.assertRaisesRegex(BundleError, 'narrower view'):
            self.diagram(ref=self.original)

    def test_presentation_dot_renders_mixed_edges_with_graphviz(self):
        renderer = os.environ.get('BDL_GRAPHVIZ_DOT') or shutil.which('dot')
        if not renderer:
            self.skipTest('optional Graphviz dot executable unavailable')
        a, b, _, result, figure = self.split_branches()
        self.p.set_presentation(figure, primary_topic='Cohort', description='Summary', generated_on='2026-11-05',
                                questions=['Cohort comparison: α "quoted" \\N <IMG SRC="bogus">?'], reason='Context')
        dot = self.diagram(lineage_roots=[a, b])
        rendered = subprocess.run([renderer, '-Tsvg'], input=dot, capture_output=True, text=True, timeout=15, check=True)
        self.assertEqual(rendered.stderr, '')
        svg = ElementTree.fromstring(rendered.stdout)
        ns = {'s': 'http://www.w3.org/2000/svg'}
        text = [item.text for item in svg.findall('.//s:text', ns)]
        self.assertIn('Recorded lineage', text)
        self.assertIn('Sources 1 + 2 (mixed)', text)
        self.assertIn('Cohort comparison: α "quoted" \\N <IMG SRC="bogus">?', text)
        self.assertFalse(svg.findall('.//s:image', ns))
        edges = [g for g in svg.findall('.//s:g[@class="edge"]', ns)
                 if g.find('s:title', ns).text == f'{exact(result)}->{exact(figure)}']
        self.assertEqual(len(edges), 1)
        self.assertEqual({p.get('stroke').lower() for p in edges[0].findall('s:path', ns)}, {'#17628d', '#a24520'})


if __name__ == '__main__':
    unittest.main()
