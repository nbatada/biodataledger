"""Synthetic native-client regression tests; no scientific acceptance."""
import copy
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from biodataledger import ProjectBundle, BundleError
from biodataledger.core import STATE_PATH, canonical, parse_json, validate_state
from biodataledger.archives import validate_zip


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "project"
        self.root.mkdir()
        (self.root / "NORTH_STAR.md").write_text("scientist-owned")
        (self.root / "data.csv").write_text("sample,value\ns1,1\ns2,2\n")
        (self.root / "qc.py").write_text("# Declared source; no proof of execution\nthreshold = 200\n")
        for name in ("library.svg", "genes.svg"):
            (self.root / name).write_text('<svg xmlns="http://www.w3.org/2000/svg"><text x="1" y="10">Synthetic QC</text></svg>')
        self.p = ProjectBundle.create("Synthetic", self.root)
        self.d = self.p.register_data("data.csv", "analysis_ready", hash=True, subset="hashed-plus-unassigned")
        self.p.set_current(self.d, "qc", "synthetic test selection")
        self.p.save()

    def retained(self):
        p = self.p
        a = p.register_analysis("QC", [self.d], code="qc.py", method="synthetic summary", params={"min_genes": 200}, unit="sample")
        f = p.register_figure("library.svg", "qc", analysis=a)
        g = p.register_figure("genes.svg", "qc", analysis=a)
        p.save()
        return a, f, g

    def test_primary_workflow_and_unknown(self):
        a, f, g = self.retained()
        q = ProjectBundle.open(self.root)
        rows = q.find_figures(type="qc")
        self.assertEqual(len(rows), 2)
        view = q.get_figure(f)
        self.assertEqual(view.inputs, [self.d])
        self.assertEqual(view.params, {"min_genes": 200})
        self.assertEqual(view.provenance, {"figure_file": "captured", "analytical": "declared", "execution": "unknown"})
        self.assertNotIn("file", view.analysis_details.get("provenance", {}))
        self.assertEqual(view.analysis_details["unit"], "sample")
        self.assertTrue(view.code_availability[0]["available"])
        legacy = q.register_figure("genes.svg", "clonality", name="T-cell clonality")
        q.save()
        self.assertIn("code", q.get_figure(legacy).unknown)
        self.assertEqual(q.find_figures("T-cell clonality")[0].ref, legacy)
        self.assertEqual((self.root / "NORTH_STAR.md").read_text(), "scientist-owned")

    def test_selector_never_replaces_approved_input(self):
        other = self.p.register_data("data.csv", "analysis_ready", subset="hashed-only")
        self.p.save()
        self.assertEqual(self.p.get_data(purpose="qc").ref, self.d)
        with self.assertRaisesRegex(BundleError, "ambiguous"):
            self.p.get_data(role="analysis_ready")
        os.unlink(self.root / "data.csv")
        view = self.p.get_data(purpose="qc")
        self.assertEqual(view.ref, self.d)
        self.assertFalse(view.available)
        self.p.set_context({"authorities": ["external-authority"]})
        with self.assertRaisesRegex(BundleError, "authority"):
            self.p.set_current(other, "qc", "attempt")

    def test_revision_and_cluster_run_identity(self):
        a = self.p.register_analysis("Leiden", [self.d], params={"resolution": .4})
        b = self.p.register_analysis("Leiden", [self.d], params={"resolution": .4})
        x = self.p.register_data("data.csv", "cluster", clustering_run=a, cluster="1")
        y = self.p.register_data("data.csv", "cluster", clustering_run=b, cluster="1")
        self.assertNotEqual(self.p.get_data(ref=x).details["clustering_run"], self.p.get_data(ref=y).details["clustering_run"])
        revised = self.p.update_record(self.d, {"name": "corrected name"}, "correction")
        self.assertEqual(revised["revision"], 2)
        self.assertEqual(self.p.get_data(purpose="qc").ref, self.d)
        self.p.save()

    def test_four_cohorts_and_modality_records(self):
        subsets = {"hashed-only": ["s1:c1"], "hashed-plus-unassigned": ["s1:c1", "s1:c2"],
                   "Vehicle + LowDose": ["s1:c1", "s2:c1"], "all-treatment": ["s1:c1", "s2:c1", "s3:c1"]}
        refs = []
        for index, (label, members) in enumerate(subsets.items()):
            path = self.root / ("membership-%s.csv" % index)
            path.write_text("cell_key\n" + "\n".join(members) + "\n")
            membership = self.p.register_data(path, "membership", hash=True)
            refs.append(self.p.register_data("data.csv", "analysis_ready", name=label, membership=membership, subset=label))
        self.p.save()
        q = ProjectBundle.open(self.root)
        self.assertEqual(len({ref["id"] for ref in refs}), 4)
        for ref, (label, members) in zip(refs, subsets.items()):
            record = q.get_data(ref=ref)
            self.assertEqual(record.details["subset"], label)
            member_record = q.get_data(ref=record.details["membership"])
            self.assertEqual(member_record.path.read_text().splitlines()[1:], members)
        bulk = q.register_analysis("bulk", [self.d], method="declared only", unit="mouse", denominator="sample reads", design="~ treatment")
        cells = q.register_analysis("single-cell", [refs[1]], layer="counts", unit="cell")
        spatial = q.register_data("library.svg", "spatial-image", coordinate_transform="declared identity")
        q.save()
        self.assertNotEqual(q._record(bulk)["details"]["unit"], q._record(cells)["details"]["unit"])
        self.assertEqual(q.get_data(ref=spatial).details["coordinate_transform"], "declared identity")

    def test_stale_writers_and_external_edit(self):
        q = ProjectBundle.open(self.root)
        self.p.set_context({"purpose": "first"})
        q.set_context({"purpose": "second"})
        self.p.save()
        with self.assertRaisesRegex(BundleError, "stale"):
            q.save()
        self.assertTrue(q.unsaved)
        p = ProjectBundle.open(self.root)
        p.set_context({"purpose": "third"})
        disk = json.loads((self.root / STATE_PATH).read_text())
        disk["project"]["name"] = "manual change"
        (self.root / STATE_PATH).write_text(json.dumps(disk))
        with self.assertRaisesRegex(BundleError, "stale"):
            p.save()

    def test_crash_before_replace_and_lock(self):
        old = (self.root / STATE_PATH).read_bytes()
        self.p.set_context({"purpose": "interrupted"})
        with patch("biodataledger.core.os.replace", side_effect=OSError("injected crash")):
            with self.assertRaises(OSError):
                self.p.save()
        self.assertEqual((self.root / STATE_PATH).read_bytes(), old)
        self.assertTrue(self.p.unsaved)
        lock = self.root / ".nb_project_bundle/write.lock"
        lock.mkdir()
        with self.assertRaisesRegex(BundleError, "lock"):
            self.p.save()
        self.assertTrue(lock.exists())

    def test_code_snapshot_is_recoverable_not_execution(self):
        _, f, _ = self.retained()
        (self.root / "qc.py").write_text("changed")
        view = self.p.get_figure(f)
        original = view.code_availability[0]["path"]
        self.assertIn("threshold = 200", original.read_text())
        self.assertEqual(view.analysis_details["provenance"]["analytical"], "declared")
        original.write_text("corrupt")
        self.assertTrue(any(r["status"] == "stale" for r in self.p.check(hashes=True)))
        with self.assertRaisesRegex(BundleError, "drift"):
            self.p.preview_export("working", [f])

    def test_malformed_and_shape(self):
        for raw in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{', b'{"x":9007199254740992}'):
            with self.assertRaises(BundleError):
                parse_json(raw)
        for mutate in (
            lambda s: s.update(schema_version="9"),
            lambda s: s.update(records={}),
            lambda s: s["records"].append(copy.deepcopy(s["records"][0])),
            lambda s: s["current"]["qc"].update(revision=99),
            lambda s: s["records"][0].update(params=[]),
        ):
            state = copy.deepcopy(self.p.state)
            mutate(state)
            with self.assertRaises(BundleError):
                validate_state(state)

    def test_no_eager_data_reads_and_getters_no_mkdir(self):
        huge = self.root / "large.h5ad"
        with huge.open("wb") as stream:
            stream.truncate(1024**3)
        with patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected data read")):
            q = ProjectBundle.open(self.root)
            ref = q.register_data("large.h5ad", "opaque")
            self.assertEqual(q.get_data(ref=ref).path, huge.resolve())
            out = q.get_output_dir("qc")
            self.assertFalse(out.exists())
        self.assertEqual(q.get_data(ref=ref).sha256, None)

    def test_working_and_context_import(self):
        _, f, g = self.retained()
        for mode, refs in (("context", None), ("working", [f, g, self.d])):
            plan = self.p.preview_export(mode, refs)
            target = self.base / (mode + ".zip")
            self.p.export_zip(plan, target)
            q = ProjectBundle.import_zip(target, self.base / mode)
            self.assertEqual(q.state["project"]["id"], self.p.state["project"]["id"])
            self.assertEqual(q.get_figure(f).params, {"min_genes": 200})
            self.assertEqual(q.get_figure(f).available, mode == "working")
            self.assertEqual(q.get_data(ref=self.d).available, mode == "working")
            self.assertEqual(q.get_figure(f).code_availability[0]["available"], mode == "working")
            with self.assertRaises(BundleError):
                ProjectBundle.import_zip(target, self.base / mode)

    def test_payload_change_and_preview_edit(self):
        _, f, _ = self.retained()
        plan = self.p.preview_export("working", [f])
        modified = copy.deepcopy(plan)
        modified["files"][0]["size"] += 1
        with self.assertRaisesRegex(BundleError, "plan"):
            self.p.export_zip(modified, self.base / "bad.zip")
        (self.root / "library.svg").write_text("changed")
        with self.assertRaisesRegex(BundleError, "changed"):
            self.p.export_zip(plan, self.base / "bad.zip")
        self.assertFalse((self.base / "bad.zip").exists())

    def test_unsafe_archive_inventory(self):
        for names in (("../evil",), ("/evil",), ("C:/evil",), ("a\\b",), ("A/x", "a/y"), ("x", "x/y"), ("x", "x")):
            path = self.base / "unsafe.zip"
            with zipfile.ZipFile(path, "w") as z:
                for name in names:
                    z.writestr(name, "bad")
            with self.assertRaises(BundleError):
                validate_zip(path)
        path = self.base / "symlink.zip"
        with zipfile.ZipFile(path, "w") as z:
            info = zipfile.ZipInfo("link")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, "../target")
        with self.assertRaisesRegex(BundleError, "regular"):
            validate_zip(path)

    def test_import_publishes_registry_last(self):
        _, f, _ = self.retained()
        z = self.base / "publication.zip"
        self.p.export_zip(self.p.preview_export("working", [f, self.d]), z)
        real_rename = os.rename
        def fail_payload(src, dst):
            if Path(src).name == "payload":
                raise OSError("injected payload publication failure")
            return real_rename(src, dst)
        dest = self.base / "partial"
        real_iterdir = Path.iterdir
        def sorted_entries(path):
            return iter(sorted(real_iterdir(path)))
        with patch("biodataledger.archives.os.rename", side_effect=fail_payload), patch.object(Path, "iterdir", sorted_entries):
            with self.assertRaises(BundleError):
                ProjectBundle.import_zip(z, dest)
        self.assertFalse((dest / STATE_PATH).exists())

    def test_unselected_external_is_missing_after_import(self):
        ext = self.base / "external.csv"
        ext.write_text("secret-data")
        ref = self.p.register_data(ext, "external")
        self.p.save()
        plan = self.p.preview_export("context")
        z = self.base / "context.zip"
        self.p.export_zip(plan, z)
        q = ProjectBundle.import_zip(z, self.base / "imported")
        self.assertFalse(q.get_data(ref=ref).available)
        q.rebind_external(ref, ext, "explicit local location")
        self.assertTrue(q.get_data(ref=ref).available)


if __name__ == "__main__":
    unittest.main()
