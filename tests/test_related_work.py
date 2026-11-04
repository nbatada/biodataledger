"""Five installed-client checks for bounded recorded related-work lookup."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle
from biodataledger.core import canonical


class RelatedWorkTests(unittest.TestCase):
    maxDiff = None
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "input.csv").write_text("sample,value\nA,1\n")
        (self.root / "other.csv").write_text("sample,value\nB,2\n")
        (self.root / "result.csv").write_text("sample,value\nA,3\n")
        (self.root / "plot.svg").write_text("<svg/>")
        self.p = ProjectBundle.create("related synthetic", self.root)
        self.data = self.p.register_data("input.csv", "input")
        self.other = self.p.register_data("other.csv", "input")

    def r_report(self, route, selector, limit=5):
        result = subprocess.run(["Rscript", "--vanilla", str(Path(__file__).with_name("r_related_work_exchange.R")),
                                 str(self.root), route, selector, str(limit)], capture_output=True, text=True,
                                env=os.environ, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def parity(self, route, selector, limit=5):
        report = self.p.related_work(input_ref=selector, limit=limit) if route == "input" else self.p.related_work(query=selector, limit=limit)
        self.assertEqual(report, self.r_report(route, selector if isinstance(selector, str) else selector["id"] + "@" + str(selector["revision"]), limit))
        self.assertLessEqual(len(canonical(report)), 4096)
        return report

    def test_exact_historical_input_keeps_declared_links(self):
        analysis = self.p.register_analysis("Historical clonality", [self.data])
        result = self.p.register_result("result.csv", analysis)
        figure = self.p.register_figure("plot.svg", "plot", analysis=analysis,
                                        figure_sources={"rendering_inputs": [result], "relationship": "declared"})
        revised = self.p.set_data_scope(self.data, {}, "synthetic revision")
        self.p.save_and_confirm()
        report = self.parity("input", self.data)
        self.assertEqual(report["analyses"][0]["ref"], analysis)
        self.assertEqual(report["analyses"][0]["inputs"], [self.data])
        self.assertIn(result, report["analyses"][0]["results"])
        self.assertIn(figure, report["analyses"][0]["figures"])
        self.assertNotEqual(revised, self.data)
        native_pending = self.r_report("numeric_guard", self.data["id"] + "@1", 20)
        self.assertTrue(native_pending["unsaved"])

    def test_topic_candidates_are_literal_and_ambiguous(self):
        first = self.p.register_analysis("TCR readout", [self.data], purpose="clonality comparison", tags=["TCR", "repertoire"])
        second = self.p.register_analysis("Other readout", [self.other], description="TCR clonality is recorded", tags="synthetic")
        object_tags = self.p.register_analysis("Object tags", [self.data], tags={"topic": "hidden-topic"})
        self.p.register_analysis("Extra tags", [self.data], tags=["ordinary"] * 32 + ["hidden-topic"])
        self.p.save_and_confirm()
        report = self.parity("query", "TCR\u00a0clonality")
        self.assertEqual([item["ref"] for item in report["analyses"]], [first, second])
        self.assertTrue(report["state"]["multiple"])
        self.assertTrue(all(item["match_basis"] == "text_candidate" for item in report["analyses"]))
        self.assertTrue(all(item["provenance"]["equivalence"] == "unknown" for item in report["analyses"]))
        tag_only = self.parity("query", "repertoire")
        self.assertEqual(tag_only["analyses"][0]["matched_fields"], ["tags"])
        hidden = self.parity("query", "hidden-topic")
        self.assertIsNone(hidden["state"]["no_match"])
        self.assertTrue(hidden["truncation"]["metadata"])
        self.assertNotIn(object_tags, [item["ref"] for item in hidden["analyses"]])

    def test_missing_and_invalid_selectors_do_not_invent_evidence(self):
        analysis = self.p.register_analysis("Declared but not executed", [self.data])
        unknown_inputs = self.p.register_analysis("Inputless legacy topic", None, tags=["inputless"])
        (self.root / "runner.py").write_text("def make(inputs, params, seeds, outputs):\n    with open(outputs[0], 'w') as stream: stream.write('synthetic')\n")
        template = self.p.register_analysis("Receipt topic", [self.data], code="runner.py", tags=["receipt"])
        receipt = self.p.run_analysis(template, "make", [{"path": "run-result.csv", "kind": "result"}], verify_inputs=False)
        (self.root / "failed.py").write_text("def stop(inputs, params, seeds, outputs):\n    raise RuntimeError('synthetic failure')\n")
        failing = self.p.register_analysis("Failed receipt topic", [self.data], code="failed.py", tags=["failed-receipt"])
        with self.assertRaises(BundleError) as raised:
            self.p.run_analysis(failing, "stop", verify_inputs=False)
        failed_receipt = raised.exception.receipt
        self.p.save_and_confirm()
        report = self.parity("query", "absent topic")
        self.assertTrue(report["state"]["no_match"])
        legacy = self.parity("query", "inputless")
        self.assertIsNone(legacy["analyses"][0]["inputs"])
        self.assertIsNone(legacy["analyses"][0]["omitted"]["inputs"])
        self.assertEqual(legacy["analyses"][0]["provenance"]["relationships"], "unknown")
        executed = self.parity("query", "receipt")
        entry = next(item for item in executed["analyses"] if item["ref"] == receipt["receipt_ref"])
        self.assertEqual(entry["artifact_analysis_ref"], receipt["run_ref"])
        self.assertEqual(entry["provenance"]["execution_status"], "succeeded")
        self.assertEqual(entry["results"], [receipt["outputs"][0]["record_ref"]])
        failed = self.parity("query", "failed-receipt")
        self.assertEqual(next(item for item in failed["analyses"] if item["ref"] == failed_receipt["receipt_ref"])["provenance"]["execution_status"], "failed")
        exact = self.parity("input", self.data)
        self.assertEqual(next(item for item in exact["analyses"] if item["ref"] == analysis)["provenance"]["execution_status"], "unknown")
        for kwargs in ({}, {"input_ref": self.data, "query": "x"}, {"input_ref": "DATA-999@1"}, {"query": " "}):
            with self.assertRaises(BundleError): self.p.related_work(**kwargs)

    def test_bounds_preserve_whole_identifiers_and_qualify_incomplete_search(self):
        analysis = self.p.register_analysis("€" * 200, [self.data], description="x" * 4096 + " TCR", tags=["€" * 100])
        for _ in range(12):
            self.p.register_result("result.csv", analysis)
        self.p.save_and_confirm()
        clipped = self.parity("input", self.data)
        self.assertTrue(clipped["state"]["incomplete"])
        self.assertTrue(clipped["truncation"]["details"])
        for index in range(101):
            self.p.register_analysis("direct " + str(index), [self.data])
        for index in range(1001):
            self.p.register_analysis("filler " + str(index), [self.other])
        self.p.save_and_confirm()
        report = self.parity("input", self.data)
        item = report["analyses"][0]
        self.assertEqual(item["omitted"]["results"], 2)
        self.assertTrue(item["omitted"]["title"])
        self.assertEqual(report["counts"]["inspected_edges"], 100)
        self.assertTrue(report["truncation"]["search"])
        uncertain = self.parity("query", "TCR")
        self.assertIsNone(uncertain["state"]["no_match"])
        self.assertTrue(uncertain["truncation"]["metadata"])
        late = self.parity("query", "not-present")
        self.assertIsNone(late["state"]["no_match"])
        self.assertTrue(late["truncation"]["search"])

    def test_read_only_and_saved_registry_exchange(self):
        self.p.register_analysis("TCR saved work", [self.data], tags=["TCR"])
        self.p.save_and_confirm()
        before = canonical(self.p.state)
        with patch.object(Path, "open", side_effect=AssertionError("unexpected payload I/O")):
            report = self.p.related_work(query="TCR")
        self.assertEqual(canonical(self.p.state), before)
        self.assertFalse(self.p.unsaved)
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.related_work(query="TCR"), report)
        self.p = reopened
        self.assertEqual(report, self.r_report("query", "TCR"))
        archive = self.root / "context.zip"
        self.p.export_zip(self.p.preview_export("context"), archive)
        imported = ProjectBundle.import_zip(archive, self.root / "python-import")
        self.assertEqual(imported.related_work(query="TCR")["coverage"]["imported_claims"], "untrusted")
        result = subprocess.run(["Rscript", "--vanilla", str(Path(__file__).with_name("r_related_work_exchange.R")),
                                 "import", str(archive), str(self.root / "r-import"), "query", "TCR", "5"],
                                capture_output=True, text=True, env=os.environ, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["coverage"]["imported_claims"], "untrusted")
        legacy = self.root / "legacy"
        (legacy / ".nb_project_bundle").mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("fixtures") / "minimal.json", legacy / ".nb_project_bundle" / "project.json")
        self.assertTrue(ProjectBundle.open(legacy).related_work(query="TCR")["state"]["no_match"])
        legacy_r = subprocess.run(["Rscript", "--vanilla", str(Path(__file__).with_name("r_related_work_exchange.R")),
                                   str(legacy), "query", "TCR", "5"], capture_output=True, text=True, env=os.environ, timeout=30)
        self.assertEqual(legacy_r.returncode, 0, legacy_r.stdout + legacy_r.stderr)
        self.assertTrue(json.loads(legacy_r.stdout)["state"]["no_match"])


if __name__ == "__main__":
    unittest.main()
