"""Installed-client contract checks for the bounded analyses timeline."""
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
    for path in outputs: Path(path).write_text('synthetic')
"""


class AnalysisFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "input.txt").write_text("input")
        (self.root / "code.py").write_text(CODE)
        self.p = ProjectBundle.create("flow", self.root)
        self.data = self.p.register_data("input.txt", "input", hash=True)
        self.a = self.p.register_analysis("A1", [self.data], code="code.py", method="test", params={})
        self.n = 0

    def execute(self, ref=None, outputs=1):
        self.n += 1
        spec = [{"path": f"out-{self.n}-{i}.txt", "kind": "result"} for i in range(outputs)]
        try: return self.p.run_analysis(ref or self.a, "run", spec)
        except ExecutionError as error: return error.receipt

    def persist(self):
        self.p.set_context({"next_task": "fixture"}); self.p.save_and_confirm()

    def native(self):
        request = self.root / "request.json"; request.write_text(json.dumps({"mode": "timeline", "options": {"view": "analyses", "limit": 1}}))
        env = dict(os.environ)
        if env.get("BDL_R_LIB"):
            env["R_LIBS_USER"] = os.pathsep.join(filter(None, (env["BDL_R_LIB"], env.get("R_LIBS_USER"))))
        completed = subprocess.run(["Rscript", "--vanilla", str(Path(__file__).with_name("r_chronology_exchange.R")), str(self.root), str(request)],
                                   capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        return json.loads(completed.stdout)

    def assert_native_rows(self):
        self.assertEqual([row for page in self.native()["pages"] for row in page["rows"]], self.rows())

    def rows(self):
        cursor, rows = None, []
        while True:
            page = self.p.timeline(view="analyses", limit=20, cursor=cursor)
            rows += page["rows"]; cursor = page["next_cursor"]
            if cursor is None: return rows

    def test_receipt_claims_and_invalid_ordinary_dates_are_unknown_last(self):
        terminal = self.execute()
        self.p._record(terminal["receipt_ref"])["details"]["execution_receipt"] = None
        bad = self.p.register_analysis("bad date", [], method="test", params={})
        self.p._record(bad)["created_at"] = "2026-02-30T00:00:00Z"
        self.persist()
        rows = self.rows()
        self.assertEqual(rows[-2]["time_source"], "unqualified")
        self.assertEqual(rows[-2]["time_utc"], None)
        self.assertEqual(rows[-1]["time_utc"], None)
        self.assert_native_rows()

    def test_exact_output_flow_survives_later_result_revision_and_branch_merge(self):
        receipt = self.execute(outputs=2)
        first, second = [item["record_ref"] for item in receipt["outputs"]]
        revised = self.p.update_record(first, {"name": "later revision"}, "fixture")
        left = self.p.register_analysis("left", [first], method="test", params={})
        right = self.p.register_analysis("right", [first, second], method="test", params={})
        self.persist()
        row = next(row for row in self.rows() if row["ref"] == receipt["receipt_ref"])
        self.assertEqual(row["output_refs"], [first, second])
        self.assertNotIn(revised, row["output_refs"])
        mapping = {item["output_ref"]["id"]: item["analysis_refs"] for item in row["output_consumers"]}
        self.assertEqual(mapping[first["id"]], [left, right])
        self.assertEqual(mapping[second["id"]], [right])
        self.assert_native_rows()

    def test_bounds_cursor_and_no_payload_io(self):
        inputs = [self.p.register_data("input.txt", f"input-{i}", hash=True) for i in range(12)]
        wide = self.p.register_analysis("wide", inputs, method="test", params={})
        receipt = self.execute(outputs=12)
        outputs = [item["record_ref"] for item in receipt["outputs"]]
        for i in range(12): self.p.register_analysis(f"consumer-{i}", [outputs[0]], method="test", params={})
        self.persist(); before = (self.root / ".nb_project_bundle/project.json").read_bytes()
        with patch.object(Path, "open", side_effect=AssertionError("payload I/O")), \
             patch('os.scandir', side_effect=AssertionError('directory scan')), \
             patch('biodataledger.core.fingerprint', side_effect=AssertionError('hash')), \
             patch.object(self.p, "save", side_effect=AssertionError("save")):
            page = self.p.timeline(view="analyses", limit=1)
            text = self.p.timeline_summary(view="analyses")
            repr(self.p)
        self.assertIn('+2 inputs omitted', text)
        self.assertIn('+2 outputs omitted', text)
        self.assertIn('consumers omitted', text)
        self.assert_native_rows()
        self.assertLessEqual(len(page["rows"][0]["input_refs"]), 10)
        self.assertEqual(before, (self.root / ".nb_project_bundle/project.json").read_bytes())
        cursor = page["next_cursor"]; self.p.update_record(wide, {"name": "edited"}, "fixture")
        with self.assertRaisesRegex(BundleError, "cursor"): self.p.timeline(view="analyses", cursor=cursor)

    def test_figure_receipts_are_not_produced_data(self):
        self.n += 1
        try:
            receipt = self.p.run_analysis(self.a, "run", [{"path": "plot.svg", "kind": "figure", "type": "svg"}])
        except ExecutionError as error: receipt = error.receipt
        self.persist()
        text = self.p.timeline_summary(view="analyses")
        figure = receipt["outputs"][0]["record_ref"]
        self.assertIn(figure["id"] + "@" + str(figure["revision"]), text)
        self.assertIn("Receipt figure " + figure['id'], text)
        self.assertNotIn('-> ' + figure['id'], text)
        row = next(row for row in self.rows() if row['ref'] == receipt['receipt_ref'])
        self.assertEqual(row['output_consumers'], [])
        self.assert_native_rows()

    def test_artifact_labels_dates_and_console_controls_are_bounded(self):
        changed = self.p.update_record(self.data, {'name': 'Cells\n\x1b[31m\u202e' + 'λ' * 5000}, 'fixture')
        self.p._record(changed)['created_at'] = 'bad\n\x1b[0m'
        a = self.p.register_analysis('Inspect\n\x1b[31m\u202e cells', [changed], method='test', params={})
        self.persist()
        row = next(row for row in self.rows() if row['ref'] == a)
        item = row['input_items'][0]
        self.assertTrue(item['name_clipped'])
        self.assertLessEqual(len(item['name'].encode()), 192)
        self.assertIsNone(item['registration_at_utc'])
        text = self.p.timeline_summary(view='analyses')
        self.assertNotIn('\x1b', text)
        self.assertNotIn('\u202e', text)
        self.assertNotIn('Cells\n', text)
        self.assertIn('[Registered UNKNOWN]', text)
        self.assertLess(len(text.encode()), 4096)
        self.assert_native_rows()

    def test_high_fanout_is_marked_without_unbounded_consumer_rows(self):
        receipt = self.execute()
        output = receipt["outputs"][0]["record_ref"]
        for index in range(1005):
            self.p.register_analysis(f"consumer-{index}", [output], method="test", params={})
        self.persist()
        row = next(row for row in self.rows() if row["ref"] == receipt["receipt_ref"])
        self.assertLessEqual(len(row["downstream_analysis_refs"]), 10)
        self.assertTrue(row["downstream_scan_truncated"])
        self.assertIn("truncated", self.p.timeline_summary(view="analyses"))
        # Native parity must preserve the same capped neighborhood at large fanout.
        native = self.native()['pages']
        native_row = next(row for page in native for row in page['rows'] if row['ref'] == receipt['receipt_ref'])
        self.assertEqual(native_row, row)
