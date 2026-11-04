from pathlib import Path
import copy
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


class ExecutionContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "input.csv").write_text("value\n1\n")
        (self.root / "run.py").write_text(
            "from pathlib import Path\n"
            "def make(inputs, params, seeds, outputs):\n"
            "    Path(outputs[0]).write_text('x,y\\n1,2\\n')\n"
            "    Path(outputs[1]).write_text('<svg/>')\n"
        )
        self.project = ProjectBundle.create("Execution fixture", self.root)
        self.data = self.project.register_data("input.csv", "input", hash=True)
        self.analysis = self.project.register_analysis("Synthetic callback", [self.data], code="run.py",
                                                       method="fixture", params={"limit": 1})

    def test_execution_api_is_available(self):
        self.assertTrue(hasattr(ProjectBundle, "run_analysis"))

    def test_success_is_started_then_terminal_with_exact_producers(self):
        receipt = self.project.run_analysis(
            self.analysis, "make",
            [{"path": str(self.root / "result.csv"), "kind": "result"},
             {"path": str(self.root / "plot.svg"), "kind": "figure", "type": "plot"}],
            seeds={"random": 4},
        )
        self.assertEqual(receipt["status"], "succeeded")
        self.assertEqual(receipt["run_ref"]["revision"], 1)
        self.assertEqual(receipt["receipt_ref"]["revision"], 2)
        self.assertEqual(receipt["phases"], {"execution_started": True, "code_executed": True, "callback_invoked": True})
        self.assertEqual([item["status"] for item in receipt["outputs"]], ["registered", "registered"])
        self.assertTrue(all(item["record_ref"] for item in receipt["outputs"]))
        self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["status"], "succeeded")
        self.assertEqual(self.project.get_analysis(receipt["run_ref"]).details["execution_receipt"]["status"], "started")
        self.assertIn("ANA-002@2: succeeded; entry point make; inputs matched 1/1", self.project.execution_summary(receipt["receipt_ref"]))

    def test_changed_input_blocks_without_callback(self):
        (self.root / "input.csv").write_text("value\nchanged\n")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(self.analysis, "make", [])
        receipt = raised.exception.receipt
        self.assertEqual(receipt["status"], "blocked")
        self.assertFalse(any(receipt["phases"].values()))
        self.assertEqual(receipt["inputs"][0]["identity"], "mismatch")

    def test_callback_failure_registers_partial_output(self):
        (self.root / "run.py").write_text(
            "from pathlib import Path\n"
            "def fail(inputs, params, seeds, outputs):\n"
            "    Path(outputs[0]).write_text('partial')\n"
            "    raise RuntimeError('synthetic stop')\n"
        )
        # The stored snapshot, not this replacement source, is what executes.
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(self.analysis, "make", [{"path": str(self.root / "partial.csv"), "kind": "result"}], verify_code=False)
        self.assertEqual(raised.exception.receipt["status"], "failed")

    def test_changed_code_blocks_but_explicit_snapshot_run_uses_original_bytes(self):
        (self.root / "run.py").write_text("raise RuntimeError('replacement must not run')\n")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(self.analysis, "make", [])
        self.assertEqual(raised.exception.receipt["status"], "blocked")
        self.assertFalse(any(raised.exception.receipt["phases"].values()))
        receipt = self.project.run_analysis(self.analysis, "make", [
            {"path": "snapshot.csv", "kind": "result"},
            {"path": "snapshot.svg", "kind": "figure", "type": "plot"}], verify_code=False)
        self.assertEqual(receipt["status"], "succeeded")
        self.assertEqual((self.root / "snapshot.csv").read_text(), "x,y\n1,2\n")

    def test_missing_output_is_incomplete_and_input_use_stays_unknown(self):
        (self.root / "ignore.py").write_text("def ignore(inputs, params, seeds, outputs):\n    pass\n")
        analysis = self.project.register_analysis("Ignores supplied arguments", [self.data], code="ignore.py")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(analysis, "ignore", [{"path": "absent.csv", "kind": "result"}])
        receipt = raised.exception.receipt
        self.assertEqual(receipt["status"], "incomplete")
        self.assertEqual(receipt["outputs"][0]["status"], "missing")
        self.assertEqual(receipt["inputs"][0]["identity"], "match")
        self.assertEqual(receipt["input_consumption"], "unknown")
        self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["status"], "incomplete")

    def test_ordinary_metadata_updates_cannot_inject_receipts(self):
        with self.assertRaises(BundleError):
            self.project.update_record(self.analysis, {"details": {"execution_receipt": {}}}, "inject")

    def test_run_context_cannot_be_revised_by_general_update(self):
        receipt = self.project.run_analysis(self.analysis, "make", [
            {"path": "protected.csv", "kind": "result"},
            {"path": "protected.svg", "kind": "figure", "type": "plot"}])
        with self.assertRaises(BundleError):
            self.project.update_record(receipt["receipt_ref"], {"params": {"limit": 2}}, "rewrite execution")
        self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["params"], {"limit": 1})

    def test_relative_outputs_normalize_to_project_paths(self):
        receipt = self.project.run_analysis(
            self.analysis, "make",
            [{"path": "relative-result.csv", "kind": "result"},
             {"path": "relative-plot.svg", "kind": "figure", "type": "plot"}],
        )
        self.assertEqual(receipt["outputs"][0]["path"], str(self.project.root / "relative-result.csv"))

    def test_malformed_or_future_receipt_is_unknown(self):
        self.project._record(self.analysis)["details"]["execution_receipt"] = {"version": "future/99"}
        receipt = self.project.get_execution(self.analysis)
        self.assertEqual(receipt["status"], "unknown")

    def test_contradictory_or_malformed_receipts_are_unknown(self):
        receipt = self.project.run_analysis(self.analysis, "make", [
            {"path": "checked.csv", "kind": "result"},
            {"path": "checked.svg", "kind": "figure", "type": "plot"}])
        record = self.project._record(receipt["receipt_ref"])
        original = copy.deepcopy(record["details"]["execution_receipt"])
        mutations = [
            lambda r: r["phases"].update(callback_invoked=False),
            lambda r: r["outputs"][0].update(status="missing"),
            lambda r: r["outputs"][0].pop("record_ref"),
            lambda r: r["outputs"][0].update(digest="0" * 64),
            lambda r: r["code"].update(digest="0" * 64),
            lambda r: r["inputs"][0].update(ref=receipt["run_ref"]),
            lambda r: r.update(status={"invented": "succeeded"}),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                value = copy.deepcopy(original); mutate(value)
                record["details"]["execution_receipt"] = value
                self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["status"], "unknown")
        record["details"]["execution_receipt"] = original

    def test_uri_output_rejects_before_execution(self):
        with self.assertRaises(BundleError):
            self.project.run_analysis(self.analysis, "make", [{"path": "file:output.csv", "kind": "result"}])
        self.assertFalse((self.root / "file:output.csv").exists())

    def test_receipt_queries_and_clean_save_do_not_read_or_write_payloads(self):
        receipt = self.project.run_analysis(self.analysis, "make", [
            {"path": "readonly.csv", "kind": "result"},
            {"path": "readonly.svg", "kind": "figure", "type": "plot"}])
        with patch.object(Path, "open", side_effect=AssertionError("unexpected file I/O")), \
                patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected hash")), \
                patch("biodataledger.execution.fingerprint", side_effect=AssertionError("unexpected hash")):
            self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["status"], "succeeded")
            self.assertIn("input use/science: unknown", self.project.execution_summary(receipt["receipt_ref"]))
            self.assertEqual(self.project.save_and_confirm()["status"], "no_changes")

    def test_legacy_template_keeps_original_optional_context(self):
        from biodataledger.core import canonical, STATE_PATH
        self.project.save_and_confirm()
        raw = copy.deepcopy(self.project.state)
        raw["schema_version"] = "0.1.0"
        for record in raw["records"]:
            record.pop("design", None); record.pop("input_mode", None)
        (self.root / STATE_PATH).write_bytes(canonical(raw))
        p = ProjectBundle.open(self.root)
        receipt = p.run_analysis(self.analysis, "make", [
            {"path": "legacy.csv", "kind": "result"},
            {"path": "legacy.svg", "kind": "figure", "type": "plot"}])
        self.assertEqual(p.get_execution(receipt["receipt_ref"])["status"], "succeeded")
        self.assertNotIn("design", p._record(receipt["run_ref"]))
        self.assertNotIn("input_mode", p._record(receipt["run_ref"]))

    def test_compile_failure_is_a_readable_terminal_receipt(self):
        (self.root / "bad.py").write_text("def broken(:\n")
        analysis = self.project.register_analysis("Broken source", [self.data], code="bad.py")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(analysis, "broken", [])
        receipt = raised.exception.receipt
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["phases"]["execution_started"])
        self.assertFalse(receipt["phases"]["code_executed"])
        self.assertEqual(self.project.get_execution(receipt["receipt_ref"])["status"], "failed")

    def test_top_level_failure_captures_observed_partial_output(self):
        output = self.root / "top-level.csv"
        (self.root / "top.py").write_text(
            "from pathlib import Path\n"
            "Path(" + repr(str(output)) + ").write_text('partial')\n"
            "raise RuntimeError('top level stop')\n"
        )
        analysis = self.project.register_analysis("Top-level failure", [self.data], code="top.py")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(analysis, "not_reached", [{"path": str(output), "kind": "result"}])
        receipt = raised.exception.receipt
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse(receipt["phases"]["callback_invoked"])
        self.assertEqual(receipt["outputs"][0]["status"], "registered")

    def test_callback_raised_execution_error_is_still_terminalized(self):
        (self.root / "raised.py").write_text(
            "from biodataledger.execution import ExecutionError\n"
            "def user_error(inputs, params, seeds, outputs):\n"
            "    raise ExecutionError('user callback error', {})\n"
        )
        analysis = self.project.register_analysis("User error", [self.data], code="raised.py")
        with self.assertRaises(BundleError) as raised:
            self.project.run_analysis(analysis, "user_error", [])
        self.assertEqual(raised.exception.receipt["status"], "failed")
        self.assertTrue(raised.exception.receipt["phases"]["callback_invoked"])

    def test_failed_start_save_does_not_invoke_callback(self):
        output = self.root / "not-created.csv"
        with patch("biodataledger.core.os.replace", side_effect=OSError("synthetic start failure")):
            with self.assertRaises(OSError):
                self.project.run_analysis(self.analysis, "make", [{"path": str(output), "kind": "result"}])
        self.assertFalse(output.exists())

    def test_failed_terminal_save_leaves_durable_started_receipt(self):
        output = self.root / "persist-failure.csv"
        original = os.replace
        calls = []
        def fail_second(*args):
            calls.append(args)
            if len(calls) == 2:
                raise OSError("synthetic terminal failure")
            return original(*args)
        with patch("biodataledger.core.os.replace", side_effect=fail_second):
            with self.assertRaises(OSError):
                self.project.run_analysis(self.analysis, "make", [{"path": str(output), "kind": "result"}])
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_execution("ANA-002@1")["status"], "started")
        self.assertTrue(output.exists())

    def test_hard_exit_retains_started_receipt(self):
        (self.root / "run.py").write_text(
            "import os\n"
            "def die(inputs, params, seeds, outputs):\n"
            "    os._exit(23)\n"
        )
        # Create the captured exit source in a separate persisted analysis.
        exit_analysis = self.project.register_analysis("Hard exit", [self.data], code="run.py")
        self.project.save_and_confirm()
        command = (
            "from biodataledger import ProjectBundle; import sys; "
            "ProjectBundle.open(sys.argv[1]).run_analysis('ANA-002@1', 'die', [])"
        )
        result = subprocess.run([sys.executable, "-c", command, str(self.root)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 23, result.stderr)
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_execution("ANA-003@1")["status"], "started")


if __name__ == "__main__":
    unittest.main()
