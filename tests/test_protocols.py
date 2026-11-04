"""Synthetic ordered-protocol acceptance using installed native clients."""
import copy
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle
from biodataledger.execution import ExecutionError


CODE = """from pathlib import Path
def run(inputs, params, seeds, outputs):
    if params.get('fail'):
        raise RuntimeError('synthetic failure')
    if not params.get('skip'):
        for path in outputs:
            Path(path).write_text('value\\n1\\n')
"""


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'input.txt').write_text('synthetic\n')
        (self.root / 'code.py').write_text(CODE)
        self.p = ProjectBundle.create('synthetic protocols', self.root)
        self.data = self.p.register_data('input.txt', 'input', hash=True)
        self.params = {'resolution': 0.5, 'dynamic': 'selection rule', 'nullable': None}
        self.analysis = self.analysis_record()
        self.step = {'step_id': 'one', 'analysis_ref': self.analysis,
                     'required_outputs': [{'kind': 'result'}], 'data_dependent_params': ['dynamic']}
        self.output_count = 0

    def analysis_record(self, **changes):
        values = dict(name='template', inputs=[self.data], code='code.py', method='synthetic', params=self.params)
        values.update(changes)
        return self.p.register_analysis(**values)

    def protocol(self, steps=None):
        return self.p.register_protocol('ordered', steps or [self.step], 'synthetic intent')

    def run_record(self, analysis=None, **options):
        self.output_count += 1
        outputs = options.pop('outputs', [{'path': 'out%d.txt' % self.output_count, 'kind': 'result'}])
        try:
            return self.p.run_analysis(analysis or self.analysis, 'run', outputs=outputs, **options)
        except ExecutionError as error:
            return error.receipt

    def compare(self, protocol, receipt, **options):
        return self.p.compare_protocol(protocol, [{'step_id': 'one', 'analysis_ref': receipt['receipt_ref']}], **options)

    def native(self, request):
        request_path = self.root / 'exchange-request.json'
        request_path.write_text(json.dumps(request))
        env = dict(os.environ)
        library = env.get('BDL_R_LIB', str(Path(__file__).resolve().parents[1] / '.r-library'))
        env['R_LIBS_USER'] = os.pathsep.join(filter(None, (library, env.get('R_LIBS_USER', ''))))
        result = subprocess.run(['Rscript', '--vanilla', str(Path(__file__).with_name('r_protocols_exchange.R')),
                                 str(self.root), str(request_path)], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_revisions_defaults_approval_and_mutation_guards(self):
        first = self.protocol()
        original = copy.deepcopy(self.p._record(first))
        approval = self.p.record_scientific_decision('approved', 'submitted', [{'ref': first}], 'approved')
        second = self.p.register_protocol('revision two', [dict(self.step, data_dependent_params=[])], 'revision', ref=first)
        self.assertEqual(self.p._record(first), original)
        self.assertEqual(second['revision'], 2)
        self.assertIsNone(self.p.get_protocol(first)['protocol']['steps'][0]['seeds'])
        self.assertEqual(self.p.compare_protocol(first, [], approval_ref=approval)['approval']['status'], 'match')
        self.assertEqual(self.p.compare_protocol(second, [], approval_ref=approval)['approval']['status'], 'mismatch')
        for operation in (
            lambda: self.p.register_protocol('stale', [self.step], 'why', ref=first),
            lambda: self.p.update_record(second, {'name': 'bad'}, 'bad'),
            lambda: self.p.update_record(second, {'status': 'inactive'}, 'bad'),
            lambda: self.p.update_record(self.analysis, {'details': {'analysis_protocol': {}}}, 'bad'),
            lambda: self.p.register_analysis('bad', [], analysis_protocol={}),
            lambda: self.p.register_data('input.txt', 'bad', analysis_protocol={}),
            lambda: self.p.register_figure('input.txt', 'bad', analysis_protocol={}),
            lambda: self.p.register_protocol('bad', [self.step], 'bad', ref=approval),
            lambda: self.p.record_scientific_decision('bad', 'why', [{'ref': self.data}], 'approved', ref=second),
        ):
            with self.assertRaises(BundleError): operation()
        self.p.save_and_confirm()
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_protocol(first), self.p.get_protocol(first))
        self.assertEqual(reopened.get_protocol(second)['name'], 'revision two')

    def test_fixed_parameter_changes_and_dynamic_values_are_distinct(self):
        protocol = self.protocol()
        for fixed, dynamic, mismatch in [(0.8, 12, True), (0.5, 12, False), (True, 12, True), (0.5, None, False)]:
            selected = self.analysis_record(params=dict(self.params, resolution=fixed, dynamic=dynamic))
            receipt = self.run_record(selected)
            report = self.compare(protocol, receipt)['steps'][0]
            self.assertEqual('params.resolution' in report['mismatches'], mismatch)
            self.assertNotIn('analysis_ref', report['mismatches'])
            self.assertEqual(report['receipt_template_ref'], selected)
            self.assertEqual(report['data_dependent_observations']['dynamic'], dynamic)
        missing = self.analysis_record(params={'resolution': 0.5})
        report = self.compare(protocol, self.run_record(missing))['steps'][0]
        self.assertIn('params.nullable', report['mismatches'])
        self.assertIn('data_dependent_param.dynamic', report['unknown'])
        numeric = self.protocol([dict(self.step, analysis_ref=self.analysis_record(params={'n': 1}), data_dependent_params=[])])
        report = self.compare(numeric, self.run_record(self.analysis_record(params={'n': 1.0})))['steps'][0]
        self.assertNotIn('params.n', report['mismatches'])

    def test_mixed_protocol_descriptor_cannot_supply_scientific_approval(self):
        protocol = self.protocol()
        approval = self.p.record_scientific_decision('approved', 'submitted', [{'ref': protocol}], 'approved')
        self.assertEqual(self.p.compare_protocol(protocol, [], approval_ref=approval)['approval']['status'], 'match')
        self.p.save_and_confirm()
        state_path = self.root / '.nb_project_bundle/project.json'
        state = json.loads(state_path.read_text())
        # Simulate malformed external metadata; supported writers reject this conversion.
        record = next(rec for rec in state['records'] if rec['id'] == approval['id'])
        record['details']['analysis_protocol'] = copy.deepcopy(self.p._record(protocol)['details']['analysis_protocol'])
        state_path.write_text(json.dumps(state))
        project = ProjectBundle.open(self.root)
        view = project.get_decision(approval)
        from biodataledger.comparison import _approval
        observed = {
            'scientific': view['scientific'], 'approval': view['approval'],
            'protocol_approval': project.compare_protocol(protocol, [], approval_ref=approval)['approval']['status'],
            'comparison_approval': _approval(project, approval, protocol),
        }
        script = r'''
args <- commandArgs(TRUE)
library(BioDataLedger)
p <- ProjectBundle$open(args[[1]])
view <- p$get_decision(args[[3]])
report <- p$compare_protocol(args[[2]], list(), approval_ref = args[[3]])
cat(jsonlite::toJSON(list(scientific = view$scientific, approval = view$approval,
  protocol_approval = report$approval$status), auto_unbox = TRUE, null = "null"))
'''
        env = dict(os.environ)
        library = env.get('BDL_R_LIB', str(Path(__file__).resolve().parents[1] / '.r-library'))
        env['R_LIBS_USER'] = os.pathsep.join(filter(None, (library, env.get('R_LIBS_USER', ''))))
        result = subprocess.run(['Rscript', '--vanilla', '-', str(self.root),
                                 protocol['id'] + '@1', approval['id'] + '@1'],
                                input=script, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        native = json.loads(result.stdout)
        expected = {'scientific': None, 'approval': 'not_applicable', 'protocol_approval': 'unknown'}
        self.assertEqual({'python': observed, 'R': native},
                         {'python': dict(expected, comparison_approval='UNKNOWN'), 'R': expected})

    def test_wrong_exact_inputs_method_code_design_and_input_mode(self):
        protocol = self.protocol()
        other = self.p.register_data('input.txt', 'other identity', hash=True)
        (self.root / 'other.py').write_text(CODE)
        design = self.p.set_design('condition', ['a', 'b'])
        for changes, field in [({'inputs': [other]}, 'inputs'), ({'method': 'different'}, 'method'),
                               ({'code': 'other.py'}, 'code'), ({'design_ref': design}, 'design'),
                               ({'input_mode': 'combined', 'design_ref': None}, 'input_mode')]:
            with self.subTest(field=field):
                report = self.compare(protocol, self.run_record(self.analysis_record(**changes)))['steps'][0]
                self.assertIn(field, report['mismatches'])

    def test_missing_extra_reordered_and_observed_chronology(self):
        protocol = self.protocol([self.step, dict(self.step, step_id='two')])
        tick = [0]
        def clock():
            tick[0] += 2
            return (datetime(2026, 1, 1) + timedelta(seconds=tick[0])).strftime('%Y-%m-%dT%H:%M:%SZ')
        with patch('biodataledger.core.now', side_effect=clock):
            first, second = self.run_record(), self.run_record()
        selections = [{'step_id': 'one', 'analysis_ref': first['receipt_ref']},
                      {'step_id': 'two', 'analysis_ref': second['receipt_ref']}]
        report = self.p.compare_protocol(protocol, selections)
        self.assertEqual(report['order'], 'match')
        self.assertEqual(report['observed_order'], 'strict_nonoverlap_in_submitted_order')
        reversed_list = self.p.compare_protocol(protocol, list(reversed(selections)))
        self.assertEqual(reversed_list['order'], 'mismatch')
        self.assertEqual(reversed_list['observed_order'], 'different_from_submitted_order')
        swapped_evidence = [dict(selections[0], analysis_ref=second['receipt_ref']), dict(selections[1], analysis_ref=first['receipt_ref'])]
        self.assertEqual(self.p.compare_protocol(protocol, swapped_evidence)['observed_order'], 'different_from_submitted_order')
        missing = self.p.compare_protocol(protocol, selections[:1])
        self.assertIn('missing_step', missing['steps'][1]['mismatches'])
        extra = self.p.compare_protocol(protocol, selections + [{'step_id': 'extra', 'analysis_ref': self.analysis}])
        self.assertEqual(extra['extra_steps'], ['extra'])
        with self.assertRaises(BundleError): self.p.compare_protocol(protocol, [selections[0], selections[0]])
        # Both clients inspect the same persisted synthetic timing observations.
        native = self.native({'mode': 'compare', 'protocol': protocol, 'executions': selections})
        self.assertEqual(native['report'], report)
        self.assertEqual(native['protocol'], self.p.get_protocol(protocol))
        raw = self.p._record(second['receipt_ref'])['details']['execution_receipt']
        raw['started_at_utc'] = first['started_at_utc']
        self.assertEqual(self.p.compare_protocol(protocol, selections)['observed_order'], 'unknown')
        raw['started_at_utc'] = 'not a timestamp'
        self.assertEqual(self.p.compare_protocol(protocol, selections)['observed_order'], 'unknown')

    def test_absent_failed_blocked_incomplete_and_unchecked_evidence(self):
        protocol = self.protocol()
        absent = self.p.compare_protocol(protocol, [{'step_id': 'one', 'analysis_ref': self.analysis}])
        self.assertIn('execution_receipt', absent['steps'][0]['unknown'])
        for flag, status in [('fail', 'failed'), ('skip', 'incomplete')]:
            receipt = self.run_record(self.analysis_record(params=dict(self.params, **{flag: True})))
            self.assertEqual(receipt['status'], status)
            self.assertIn('execution_status.' + status, self.compare(protocol, receipt)['steps'][0]['mismatches'])
        (self.root / 'input.txt').write_text('changed input')
        blocked = self.run_record()
        self.assertEqual(blocked['status'], 'blocked')
        self.assertIn('execution_status.blocked', self.compare(protocol, blocked)['steps'][0]['mismatches'])
        unchecked = self.run_record(verify_inputs=False)
        self.assertEqual(unchecked['status'], 'succeeded')
        self.assertIn('input_identity', self.compare(protocol, unchecked)['steps'][0]['unknown'])
        malformed = self.p._record(unchecked['receipt_ref'])['details']['execution_receipt']
        malformed['version'] = 'unsupported'
        self.assertIn('execution_receipt', self.compare(protocol, unchecked)['steps'][0]['unknown'])

    def test_required_output_order_and_seed_requirements(self):
        expected = [{'kind': 'result'}, {'kind': 'figure', 'type': 'synthetic'}]
        protocol = self.protocol([dict(self.step, required_outputs=expected, seeds={'random': 42})])
        outputs = [{'path': 'fig.txt', 'kind': 'figure', 'type': 'synthetic'}, {'path': 'table.txt', 'kind': 'result'}]
        receipt = self.run_record(outputs=outputs, seeds={'random': 7})
        report = self.compare(protocol, receipt)['steps'][0]
        self.assertIn('required_outputs', report['mismatches'])
        self.assertIn('seeds', report['mismatches'])
        unconstrained = self.protocol()
        report = self.compare(unconstrained, self.run_record(seeds={'random': 1}))['steps'][0]
        self.assertNotIn('seeds', report['mismatches'])
        self.assertIn('seeds', report['unknown'])

    def test_import_preserves_intent_without_promoting_approval_or_order(self):
        protocol = self.protocol([self.step, dict(self.step, step_id='two')])
        approval = self.p.record_scientific_decision('approved', 'synthetic', [{'ref': protocol}], 'approved')
        timestamps = ((datetime(2026, 1, 1) + timedelta(seconds=2*i)).strftime('%Y-%m-%dT%H:%M:%SZ') for i in range(100))
        with patch('biodataledger.core.now', side_effect=lambda: next(timestamps)):
            first, second = self.run_record(), self.run_record()
        selected = [{'step_id': 'one', 'analysis_ref': first['receipt_ref']}, {'step_id': 'two', 'analysis_ref': second['receipt_ref']}]
        archive = self.root / 'context.zip'
        self.p.export_zip(self.p.preview_export('context'), archive)
        imported = ProjectBundle.import_zip(archive, self.root / 'imported')
        report = imported.compare_protocol(protocol, selected, approval_ref=approval)
        self.assertEqual(report['approval']['status'], 'unknown')
        self.assertEqual(report['observed_order'], 'unknown')
        self.assertTrue(all('execution_receipt' in step['unknown'] for step in report['steps']))
        self.assertEqual(imported.get_protocol(protocol)['protocol'], self.p.get_protocol(protocol)['protocol'])

    def test_read_only_queries_do_not_hash_load_or_save(self):
        protocol = self.protocol()
        receipt = self.run_record()
        path = self.root / '.nb_project_bundle/project.json'
        before = path.read_bytes()
        with patch('biodataledger.core.fingerprint', side_effect=AssertionError('hash')),\
             patch.object(Path, 'open', side_effect=AssertionError('payload read')),\
             patch.object(self.p, 'save', side_effect=AssertionError('save')):
            self.p.get_protocol(protocol)
            self.compare(protocol, receipt)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(self.p.unsaved)

    def test_malformed_unknown_and_bounded_contracts(self):
        unknown = self.analysis_record(inputs=None, method=None, params=None)
        with self.assertRaises(BundleError): self.protocol([dict(self.step, analysis_ref=unknown)])
        for dynamic in [None, [{}], ['dynamic', 'dynamic'], ['absent']]:
            with self.assertRaises(BundleError): self.protocol([dict(self.step, data_dependent_params=dynamic)])
        with self.assertRaises(BundleError): self.protocol([dict(self.step, step_id=str(i)) for i in range(101)])
        large = self.analysis_record(params={'x': 'x' * 65536})
        with self.assertRaises(BundleError): self.protocol([dict(self.step, analysis_ref=large, data_dependent_params=[])])
        protocol = self.protocol()
        with self.assertRaises(BundleError): self.p.compare_protocol(protocol, [{'step_id': 'one', 'analysis_ref': large}])
        original = copy.deepcopy(self.p._record(protocol))
        self.p._record(protocol)['details']['targets'] = []
        self.assertEqual(self.p.get_protocol(protocol)['unknown'], ['malformed_analysis_protocol'])
        self.p._record(protocol)['details'] = original['details']
        self.p._record(protocol)['details']['analysis_protocol']['version'] = 'future'
        self.assertEqual(self.p.get_protocol(protocol)['unknown'], ['unsupported_analysis_protocol'])

    def test_native_comparison_and_native_revision_roundtrip(self):
        protocol = self.protocol()
        changed = self.analysis_record(params={'resolution': True, 'dynamic': None})
        receipt = self.run_record(changed, verify_inputs=False)
        selected = [{'step_id': 'one', 'analysis_ref': receipt['receipt_ref']}]
        expected = self.p.compare_protocol(protocol, selected)
        native = self.native({'mode': 'revise', 'protocol': protocol, 'executions': selected})
        self.assertEqual(native['report'], expected)
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_protocol(native['new_ref']), native['new_view'])
        self.assertEqual(reopened.get_protocol(protocol)['protocol'], self.p.get_protocol(protocol)['protocol'])
        imported = ProjectBundle.import_zip(native['archive'], self.root / 'native-import')
        self.assertEqual(imported.get_protocol(native['new_ref'])['protocol'], native['new_view']['protocol'])
        # R produced a genuine receipt; Python reads and compares it without execution.
        self.assertEqual(reopened.compare_protocol(native['native_protocol'], native['native_selection']), native['native_report'])


if __name__ == '__main__':
    unittest.main()
