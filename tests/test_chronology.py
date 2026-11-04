"""Synthetic receipt history: partial orders, bounded pages and native parity."""
import copy
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
        for output in outputs:
            Path(output).write_text('synthetic')
"""


class ChronologyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / 'input.txt').write_text('synthetic')
        (self.root / 'code.py').write_text(CODE)
        self.p = ProjectBundle.create('synthetic chronology', self.root)
        self.data = self.p.register_data('input.txt', 'input', hash=True)
        self.a = self.template()
        self.counter = 0
        self.fixture_revision = 0

    def template(self, **params):
        return self.p.register_analysis('synthetic', [self.data], code='code.py', method='synthetic', params=params)

    def run_record(self, ref=None):
        self.counter += 1
        try:
            return self.p.run_analysis(ref or self.a, 'run', [{'path': 'out%d.txt' % self.counter, 'kind': 'result'}])
        except ExecutionError as error:
            return error.receipt

    def interval(self, receipt, start, end):
        # Controlled timing fixtures, not edits to any real execution history.
        raw = self.p._record(receipt['receipt_ref'])['details']['execution_receipt']
        raw['started_at_utc'], raw['ended_at_utc'] = start, end

    def persist_fixture(self):
        self.fixture_revision += 1
        self.p.set_context({'next_task': 'synthetic timing fixture ' + str(self.fixture_revision)})
        self.p.save_and_confirm()

    def native(self, **request):
        request_path = self.root / 'chronology-request.json'
        request_path.write_text(json.dumps(request))
        env = dict(os.environ)
        library = env.get('BDL_R_LIB', str(Path(__file__).resolve().parents[1] / '.r-library'))
        env['R_LIBS_USER'] = os.pathsep.join(filter(None, (library, env.get('R_LIBS_USER', ''))))
        completed = subprocess.run(['Rscript', '--vanilla', str(Path(__file__).with_name('r_chronology_exchange.R')),
                                    str(self.root), str(request_path)], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        return json.loads(completed.stdout)

    def test_registration_protocol_and_execution_orders_are_separate(self):
        b = self.template(n=2)
        protocol = self.p.register_protocol('intent', [
            {'step_id': 'b-first', 'analysis_ref': b, 'required_outputs': []},
            {'step_id': 'a-second', 'analysis_ref': self.a, 'required_outputs': []}], 'synthetic intent')
        first, second = self.run_record(self.a), self.run_record(b)
        self.interval(first, '2020-01-01T00:00:05Z', '2020-01-01T00:00:06Z')
        self.interval(second, '2020-01-01T00:00:01Z', '2020-01-01T00:00:02Z')
        before = copy.deepcopy(self.p.state)
        with patch.object(self.p, 'dependencies', side_effect=AssertionError('must not infer graph order')):
            report = self.p.execution_history(protocol_ref=protocol)
        self.assertEqual([row['receipt_ref'] for row in report['entries']], [second['receipt_ref'], first['receipt_ref']])
        self.assertEqual(report['relations'], [{'left': 1, 'right': 2, 'relation': 'before'}])
        self.assertEqual([s['step_id'] for s in report['selector']['steps']], ['b-first', 'a-second'])
        self.assertEqual(report['selector']['order_evidence'], 'declared_intent_not_approval')
        self.assertEqual(report['entries'][0]['registration_at_utc'], self.p._record(second['receipt_ref'])['created_at'])
        self.assertEqual(report['entries'][0]['run_ref'], second['run_ref'])
        self.assertIn('not_execution_or_dependency_or_protocol_order', report['presentation_order'])
        self.assertEqual(before, self.p.state)

    def test_all_partial_order_relations_and_native_timestamp_parity(self):
        older, newer = self.run_record(), self.run_record()
        fixtures = [
            ('00:00:00', '00:00:01', '00:00:02', '00:00:03', 'before'),
            ('00:00:04', '00:00:05', '00:00:02', '00:00:03', 'after'),
            ('00:00:01', '00:00:04', '00:00:02', '00:00:05', 'overlap'),
            ('00:00:01', '00:00:02', '00:00:01', '00:00:02', 'tied'),
            ('00:00:01', '00:00:02', '00:00:02', '00:00:03', 'tied_boundary'),
            ('00:00:01', '00:00:01', '00:00:01', '00:00:01', 'tied'),
            ('00:00:04', '00:00:01', '00:00:02', '00:00:03', 'unknown'),
        ]
        for a, b, c, d, expected in fixtures:
            self.interval(newer, '2020-01-01T' + a + 'Z', '2020-01-01T' + b + 'Z')
            self.interval(older, '2020-01-01T' + c + 'Z', '2020-01-01T' + d + 'Z')
            self.assertEqual(self.p.execution_history()['relations'][0]['relation'], expected)
            self.persist_fixture()
            self.assertEqual(self.native()['report'], self.p.execution_history())
        for invalid in ('2020-1-01T00:00:00Z', '2020-02-30T00:00:00Z', '2020-01-01T00:00:00Zjunk'):
            self.interval(newer, invalid, '2020-01-01T00:00:01Z')
            report = self.p.execution_history()
            self.assertEqual(report['entries'][0]['timing_status'], 'invalid')
            self.assertEqual(report['entries'][0]['started_at_utc'], invalid)
            self.assertEqual(report['relations'][0]['relation'], 'unknown')
            self.persist_fixture()
            self.assertEqual(self.native()['report'], self.p.execution_history())

    def test_failed_incomplete_blocked_and_open_are_not_success(self):
        failed = self.run_record(self.template(fail=True))
        incomplete = self.run_record(self.template(skip=True))
        self.interval(failed, '2020-01-01T00:00:00Z', '2020-01-01T00:00:01Z')
        self.interval(incomplete, '2020-01-01T00:00:02Z', '2020-01-01T00:00:03Z')
        report = self.p.execution_history()
        self.assertEqual([x['outcome'] for x in report['entries']], ['incomplete', 'failed'])
        self.assertEqual(report['relations'][0]['relation'], 'after')
        (self.root / 'input.txt').write_text('changed bytes')
        blocked = self.run_record()
        row = self.p.execution_history()['entries'][0]
        self.assertEqual(row['outcome'], 'blocked')
        self.assertEqual(row['timing_status'], 'not_executed')
        self.assertEqual(self.p.execution_history()['relations'][0]['relation'], 'unknown')
        (self.root / 'input.txt').write_text('synthetic')
        real_save, calls = self.p.save_and_confirm, [0]
        def fail_terminal_save():
            calls[0] += 1
            if calls[0] == 2: raise OSError('synthetic terminal persistence failure')
            return real_save()
        with patch.object(self.p, 'save_and_confirm', side_effect=fail_terminal_save):
            with self.assertRaises(OSError): self.run_record()
        self.p = ProjectBundle.open(self.root)
        row = self.p.execution_history()['entries'][0]
        self.assertEqual((row['outcome'], row['timing_status']), ('started', 'open'))
        self.assertIsNone(row['ended_at_utc'])
        self.assertEqual(self.native()['report'], self.p.execution_history())

    def test_exact_filters_no_match_and_single_run_latest_revision(self):
        first = self.run_record()
        other = self.template(n=2)
        second = self.run_record(other)
        protocol = self.p.register_protocol('intent', [{'step_id': 'exact', 'analysis_ref': self.a, 'required_outputs': []}], 'synthetic')
        for selector in ({'analysis_ref': self.a}, {'analysis_ref': first['run_ref']},
                         {'analysis_ref': first['receipt_ref']}, {'protocol_ref': protocol}):
            report = self.p.execution_history(**selector)
            self.assertEqual([e['receipt_ref'] for e in report['entries']], [first['receipt_ref']])
        unexecuted = self.template(n=99)
        self.assertEqual(self.p.execution_history(analysis_ref=unexecuted)['entries'], [])
        self.assertIn('not_complete', self.p.execution_history()['evidence_scope'])
        with self.assertRaises(BundleError): self.p.execution_history(analysis_ref=self.a, protocol_ref=protocol)
        for options in ({'limit': True}, {'limit': 0}, {'limit': 21}, {'offset': -1}, {'offset': True}, {'offset': 2**31}):
            with self.assertRaises(BundleError): self.p.execution_history(**options)

    def test_page_limits_never_lose_or_duplicate_runs(self):
        receipts = [self.run_record() for _ in range(4)]
        offset, seen = 0, []
        while offset is not None:
            report = self.p.execution_history(limit=1, offset=offset)
            self.assertLessEqual(report['scan']['scanned'], 1000)
            seen.extend(e['receipt_ref'] for e in report['entries'])
            next_offset = report['scan']['next_offset']
            self.assertTrue(next_offset is None or next_offset > offset)
            offset = next_offset
        self.assertEqual(seen, [r['receipt_ref'] for r in reversed(receipts)])
        for _ in range(1005): self.p.register_analysis('ordinary declaration', [], method='synthetic', params={})
        first = self.p.execution_history()
        self.assertEqual(first['entries'], [])
        self.assertEqual(first['scan']['scanned'], 1000)
        self.assertEqual(first['scan']['stop_reason'], 'scan_limit')
        second = self.p.execution_history(offset=first['scan']['next_offset'])
        self.assertEqual([e['receipt_ref'] for e in second['entries']], seen)
        self.assertEqual(self.p.execution_history(offset=999999)['entries'], [])
        self.p.save_and_confirm()
        self.assertEqual(self.native(options={'offset': 1000})['report'], second | {'unsaved': False, 'registry_revision': self.p.state['state_revision']})

    def test_imported_and_malformed_claims_cannot_establish_relations(self):
        one, two = self.run_record(), self.run_record()
        self.interval(one, '2020-01-01T00:00:00Z', '2020-01-01T00:00:01Z')
        self.interval(two, '2020-01-01T00:00:02Z', '2020-01-01T00:00:03Z')
        self.persist_fixture()
        archive = self.root / 'context.zip'
        self.p.export_zip(self.p.preview_export('context'), archive)
        imported = ProjectBundle.import_zip(archive, self.root / 'imported')
        report = imported.execution_history()
        self.assertEqual(report['relations'][0]['relation'], 'unknown')
        self.assertEqual([e['evidence'] for e in report['entries']], ['untrusted_imported'] * 2)
        self.assertEqual(report['entries'][0]['started_at_utc'], '2020-01-01T00:00:02Z')
        self.p._record(two['receipt_ref'])['details']['execution_receipt']['version'] = 'future'
        report = self.p.execution_history(analysis_ref=self.a)
        self.assertEqual(report['entries'][0]['evidence'], 'unknown')
        self.assertEqual(report['relations'][0]['relation'], 'unknown')
        self.persist_fixture()
        self.assertEqual(self.native(options={'analysis_ref': self.a})['report'], self.p.execution_history(analysis_ref=self.a))

    def test_metadata_and_report_bounds_preserve_cursor_and_exact_values(self):
        one, two = self.run_record(), self.run_record()
        long_time = 'λ' * 18000
        self.interval(one, long_time, '2020-01-01T00:00:01Z')
        self.interval(two, long_time, '2020-01-01T00:00:02Z')
        first = self.p.execution_history()
        self.assertEqual(len(first['entries']), 1)
        self.assertEqual(first['scan']['stop_reason'], 'report_limit')
        self.assertEqual(first['entries'][0]['started_at_utc'], long_time)
        second = self.p.execution_history(offset=first['scan']['next_offset'])
        self.assertEqual(second['entries'][0]['receipt_ref'], one['receipt_ref'])
        self.assertTrue(all(r['right'] <= len(first['entries']) for r in first['relations']))
        text = self.p.execution_history_summary()
        self.assertLessEqual(len(text.encode('utf-8')), 4096)
        self.assertIn('Summary omitted 1 entries', text)
        self.assertNotIn('λ', text)
        self.persist_fixture()
        native = self.native()
        self.assertEqual(native['report'], self.p.execution_history())
        self.assertEqual(native['summary'], text)
        self.p._record(two['receipt_ref'])['details']['padding'] = 'x' * 65536
        real_get = self.p.get_execution
        def bounded(ref):
            self.assertNotEqual(ref, two['receipt_ref'])
            return real_get(ref)
        with patch.object(self.p, 'get_execution', side_effect=bounded):
            self.assertEqual(self.p.execution_history()['entries'][0]['reason'], 'metadata_limit')
        protocol = self.p.register_protocol('large intent', [{'step_id': 'λ'*25000, 'analysis_ref': self.a, 'required_outputs': []}], 'synthetic')
        report = self.p.execution_history(protocol_ref=protocol)
        self.assertEqual(report['selector']['omitted_steps'], 1)
        self.assertEqual(report['selector']['steps'], [])
        self.assertLessEqual(len(json.dumps(report, ensure_ascii=False).encode()), 65536)

    def test_expanded_budget_stops_without_losing_candidate(self):
        receipts = [self.run_record() for _ in range(18)]
        for receipt in receipts: self.p._record(receipt['receipt_ref'])['details']['padding'] = 'x' * 60000
        report = self.p.execution_history(limit=20)
        self.assertEqual(report['scan']['stop_reason'], 'metadata_budget')
        following = self.p.execution_history(limit=20, offset=report['scan']['next_offset'])
        refs = [e['receipt_ref'] for e in report['entries'] + following['entries']]
        self.assertEqual(refs, [r['receipt_ref'] for r in reversed(receipts)])

    def test_queries_and_summaries_are_read_only_and_native_runs_roundtrip(self):
        receipt = self.run_record()
        path = self.root / '.nb_project_bundle/project.json'
        before, state = path.read_bytes(), copy.deepcopy(self.p.state)
        with patch.object(Path, 'open', side_effect=AssertionError('payload I/O')),\
             patch('os.scandir', side_effect=AssertionError('directory scan')),\
             patch('biodataledger.core.fingerprint', side_effect=AssertionError('hash')),\
             patch.object(self.p, 'save', side_effect=AssertionError('save')):
            report = self.p.execution_history()
            summary = self.p.execution_history_summary()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(self.p.state, state)
        self.assertIn('start=' + receipt['started_at_utc'], summary)
        self.assertIn('not a total execution', summary)
        native = self.native()
        self.assertEqual(native['report'], report)
        self.assertEqual(native['summary'], summary)
        new = self.native(mode='native_run')
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.execution_history(analysis_ref=new['analysis_ref']), new['native_report'])
        self.assertEqual(reopened.execution_history_summary(analysis_ref=new['analysis_ref']), new['native_summary'])


if __name__ == '__main__':
    unittest.main()
