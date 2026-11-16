import tempfile
from pathlib import Path
import unittest
import os
import json

from biodataledger import BundleError, ProjectBundle
from biodataledger import metadata as metadata_module


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.project = ProjectBundle.create("metadata fixture", self.root)

    def tearDown(self):
        self.temp.cleanup()

    def csv(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def table(self, name="samples.csv", text="sample,patient\n001,P1\n002,P2\n", **kwargs):
        return self.project.register_metadata(self.csv(name, text), "sample_preparation", ["sample"],
                                              authority="lab", reason="synthetic fixture", **kwargs)

    def test_capture_preserves_text_and_paged_get(self):
        ref = self.table(text="sample,value,optional\n001,NA,\n002,0,x\n")
        page = self.project.get_metadata(ref, limit=1, offset=1)
        self.assertEqual(page["bl_rows"], [{"sample": "002", "value": "0", "optional": "x"}])
        self.assertEqual(page["bl_columns"], ["sample", "value", "optional"])
        self.assertTrue(page["bl_has_more"] is False)
        record = self.project.get_data(ref)
        self.assertTrue(record.path.read_bytes().startswith(b"sample,value"))

    def test_rejects_bad_csv_and_generic_metadata_role(self):
        with self.assertRaises(BundleError):
            self.table(text="sample,sample\n1,2\n")
        with self.assertRaises(BundleError):
            self.table(text="sample,value\n,2\n")
        with self.assertRaises(BundleError):
            self.project.register_data(self.csv("generic.csv", "x\n1\n"), "bl_metadata_table", hash=True)
        ordinary = self.project.register_data(self.root / "generic.csv", "metadata_table", hash=True)
        self.assertEqual(self.project.get_data(ordinary).role, "metadata_table")
        before = list((self.root / ".nb_project_bundle" / "outputs").glob("metadata-*")) if (self.root / ".nb_project_bundle" / "outputs").exists() else []
        with self.assertRaises(BundleError):
            self.project.register_metadata(self.csv("bad-link.csv", "library,sample\nL1,001\n"), "acquisition", ["library"],
                                           authority="lab", reason="bad", links=[{"ref": "DATA-999@1", "columns": ["sample"], "target_columns": ["sample"]}])
        after = list((self.root / ".nb_project_bundle" / "outputs").glob("metadata-*")) if (self.root / ".nb_project_bundle" / "outputs").exists() else []
        self.assertEqual(after, before)

    def test_links_revisions_bindings_and_no_payload_view(self):
        samples = self.table()
        libraries = self.project.register_metadata(
            self.csv("libraries.tsv", "library\tsample\nL1\t001\nL2\t002\n"), "acquisition", ["library"],
            authority="sequencing", reason="synthetic fixture", delimiter="\t",
            links=[{"ref": samples, "columns": ["sample"], "target_columns": ["sample"]}])
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [samples, libraries], "attach source tables")
        first = self.project.metadata_view(bound)
        self.assertEqual(first["bl_limits"]["bl_visited_records"], 3)
        self.assertEqual([x["bl_ref"] for x in first["bl_categories"]["sample_preparation"]], [samples])
        self.assertEqual(self.project.check_metadata(bound, ["sample_preparation", "acquisition"])["bl_status"], "PASS")
        # Generic updates cannot replace a pinned binding, and the table revision is explicit.
        with self.assertRaises(BundleError):
            self.project.update_record(bound, {"details": {}}, "bad correction")
        revised = self.project.register_metadata(self.csv("new.csv", "sample,patient\n001,P9\n002,P2\n"), "sample_preparation", ["sample"], authority="lab", reason="correction", ref=samples)
        self.assertNotEqual(samples, revised)
        self.assertEqual(self.project.metadata_view(bound)["bl_source_refs"][0], samples)

    def test_invalid_foreign_key_and_conflict_fail(self):
        samples = self.table()
        with self.assertRaises(BundleError):
            self.project.register_metadata(self.csv("broken.csv", "library,sample\nL1,009\n"), "acquisition", ["library"], authority="lab", reason="bad link",
                                           links=[{"ref": samples, "columns": ["sample"], "target_columns": ["sample"]}])
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        conflicting = self.project.register_metadata(self.csv("conflict.csv", "sample,patient\n001,P9\n"), "sample_preparation", ["sample"], authority="other", reason="conflict")
        conflict_bound = self.project.bind_metadata(raw, [samples, conflicting], "conflict")
        self.assertEqual(self.project.check_metadata(conflict_bound)["bl_status"], "FAIL")

    def test_missing_snapshot_is_unknown_and_reopen_validates(self):
        metadata = self.table()
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [metadata], "attach")
        self.project.save()
        self.project.get_data(metadata).path.unlink()
        self.assertEqual(self.project.check_metadata(bound)["bl_status"], "UNKNOWN")
        self.project = ProjectBundle.open(self.root)
        self.assertEqual(self.project.metadata_view(bound)["bl_source_refs"], [metadata])

    def test_source_and_managed_snapshot_symlinks_are_rejected(self):
        source = self.csv("source.csv", "sample,patient\n001,P1\n")
        source_link = self.root / "source-link.csv"
        os.symlink(source.name, source_link)
        with self.assertRaises(BundleError):
            self.project.register_metadata(source_link, "sample_preparation", ["sample"], authority="lab", reason="unsafe source")
        metadata = self.table()
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [metadata], "attach")
        snapshot = self.project.get_data(metadata).path
        replacement = self.csv("same-bytes.csv", snapshot.read_text(encoding="utf-8"))
        snapshot.unlink()
        os.symlink(replacement, snapshot)
        report = self.project.check_metadata(bound)
        self.assertEqual(report["bl_status"], "FAIL")
        self.assertEqual(report["bl_issues"][0]["bl_code"], "UNSAFE_FILE")

    def test_stale_save_retains_staged_snapshot(self):
        first = ProjectBundle.open(self.root)
        second = ProjectBundle.open(self.root)
        path = self.csv("stale.csv", "sample,patient\n001,P1\n")
        metadata = second.register_metadata(path, "sample_preparation", ["sample"], authority="lab", reason="stale")
        snapshot = second.get_data(metadata).path
        first.set_context({"next_task": "other writer"})
        first.save()
        with self.assertRaises(BundleError):
            second.save()
        self.assertTrue(snapshot.is_file())
        self.assertTrue(second.unsaved)

    def test_relative_path_latest_revision_and_single_check_read(self):
        (self.root / "relative.csv").write_text("sample,patient\n001,P1\n", encoding="utf-8")
        ref = self.project.register_metadata("relative.csv", "sample_preparation", ["sample"], authority="lab", reason="relative")
        revised = self.project.register_metadata(self.csv("revised.csv", "sample,patient\n001,P2\n"), "sample_preparation", ["sample"], authority="lab", reason="revise", ref=ref)
        with self.assertRaises(BundleError):
            self.project.register_metadata(self.csv("stale-revision.csv", "sample,patient\n001,P3\n"), "sample_preparation", ["sample"], authority="lab", reason="stale", ref=ref)
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [revised], "attach")
        with self.assertRaises(BundleError):
            self.project.bind_metadata(raw, [revised], "stale target")
        calls, original = [], metadata_module._read
        def counted(*args, **kwargs):
            calls.append(args[0]); return original(*args, **kwargs)
        metadata_module._read = counted
        try:
            self.assertEqual(self.project.check_metadata(bound)["bl_status"], "PASS")
        finally:
            metadata_module._read = original
        self.assertEqual(len(calls), 1)

    def test_context_and_working_archives_preserve_or_mark_metadata_unavailable(self):
        metadata = self.table()
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [metadata], "attach")
        self.project.save()
        context = self.project.preview_export("context")
        context_path = self.root / "context.zip"
        self.project.export_zip(context, context_path)
        imported_context = ProjectBundle.import_zip(context_path, self.root / "context-import")
        self.assertEqual(imported_context.check_metadata(bound)["bl_status"], "UNKNOWN")
        working = self.project.preview_export("working", include=[metadata])
        working_path = self.root / "working.zip"
        self.project.export_zip(working, working_path)
        imported_working = ProjectBundle.import_zip(working_path, self.root / "working-import")
        self.assertEqual(imported_working.check_metadata(bound)["bl_status"], "PASS")

    def test_partial_working_archive_marks_missing_link_unverified(self):
        samples = self.table()
        libraries = self.project.register_metadata(
            self.csv("libraries.csv", "library,sample\nL1,001\n"), "acquisition", ["library"], authority="lab", reason="link",
            links=[{"ref": samples, "columns": ["sample"], "target_columns": ["sample"]}])
        raw = self.project.register_data(self.csv("raw.csv", "x\n1\n"), "input", hash=True)
        bound = self.project.bind_metadata(raw, [libraries], "attach")
        self.project.save()
        plan = self.project.preview_export("working", include=[libraries])
        archive = self.root / "partial.zip"; self.project.export_zip(plan, archive)
        imported = ProjectBundle.import_zip(archive, self.root / "partial-import")
        report = imported.check_metadata(bound, ["acquisition"])
        self.assertEqual(report["bl_status"], "UNKNOWN")
        self.assertIn("UNVERIFIED_LINK", [issue["bl_code"] for issue in report["bl_issues"]])

    def test_metadata_records_without_policy_fail_open(self):
        metadata = self.table()
        self.project.save()
        state_path = self.root / ".nb_project_bundle" / "project.json"
        state = json.loads(state_path.read_text(encoding="utf-8"))
        state["project"].pop("bl_metadata_policy")
        state_path.write_text(json.dumps(state), encoding="utf-8")
        with self.assertRaises(BundleError):
            ProjectBundle.open(self.root)


if __name__ == "__main__":
    unittest.main()
