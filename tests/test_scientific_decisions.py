"""Five focused F14 runtime cases; installed-package execution is recorded by the ticket."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


class ScientificDecisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "data.csv").write_text("value\n1\n")
        self.p = ProjectBundle.create("Synthetic decisions", self.root)
        self.data = self.p.register_data("data.csv", "input")
        self.analysis = self.p.register_analysis("clustering run", [self.data])

    def decision(self, **changes):
        values = dict(text="submitted label", reason="synthetic rationale",
                      subjects=[{"ref": self.analysis, "cluster_id": "01", "annotation": "label A"}],
                      scientific_status="provisional", supporting=[self.data], contradictory=[self.data])
        values.update(changes)
        return self.p.record_scientific_decision(**values)

    def test_01_distinct_cluster_subjects_evidence_and_lifecycle_are_separate(self):
        other = self.p.register_analysis("second clustering run", [self.data])
        ref = self.decision(subjects=[{"ref": self.analysis, "cluster_id": "01", "annotation": "A"},
                                      {"ref": other, "cluster_id": "01", "annotation": "B"}])
        with patch.object(self.p, "_resolve", side_effect=AssertionError("decision getter must not read payloads")):
            view = self.p.get_decision(ref)
        self.assertEqual(view["approval"], "not_authenticated")
        self.assertEqual(view["record_status"], "active")
        self.assertEqual(view["scientific"]["scientific_status"], "provisional")
        self.assertEqual(view["scientific"]["supporting"], view["scientific"]["contradictory"])
        corrected = self.p.update_record(ref, {"status": "inactive"}, "lifecycle correction")
        self.assertEqual(self.p.get_decision(corrected)["scientific"]["scientific_status"], "provisional")

    def test_02_revisions_preserve_history_and_subjects_are_immutable(self):
        first = self.decision()
        second = self.decision(ref=first, scientific_status="approved",
                               subjects=[{"ref": self.analysis, "cluster_id": "01", "annotation": "corrected"}])
        third = self.decision(ref=second, scientific_status="superseded",
                              subjects=[{"ref": self.analysis, "cluster_id": "01", "annotation": "corrected"}])
        self.assertEqual(self.p.get_decision(first)["scientific"]["subjects"][0]["annotation"], "label A")
        self.assertEqual(self.p.get_decision(second)["scientific"]["scientific_status"], "approved")
        with self.assertRaises(BundleError):
            self.decision(ref=second)
        with self.assertRaises(BundleError):
            self.decision(ref=third, subjects=[{"ref": self.data, "annotation": "replacement"}])

    def test_03_invalid_writes_and_unknown_or_imported_views_are_conservative(self):
        before = copy.deepcopy(self.p.state)
        with self.assertRaises(BundleError): self.decision(scientific_status="accepted")
        with self.assertRaises(BundleError): self.decision(reason="   ")
        with self.assertRaises(BundleError): self.decision(subjects=[{"ref": self.analysis, "cluster_id": "1"}, {"ref": self.analysis, "cluster_id": "1"}])
        with self.assertRaises(BundleError): self.p.update_record(self.p.record_decision("legacy", "why", [self.data]), {"details": {"scientific_decision": {}}}, "inject")
        with self.assertRaises(BundleError): self.p.update_record(self.data, {"details": {"scientific_decision": {}}}, "inject")
        self.assertEqual(self.p.state["records"][:2], before["records"])
        legacy = self.p.record_decision("legacy", "why", [self.data])
        corrected = self.p.update_record(legacy, {"name": "generic correction", "details": {"note": "kept generic"}}, "generic correction")
        self.assertEqual(self.p._record(corrected)["name"], "generic correction")
        self.assertEqual(self.p.get_decision(legacy)["unknown"], ["legacy_untyped_decision"])
        typed = self.decision()
        rec = self.p._record(typed); rec["details"]["targets"] = [self.data]
        self.assertEqual(self.p.get_decision(typed)["unknown"], ["malformed_scientific_decision"])
        with self.assertRaises(BundleError): self.decision(ref=typed)
        rec = self.p._record(legacy); rec["details"]["scientific_decision"] = {"version": "future"}
        self.assertEqual(self.p.get_decision(legacy)["unknown"], ["unsupported_scientific_decision"])
        self.p.state["imported"] = True
        self.assertIn("untrusted_imported_claim", self.p.get_decision(legacy)["unknown"])

    def test_04_save_failure_stale_writer_and_fresh_recovery_preserve_decision(self):
        ref = self.decision()
        path = self.root / ".nb_project_bundle/project.json"
        raw = path.read_bytes()
        with patch("biodataledger.core.os.replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError): self.p.save_and_confirm()
        self.assertTrue(self.p.unsaved); self.assertEqual(path.read_bytes(), raw)
        self.p.save_and_confirm()
        self.assertEqual(ProjectBundle.open(self.root).get_decision(ref)["text"], "submitted label")
        stale = ProjectBundle.open(self.root); self.p.set_context({"next_task": "newer"}); self.p.save_and_confirm()
        stale.set_context({"next_task": "stale"})
        with self.assertRaises(BundleError): stale.save_and_confirm()
        raw = path.read_bytes()
        self.assertEqual(self.p.save_and_confirm()["status"], "no_changes")
        self.assertEqual(path.read_bytes(), raw)

    def test_05_r_python_roundtrip_and_legacy_writer_remain_usable(self):
        script = Path(__file__).with_name("r_scientific_decisions_exchange.R")
        python_ref = self.decision()
        self.p.save_and_confirm()
        env = dict(os.environ)
        if env.get("BDL_R_LIB"): env["R_LIBS_USER"] = env["BDL_R_LIB"]
        result = subprocess.run(["Rscript", "--vanilla", str(script), str(self.root), python_ref["id"] + "@" + str(python_ref["revision"])], env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        py = ProjectBundle.open(self.root)
        exchange = json.loads(result.stdout); ref = exchange["ref"]
        self.assertEqual(exchange["python_status"], "provisional")
        self.assertEqual(py.get_decision(ref), exchange["view"])
        native_import = ProjectBundle.import_zip(exchange["archive"], self.root / "native-import")
        self.assertEqual(native_import.get_decision(ref)["scientific"]["scientific_status"], "approved")
        py.set_context({"next_task": "Python canonical serialization"})
        py.save_and_confirm()
        archive = self.root / "decision-context.zip"
        py.export_zip(py.preview_export("context"), archive)
        imported = ProjectBundle.import_zip(archive, self.root / "imported")
        self.assertEqual(imported.get_decision(ref)["scientific"]["scientific_status"], "approved")
        self.assertIn("untrusted_imported_claim", imported.get_decision(ref)["unknown"])
        native = subprocess.run(["Rscript", "--vanilla", str(script), str(self.root / "python-import-r"),
                                 ref["id"] + "@" + str(ref["revision"]), "import", str(archive)],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        self.assertEqual(json.loads(native.stdout), imported.get_decision(ref))
        records_before_legacy = copy.deepcopy(ProjectBundle.open(self.root).state["records"])
        legacy_python = os.environ.get("BDL_LEGACY_PYTHON_PATH")
        if legacy_python:
            legacy_env = dict(os.environ); legacy_env.pop("PYTHONPATH", None)
            legacy = subprocess.run([legacy_python, "-c", "import importlib.metadata as m; from biodataledger import ProjectBundle; import sys; assert m.version('biodataledger') == '0.7.0'; p=ProjectBundle.open(sys.argv[1]); p.set_context({'next_task':'legacy writer'}); p.save()", str(self.root)],
                                    env=legacy_env, capture_output=True, text=True, timeout=30)
            self.assertEqual(legacy.returncode, 0, legacy.stdout + legacy.stderr)
        legacy_r = os.environ.get("BDL_LEGACY_R_LIB")
        if legacy_r:
            legacy = subprocess.run(["Rscript", "--vanilla", "-", legacy_r, str(self.root)],
                input="args<-commandArgs(TRUE); library(BioDataLedger,lib.loc=args[[1]]); stopifnot(as.character(packageVersion('BioDataLedger'))=='0.7.0'); p<-ProjectBundle$open(args[[2]]); p$set_context(list(next_task='legacy R writer')); invisible(p$save())",
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(legacy.returncode, 0, legacy.stdout + legacy.stderr)
        refreshed = ProjectBundle.open(self.root)
        self.assertEqual(refreshed.state["records"], records_before_legacy)
        self.assertEqual(refreshed.get_decision(ref)["scientific"]["scientific_status"], "approved")
        legacy = py.record_decision("still generic", "why", [self.data])
        self.assertEqual(py.get_decision(legacy)["unknown"], ["legacy_untyped_decision"])

