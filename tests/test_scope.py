"""Installed-client identity, explicit verification and loaded-query regressions."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import ProjectBundle, BundleError
from biodataledger.core import canonical, STATE_PATH


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "input.csv").write_text("sample,value\nS1,1\nS2,2\n")
        (self.root / "qc.py").write_text("# Synthetic source declaration\n")
        (self.root / "plot.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
        self.p = ProjectBundle.create("Synthetic scope", self.root)
        self.d = self.p.register_data("input.csv", "input", hash=True)
        self.design = self.p.set_design("treatment", ["Vehicle", "LowDose", "HighDose"],
                                        selected_levels=["Vehicle", "LowDose"], reference_level="Vehicle")
        self.scope = {"condition_values": ["Vehicle", "LowDose"],
                      "assignment_inclusion": ["assigned_hashed", "unassigned"],
                      "observation_unit": "cell", "evidence": {"basis": "declared", "source_refs": []}}
        self.p.save()

    def scoped(self):
        d = self.p.set_data_scope(self.d, self.scope, "synthetic confirmed scope", self.design)
        self.p.set_current(d, "cd8", "synthetic scientist selection")
        return d

    def test_loaded_queries_do_not_serialize_registry(self):
        a = self.p.register_analysis("QC", [self.d], code="qc.py")
        f = self.p.register_figure("plot.svg", "qc", analysis=a)
        self.p.save()
        with patch("biodataledger.core.canonical", side_effect=AssertionError("full serialization")):
            self.assertIsNone(self.p.get_data(ref=self.d).available)
            self.assertIsNone(self.p.get_figure(f).available)
            self.assertFalse(self.p.unsaved)
        with patch("biodataledger.core.fingerprint", side_effect=AssertionError("hash")):
            status = self.p.status()
        self.assertFalse(status["availability_checked"])
        self.assertEqual(status["missing"]["checked"], 0)

    def test_input_resolution_migration_preserves_exact_record(self):
        import biodataledger.core as core
        selected_path = (self.root / "selected.rds").resolve()
        selected_path.write_bytes(b"opaque fixture A")
        alternative_path = (self.root / "alternative.rds").resolve()
        alternative_path.write_bytes(b"opaque fixture B")
        selected = self.p.register_data(selected_path, "selected", hash=True)
        self.p.register_data(alternative_path, "selected", hash=True)
        self.p.set_current(selected, "analysis", "synthetic selected input")
        self.p.save()
        registry = self.root / STATE_PATH
        before = registry.read_bytes()
        history = copy.deepcopy(self.p.state["history"])
        expected_digest = hashlib.sha256(selected_path.read_bytes()).hexdigest()
        with patch.object(core, "fingerprint", side_effect=AssertionError("metadata inspection hashed a file")):
            metadata = self.p.get_data(purpose="analysis")
        self.assertIsNone(metadata.available)
        self.assertFalse(metadata.availability_checked)
        self.assertTrue(selected_path.is_file())
        with patch.object(core, "fingerprint", wraps=core.fingerprint) as hashes:
            resolved = self.p.resolve_data(purpose="analysis", verify="sha256")
        self.assertEqual([Path(call.args[0]) for call in hashes.call_args_list], [selected_path])
        self.assertEqual(resolved.ref, metadata.ref)
        self.assertEqual(resolved.ref, selected)
        self.assertEqual(resolved.path, selected_path)
        self.assertEqual(resolved.sha256, expected_digest)
        self.assertEqual(resolved.verification["observed_sha256"], expected_digest)
        self.assertTrue(resolved.available and resolved.availability_checked)
        self.assertFalse(self.p.get_data(ref=selected).availability_checked)
        selected_path.write_bytes(b"opaque fixture Z")
        self.assertTrue(self.p.get_data(ref=selected, check_files=True).available)
        with self.assertRaisesRegex(BundleError, "DIGEST_MISMATCH"):
            self.p.resolve_data(purpose="analysis", verify="sha256")
        selected_path.unlink()
        with self.assertRaisesRegex(BundleError, "MISSING_FILE"):
            self.p.resolve_data(purpose="analysis", verify="sha256")
        self.assertTrue(alternative_path.is_file())
        self.assertEqual(self.p.get_data(purpose="analysis").ref, selected)
        self.assertEqual(self.p.get_data(ref=selected).sha256, expected_digest)
        self.assertEqual(self.p.state["history"], history)
        self.assertFalse(self.p.unsaved)
        self.assertEqual(registry.read_bytes(), before)

    def test_trial_refuses_input_drift_before_registering_outputs(self):
        source = Path(__file__).resolve().parents[1] / "examples/trial_python.py"
        spec = importlib.util.spec_from_file_location("trial_resolution", source)
        trial = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(trial)
        original_open = ProjectBundle.open
        folder = self.root / "trial-drift"
        def open_after_drift(project_dir):
            project = original_open(project_dir)
            path = Path(project_dir) / "input.csv"
            raw = path.read_bytes()
            changed = raw.replace(b"S1,300", b"S1,301")
            self.assertNotEqual(raw, changed)
            path.write_bytes(changed)
            return project
        with patch.object(ProjectBundle, "open", side_effect=open_after_drift):
            with self.assertRaisesRegex(BundleError, "DIGEST_MISMATCH"):
                trial.main(folder)
        self.assertEqual(original_open(folder).summary()["counts"], {"data": 1, "analysis": 0, "figure": 0})
        r_script = r'''
args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc=Sys.getenv("BDL_R_LIB"))
original_open <- ProjectBundle$open
trial <- new.env(parent=globalenv())
trial$ProjectBundle <- ProjectBundle
trial$ProjectBundle$open <- function(project_dir) {
  project <- original_open(project_dir)
  path <- file.path(project_dir,"input.csv")
  raw <- readChar(path,file.info(path)$size,useBytes=TRUE)
  changed <- sub("S1,300","S1,301",raw,fixed=TRUE)
  stopifnot(raw != changed)
  writeBin(charToRaw(changed),path)
  project
}
trial$commandArgs <- function(trailingOnly=FALSE) c(args[[2]],args[[3]])
result <- try(sys.source(args[[1]],envir=trial),silent=TRUE)
stopifnot(inherits(result,"try-error"),grepl("DIGEST_MISMATCH",as.character(result),fixed=TRUE))
counts <- original_open(args[[2]])$summary()$counts
stopifnot(counts$data == 1L,counts$analysis == 0L,counts$figure == 0L)
'''
        repo = Path(__file__).resolve().parents[1]
        result = subprocess.run(["Rscript", "--vanilla", "-", str(repo / "examples/trial_R.R"),
                                 str(self.root / "r-trial-drift"), str(repo / "examples/input-files")],
                                input=r_script, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_clean_save_has_no_lock_or_registry_io(self):
        self.p.set_context({"next_task": None})
        self.assertFalse(self.p.unsaved)
        with patch.object(Path, "mkdir", side_effect=AssertionError("lock write")), \
                patch.object(Path, "read_bytes", side_effect=AssertionError("registry reload")):
            self.p.save()

    def test_dirty_save_checks_bytes_and_validates_proposed_state_once(self):
        import biodataledger.core as core
        self.p.set_context({"next_task": "Retain the selected result"})
        with patch.object(core, "parse_json", side_effect=AssertionError("unchanged registry reparsed")), \
                patch.object(core, "validate_state", wraps=core.validate_state) as validate:
            self.p.save()
        self.assertEqual(validate.call_count, 1)
        self.assertEqual(ProjectBundle.open(self.root).summary()["next_task"], "Retain the selected result")
        before = (self.root / STATE_PATH).read_bytes()
        self.p.set_context({"next_task": "Pending edit"})
        # Inject an invalid staged value to exercise the final persistence boundary.
        self.p.state["records"][0]["details"]["bad_number"] = float("nan")
        with self.assertRaises(BundleError):
            self.p.save()
        self.assertTrue(self.p.unsaved)
        self.assertEqual((self.root / STATE_PATH).read_bytes(), before)

    def test_scope_revision_pin_and_strict_resolution(self):
        d = self.scoped()
        self.assertNotEqual(d, self.d)
        self.assertIsNone(self.p.get_data(ref=self.d).scope)
        v = self.p.resolve_data(purpose="cd8", verify="sha256", expected_scope={"assignment_inclusion": self.scope["assignment_inclusion"]})
        self.assertEqual(v.ref, d)
        self.assertEqual(v.design_ref, self.design)
        self.assertEqual(v.verification["file_integrity"], "match")
        self.assertEqual(v.verification["scope_basis"], "declared")
        a = self.p.register_analysis("Retained", [d], code="qc.py", method="fixture", params={"x": 1})
        f = self.p.register_figure("plot.svg", "qc", analysis=a)
        self.p.save()
        self.p.set_design("treatment", ["Vehicle", "LowDose", "HighDose"])
        self.assertEqual(self.p.state["schema_version"], "0.4.0")
        self.assertEqual(self.p.get_figure(f).inputs, [d])
        self.assertEqual(self.p.status(purpose="cd8")["dataset"]["design_ref"], self.design)
        self.assertFalse(self.p.resolve_data(ref=d, verify="sha256").verification["verified_scope_fields"])

    def test_failure_cases_do_not_choose_another_input(self):
        d = self.scoped()
        self.p.register_data("input.csv", "input", hash=True)
        for kwargs in ({"purpose": "absent"}, {"ref": d, "purpose": "cd8"}, {}):
            with self.assertRaises(BundleError):
                self.p.resolve_data(verify="sha256", **kwargs)
        with self.assertRaises(BundleError):
            self.p.get_data(role="input")
        before = canonical(self.p.state)
        with self.assertRaisesRegex(BundleError, "SCOPE_CONFLICT"):
            self.p.resolve_data(ref=d, verify="sha256", expected_scope={"assignment_inclusion": ["assigned_hashed"]})
        with self.assertRaisesRegex(BundleError, "SCOPE_UNKNOWN"):
            self.p.resolve_data(ref=d, verify="sha256", expected_scope={"assay": "RNA"})
        path = self.root / "input.csv"
        path.write_bytes(path.read_bytes().replace(b"S1,1", b"S1,9"))
        with self.assertRaisesRegex(BundleError, "DIGEST_MISMATCH"):
            self.p.resolve_data(ref=d, verify="sha256")
        path.unlink()
        with self.assertRaisesRegex(BundleError, "MISSING_FILE"):
            self.p.resolve_data(ref=d, verify="sha256")
        self.assertEqual(canonical(self.p.state), before)

    def test_invalid_changes_are_atomic_and_views_detached(self):
        before = canonical(self.p.state)
        for scope in ({"invalid": True}, {"condition_values": ["Vehicle", "Vehicle"]},
                      {"evidence": {"basis": "verified", "source_refs": []}}):
            with self.assertRaises(BundleError):
                self.p.set_data_scope(self.d, scope, "invalid", self.design)
            self.assertEqual(canonical(self.p.state), before)
            self.assertFalse(self.p.unsaved)
        d = self.scoped()
        view = self.p.get_data(ref=d)
        view.scope["condition_values"].append("mutated")
        self.assertEqual(self.p.get_data(ref=d).scope["condition_values"], self.scope["condition_values"])

    def test_required_verification_and_design_conflict(self):
        d = self.scoped()
        with self.assertRaises((TypeError, BundleError)):
            self.p.resolve_data(ref=d)
        with self.assertRaises(BundleError):
            self.p.resolve_data(ref=d, verify="exists")
        conflict = self.p.set_data_scope(d, dict(self.scope, condition_values=["Vehicle"]), "record incomplete cohort", self.design)
        with self.assertRaisesRegex(BundleError, "SCOPE_CONFLICT"):
            self.p.resolve_data(ref=conflict, verify="sha256")
        missing = self.p.register_data("input.csv", "unhashed")
        with self.assertRaisesRegex(BundleError, "MISSING_DIGEST"):
            self.p.resolve_data(ref=missing, verify="sha256")

    def membership_fixture(self):
        (self.root / "membership.csv").write_text("sample\nS1\nS2\n")
        member = self.p.register_data("membership.csv", "membership", hash=True)
        details = self.p.get_data(ref=self.d).details
        details["membership"] = member
        subject = self.p.update_record(self.d, {"details": details}, "link synthetic membership")
        report = {"report_version": "biodataledger-membership-check/1",
                  "subject_sha256": self.p.get_data(ref=subject).sha256,
                  "membership_ref": member, "membership_sha256": self.p.get_data(ref=member).sha256,
                  "key_columns": ["sample"], "key_namespace": "synthetic", "comparison": "ordered_keys",
                  "result": "match", "checked_at": "2026-11-02T12:00:00Z",
                  "checker": {"method": "Compare synthetic CSV sample keys", "origin": "native_check", "analysis_ref": None},
                  "counts": {"subject_rows": 2, "membership_rows": 2, "subject_duplicate_keys": 0,
                             "membership_duplicate_keys": 0, "missing_keys": 0, "extra_keys": 0}}
        import csv
        with (self.root / "input.csv").open() as inp, (self.root / "membership.csv").open() as mem:
            self.assertEqual([x["sample"] for x in csv.DictReader(inp)], [x["sample"] for x in csv.DictReader(mem)])
        (self.root / "report.json").write_text(json.dumps(report))
        evidence = self.p.register_data("report.json", "membership_report", hash=True)
        scope = dict(self.scope, membership_evidence={"status": "verification_recorded", "report_ref": evidence})
        return subject, scope, report

    def test_membership_binding_and_explicit_recheck(self):
        subject, scope, _ = self.membership_fixture()
        d = self.p.set_data_scope(subject, scope, "record independent synthetic check", self.design)
        declared = self.p.resolve_data(ref=d, verify="sha256")
        self.assertEqual(declared.verification["membership"], "verification_recorded_not_rechecked")
        checked = self.p.resolve_data(ref=d, verify="sha256", require_membership=True)
        self.assertEqual(checked.verification["membership"], "verified_against_recorded_evidence")
        self.assertEqual(checked.verification["verified_scope_fields"], [])
        before = canonical(self.p.state)
        with self.assertRaises(BundleError):
            self.p.update_record(d, {"path": "input.csv"}, "cannot transfer evidence")
        self.assertEqual(canonical(self.p.state), before)
        (self.root / "membership.csv").write_text("sample\nS1\nS3\n")
        self.p.set_data_scope(subject, scope, "record prior evidence without rereading members", self.design)
        with self.assertRaises(BundleError):
            self.p.resolve_data(ref=d, verify="sha256", require_membership=True)

    def test_failed_snapshot_registration_does_not_leak(self):
        before = canonical(self.p.state)
        with self.assertRaises(BundleError):
            self.p.register_analysis("Invalid", [self.d], code="qc.py", params=[])
        self.assertEqual(canonical(self.p.state), before)
        self.assertFalse(self.p.unsaved)
        self.assertEqual(self.p._snapshots, {})

    def r_call(self, action, *args, root=None):
        script = Path(__file__).with_name("r_scope_exchange.R")
        result = subprocess.run(["Rscript", "--vanilla", str(script), os.environ["BDL_R_LIB"], action,
                                 str(root or self.root), *map(str, args)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_scope_roundtrip_both_native_clients(self):
        d = self.scoped()
        self.p.set_current(d, "comparison", "shared native fixture")
        self.p.save()
        key = d["id"] + "@" + str(d["revision"])
        observed = self.r_call("inspect", key)
        self.assertEqual(observed["data"]["scope"], self.p.get_data(ref=d).scope)
        self.assertEqual(observed["data"]["design_ref"], self.design)
        self.assertIsNone(observed["data"]["available"])
        self.assertEqual(observed["status"], self.p.status(purpose="comparison"))
        self.r_call("append", key)
        q = ProjectBundle.open(self.root)
        self.assertEqual(q.get_figure("FIG-001@1").inputs, [d])
        other = self.root / "r-created"
        other.mkdir()
        created = self.r_call("create", root=other)
        r_project = ProjectBundle.open(other)
        self.assertEqual(r_project.get_data(purpose="comparison").scope, created["data"]["scope"])
        r_project.set_context({"next_task": "Python revision"})
        r_project.save()
        rkey = created["ref"]["id"] + "@" + str(created["ref"]["revision"])
        self.assertEqual(self.r_call("inspect", rkey, root=other)["data"]["scope"], created["data"]["scope"])

    def test_membership_report_survives_native_reopen(self):
        subject, scope, _ = self.membership_fixture()
        d = self.p.set_data_scope(subject, scope, "record synthetic membership", self.design)
        self.p.save()
        before = (self.root / STATE_PATH).read_bytes()
        key = d["id"] + "@" + str(d["revision"])
        native = self.r_call("verify", key)
        python = self.p.resolve_data(ref=d, verify="sha256", require_membership=True).verification
        native.pop("checked_at")
        python.pop("checked_at")
        self.assertEqual(native, python)
        self.assertEqual((self.root / STATE_PATH).read_bytes(), before)

    def test_malformed_reference_rejects_before_hashing(self):
        bad = dict(self.d, id=["DATA-001"])
        with patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected hash")):
            with self.assertRaises(BundleError):
                self.p.get_data(ref=bad)

    def test_metadata_size_guard_preserves_saved_registry(self):
        before = (self.root / STATE_PATH).read_bytes()
        self.p.set_context({"next_task": "x" * 1000})
        with patch("biodataledger.core.MAX_JSON", len(before) + 100):
            with self.assertRaises(BundleError):
                self.p.save()
        self.assertEqual((self.root / STATE_PATH).read_bytes(), before)
        self.assertTrue(self.p.unsaved)


if __name__ == "__main__":
    unittest.main()
