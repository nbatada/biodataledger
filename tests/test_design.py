"""Synthetic experimental design contract, exercised through installed clients."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle, __version__
from biodataledger.core import STATE_PATH, canonical
from test_interop import R_LIBRARY

BASE = Path(__file__).resolve().parents[1]
FIXTURE = BASE / "tests/fixtures/design.json"
DESIGN = json.loads(FIXTURE.read_text())
RSCRIPT = BASE / "tests/r_design_exchange.R"


def r_design(action, root, *args):
    result = subprocess.run(["Rscript", "--vanilla", str(RSCRIPT), R_LIBRARY,
                             action, str(root), str(FIXTURE), *map(str, args)],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stderr + result.stdout)
    return result.stdout


class DesignTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.p = ProjectBundle.create("PRMT5 (synthetic)", self.root,
                                      purpose="Treatment-associated changes in T-cell populations")

    def populate(self):
        self.p.set_design(**DESIGN)
        (self.root / "input.csv").write_text("synthetic\n")
        data = self.p.register_data("input.csv", "analysis_ready")
        analysis = self.p.register_analysis("Declared synthetic comparison", [data])
        (self.root / "figure.svg").write_text("synthetic")
        figure = self.p.register_figure("figure.svg", "qc", analysis=analysis)
        self.p.save()
        return data, analysis, figure

    def test_missing_design_and_legacy_files_are_unchanged(self):
        before = (self.root / STATE_PATH).read_bytes()
        for method in (self.p.get_design, self.p.get_condition, self.p.get_levels,
                       self.p.get_selected_levels, self.p.get_reference_level,
                       self.p.get_replicate, self.p.get_design_summary):
            self.assertIsNone(method())
        self.assertIn("not configured", repr(self.p))
        self.assertEqual((self.root / STATE_PATH).read_bytes(), before)
        self.assertFalse(self.p.unsaved)
        for source in ("minimal.json", "with-provenance.json"):
            raw = (BASE / "tests/fixtures" / source).read_bytes()
            (self.root / STATE_PATH).write_bytes(raw)
            p = ProjectBundle.open(self.root)
            self.assertIsNone(p.get_design())
            self.assertEqual((self.root / STATE_PATH).read_bytes(), raw)
        with self.assertRaises(BundleError):
            self.p.check_design_metadata({})

    def test_getters_order_persistence_and_detached_values(self):
        ref = self.p.set_design(**DESIGN)
        self.assertEqual(ref["revision"], 1)
        self.assertTrue(self.p.unsaved)
        self.p.save()
        p = ProjectBundle.open(self.root)
        self.assertEqual(p.get_condition(), "treatment")
        self.assertEqual(p.get_levels(), DESIGN["levels"])
        self.assertEqual(p.get_selected_levels(), DESIGN["selected_levels"])
        self.assertEqual(p.get_reference_level(), "Vehicle")
        self.assertEqual(p.get_replicate(), "mouse_id")
        self.assertEqual(p.get_design()["evidence_source"], "scientist-declared")
        self.assertIsNone(p.get_design()["metadata_check"])
        p.get_design()["levels"].append("unrelated")
        self.assertEqual(p.get_levels(), DESIGN["levels"])
        p.set_design("dose", ["b", "a"], selection_reason="")
        self.assertEqual(p.get_selected_levels(), ["b", "a"])
        self.assertIsNone(p.get_reference_level())
        self.assertEqual(p.state["schema_version"], "0.2.0")

    def test_invalid_changes_are_atomic_in_both_languages(self):
        self.populate()
        before = canonical(self.p.state)
        cases = [dict(levels=["Vehicle", "Vehicle"]), dict(levels=[]), dict(levels=[""]),
                 dict(levels=[" "]), dict(levels=[1]), dict(levels="Vehicle"),
                 dict(selected_levels=[]), dict(selected_levels=["not-present"]),
                 dict(selected_levels=["Vehicle", "Vehicle"]), dict(reference_level="HighDose"),
                 dict(reference_level=""), dict(condition=""), dict(replicate=" ")]
        for changes in cases:
            args = dict(DESIGN, **changes)
            with self.subTest(changes=changes):
                with self.assertRaises((BundleError, TypeError)):
                    self.p.set_design(**args)
                self.assertEqual(canonical(self.p.state), before)
                self.assertEqual(r_design("invalid_set", self.root, json.dumps(args)).strip(), "REJECTED")
        self.assertEqual((self.root / STATE_PATH).read_bytes(), before)

    def test_history_pins_analyses_figures_and_corrections(self):
        _, analysis, figure = self.populate()
        original = self.p.get_design()
        self.p.set_design(**dict(DESIGN, selected_levels=DESIGN["levels"]))
        self.p.set_design(**DESIGN)
        self.assertEqual(self.p.get_design()["ref"]["revision"], 3)
        self.assertEqual(self.p.get_design("DES-001@2")["selected_levels"], DESIGN["levels"])
        self.assertEqual(self.p.get_analysis(analysis).design, original)
        self.assertEqual(self.p.get_figure(figure).design, original)
        corrected = self.p.update_record(analysis, {"name": "Corrected name"}, "name correction")
        self.assertEqual(self.p.get_analysis(corrected).design, original)
        new_figure = self.p.register_figure("figure.svg", "qc")
        self.assertEqual(self.p.get_figure(new_figure).design["ref"]["revision"], 3)
        with self.assertRaises(BundleError):
            self.p.update_record(original["ref"], {"name": "bad correction"}, "test")
        self.p.save()
        p = ProjectBundle.open(self.root)
        self.assertEqual(p.get_figure(figure).design, original)
        self.assertEqual(len([e for e in p.state["history"] if e["action"] == "set_design"]), 3)
        self.assertEqual(p.summary()["counts"], {"data": 1, "analysis": 1, "figure": 2})

    def test_pre_design_analysis_remains_unknown(self):
        a = self.p.register_analysis("Before design", None)
        (self.root / "f.svg").write_text("synthetic")
        self.p.set_design(**DESIGN)
        f = self.p.register_figure("f.svg", "qc", analysis=a)
        self.assertIsNone(self.p.get_analysis(a).design)
        self.assertIsNone(self.p.get_figure(f).design)

    def test_python_r_python_design_and_metadata_roundtrip(self):
        data, analysis, figure = self.populate()
        original = self.p.get_design()
        r = json.loads(r_design("inspect", self.root))
        self.assertEqual(r["design"], original)
        self.assertEqual(r["text"], repr(self.p))
        self.assertEqual(r["analysis_design"], original)
        self.assertEqual(r["figure_design"], original)
        r_design("change", self.root)
        p = ProjectBundle.open(self.root)
        self.assertEqual(p.get_selected_levels(), DESIGN["levels"])
        self.assertEqual(p.get_figure(figure).design, original)
        columns = {"treatment": ["LowDose", "Vehicle"], "mouse_id": ["m1", "m2"]}
        r = json.loads(r_design("metadata", self.root, json.dumps(columns)))
        p = ProjectBundle.open(self.root)
        self.assertEqual(r["design"], p.get_design())
        self.assertEqual(p.get_design()["context"], [data])
        self.assertEqual(p.get_design()["metadata_check"], p.check_design_metadata(columns))

    def test_r_python_r_and_both_archive_directions(self):
        root = self.base / "from-r"
        root.mkdir()
        original = json.loads(r_design("create", root))
        p = ProjectBundle.open(root)
        self.assertEqual(p.get_design(), original)
        p.set_design(**dict(DESIGN, selected_levels=DESIGN["levels"]))
        p.save()
        r = json.loads(r_design("inspect", root))
        self.assertEqual(r["design"], p.get_design())
        self.assertEqual(r["figure_design"], original)
        archive = self.base / "python.zip"
        p.export_zip(p.preview_export("context"), archive)
        r = json.loads(r_design("import", self.base / "r-import", archive))
        self.assertEqual(r["design"], p.get_design())
        archive = self.base / "r.zip"
        r_design("export", root, archive)
        q = ProjectBundle.import_zip(archive, self.base / "python-import")
        self.assertEqual(q.get_design(), p.get_design())
        self.assertEqual(q.get_figure("FIG-001@1").design, original)

    def test_metadata_checks_without_file_reads(self):
        data, _, _ = self.populate()
        columns = {"treatment": ["LowDose", "Vehicle", "LowDose"], "mouse_id": [1, 2, 3]}
        before = canonical(self.p.state)
        with patch.object(Path, "open", side_effect=AssertionError("unexpected file read")):
            report = self.p.check_design_metadata(columns)
            self.assertEqual(canonical(self.p.state), before)
            self.p.set_design(**DESIGN, metadata=columns, context=[data])
        self.assertTrue(report["valid"])
        self.assertEqual(report["observed_levels"], ["LowDose", "Vehicle"])
        self.assertEqual(report["missing_levels"], ["HighDose"])
        self.assertEqual(self.p.get_design()["metadata_check"], report)
        self.assertEqual(self.p.get_design()["evidence_source"], "metadata-verified")
        self.p.save()
        self.assertEqual(json.loads(r_design("check_metadata", self.root, json.dumps(columns))), report)
        self.assertEqual(json.loads(r_design("inspect", self.root))["design"], self.p.get_design())

    def test_metadata_missing_unknown_empty_and_malformed(self):
        self.populate()
        for columns in ({}, {"treatment": ["Vehicle"]},
                        {"treatment": ["Unknown"], "mouse_id": ["m1"]},
                        {"treatment": [None], "mouse_id": ["m1"]},
                        {"treatment": ["Vehicle"], "mouse_id": [None]},
                        {"treatment": [], "mouse_id": []}):
            with self.subTest(columns=columns):
                report = self.p.check_design_metadata(columns)
                self.assertFalse(report["valid"])
                self.assertEqual(json.loads(r_design("check_metadata", self.root, json.dumps(columns))), report)
                before = canonical(self.p.state)
                with self.assertRaises(BundleError):
                    self.p.set_design(**DESIGN, metadata=columns)
                self.assertEqual(canonical(self.p.state), before)
        partial = self.p.check_design_metadata({"treatment": ["Vehicle"], "mouse_id": ["m1"]})
        self.assertTrue(partial["valid"])
        self.assertEqual(partial["missing_selected_levels"], ["LowDose"])
        for columns in ({"treatment": ["Vehicle"], "mouse_id": []}, {"treatment": "Vehicle", "mouse_id": [1]}, {"treatment": [["Vehicle"]], "mouse_id": [1]}):
            with self.assertRaises(BundleError):
                self.p.check_design_metadata(columns)

    def test_persisted_invalid_design_rejected_by_both(self):
        self.populate()
        original = copy.deepcopy(self.p.state)
        changes = [lambda s: s.update(schema_version="0.1.0"),
                   lambda s: s["project"]["design"].update(revision=999),
                   lambda s: s["records"][0]["details"].update(selected_levels=["unknown"]),
                   lambda s: s["records"][0]["details"].update(evidence_source="metadata-verified"),
                   lambda s: s["records"][0]["details"].update(context={"data": None}),
                   lambda s: s["records"][0]["details"].update(context=[s["project"]["design"]]),
                   lambda s: s["records"][2]["design"].update(id="DATA-001")]
        for change in changes:
            state = copy.deepcopy(original)
            change(state)
            (self.root / STATE_PATH).write_text(json.dumps(state))
            with self.assertRaises(BundleError):
                ProjectBundle.open(self.root)
            self.assertEqual(r_design("invalid", self.root).strip(), "REJECTED")

    def test_exact_design_refs_and_single_figure_authority(self):
        self.populate()
        original = copy.deepcopy(self.p.state)
        changes = [lambda s: s["project"]["design"].update(extra="invalid"),
                   lambda s: s["records"][2]["design"].update(extra="invalid"),
                   lambda s: s["records"][3].update(design=s["project"]["design"])]
        for change in changes:
            state = copy.deepcopy(original)
            change(state)
            (self.root / STATE_PATH).write_text(json.dumps(state))
            with self.assertRaises(BundleError):
                ProjectBundle.open(self.root)
            self.assertEqual(r_design("invalid", self.root).strip(), "REJECTED")

    def test_inspection_runtime_version_and_pending_state_without_io(self):
        self.populate()
        before = canonical(self.p.state)
        with patch.object(Path, "open", side_effect=AssertionError("unexpected read")), \
                patch.object(Path, "exists", side_effect=AssertionError("unexpected probe")), \
                patch("builtins.open", side_effect=AssertionError("unexpected read")), \
                patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected hash")):
            for purpose in (None, "comparison"):
                text = self.p.summary_text(purpose)
                self.assertIn(f"Package version: {__version__}", text)
                self.assertIn(f"Registry revision: {self.p.state['state_revision']}", text)
                self.assertIn("Unsaved changes: no", text)
                self.assertEqual(self.p.status(purpose=purpose)["package_version"], __version__)
            self.assertIn(f"Package version: {__version__}", repr(self.p))
            self.assertEqual(canonical(self.p.state), before)
            self.p.set_context({"next_task": "staged task"})
            self.assertIn("Unsaved changes: yes", repr(self.p))
            self.assertTrue(self.p.status()["unsaved"])
        self.assertNotIn("package_version", self.p.state)

    def test_compact_print_and_design_endpoint(self):
        self.populate()
        with patch.object(Path, "open", side_effect=AssertionError("unexpected read")):
            text = repr(self.p)
            compact = self.p.get_design_summary()
        for expected in ("BioDataLedger: PRMT5 (synthetic)", "Selected levels:  Vehicle, LowDose", "Excluded:         HighDose", "1 registered datasets"):
            self.assertIn(expected, text)
        self.assertEqual(compact["revision"], 1)
        self.assertFalse(compact["truncated"])
        levels = [str(i) + "漢" * 500 for i in range(12)]
        self.p.set_design("é" * 500, levels, reference_level=levels[0], selection_reason="x" * 10000)
        self.p.save()
        self.assertLess(len(repr(self.p).encode()), 8000)
        self.assertTrue(self.p.get_design_summary()["truncated"])
        self.assertEqual(len(self.p.get_design_summary()["selected_levels"]), 5)
        self.assertEqual(json.loads(r_design("inspect", self.root))["compact"], self.p.get_design_summary())
        self.assertLessEqual(len(canonical(self.p.status())), 4096)

    def test_design_stale_writers_in_both_directions(self):
        self.populate()
        ready, go = self.base / "ready", self.base / "go"
        worker = subprocess.Popen(["Rscript", "--vanilla", str(RSCRIPT), R_LIBRARY,
                                   "stale", str(self.root), str(FIXTURE), str(ready), str(go)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: worker.kill() if worker.poll() is None else None)
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline and worker.poll() is None:
            time.sleep(.02)
        self.assertTrue(ready.exists())
        self.p.set_design(**dict(DESIGN, selected_levels=DESIGN["levels"]))
        self.p.save()
        go.write_text("go")
        stdout, stderr = worker.communicate(timeout=15)
        self.assertEqual(worker.returncode, 0, stderr)
        self.assertEqual(stdout, "REJECTED")
        p = ProjectBundle.open(self.root)
        p.set_design(**DESIGN)
        r_design("change", self.root)
        with self.assertRaisesRegex(BundleError, "stale"):
            p.save()
        self.assertTrue(p.unsaved)


if __name__ == "__main__":
    unittest.main()
