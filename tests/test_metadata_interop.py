"""Installed native metadata interchange, including selected archive payloads."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from biodataledger import ProjectBundle

SCRIPT = Path(__file__).with_name("r_metadata_exchange.R")


@unittest.skipUnless(os.environ.get("BDL_R_LIB") and shutil.which("Rscript"), "installed R client required")
class MetadataInteropTests(unittest.TestCase):
    def native(self, action, root, *args):
        result = subprocess.run(
            ["Rscript", "--vanilla", str(SCRIPT), os.environ["BDL_R_LIB"], action, str(root), *map(str, args)],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_python_created_metadata_is_read_and_checked_by_r(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "samples.csv").write_text("sample,patient,note\n001,Pα,NA\n", encoding="utf-8")
            p = ProjectBundle.create("Python metadata", root)
            ref = p.register_metadata("samples.csv", "sample_preparation", ["sample"],
                                      authority="Python", reason="source", required_columns=["patient"])
            p.save()
            native = self.native("inspect", root, json.dumps(ref))
            self.assertEqual(native["metadata"], p.get_metadata(ref))
            self.assertEqual(native["view"], p.metadata_view(ref))
            self.assertEqual(native["check"]["bl_status"], "PASS")
            revised = p.register_metadata("samples.csv", "sample_preparation", ["sample"],
                                          authority="Python", reason="revision", ref=ref)
            p.save()
            self.assertEqual(self.native("inspect", root, json.dumps(revised))["metadata"]["bl_reason"], "revision")

    def test_r_created_metadata_and_pinned_revision_are_read_by_python(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "r"
            refs = self.native("create", root)
            p = ProjectBundle.open(root)
            self.assertEqual(p.get_metadata(refs["samples"])["bl_rows"][0]["sample"], "001")
            self.assertEqual(p.check_metadata(refs["bound"])["bl_status"], "PASS")
            self.assertEqual(p.metadata_view(refs["bound"])["bl_categories"]["sample_preparation"][0]["bl_ref"], refs["samples"])
            # A correction written in Python remains readable in R and never changes the old bound ref.
            latest = p.register_metadata("samples.csv", "sample_preparation", ["sample"], authority="Python",
                                         reason="another explicit correction", ref=refs["samples_revision"])
            p.save()
            self.assertEqual(self.native("inspect", root, json.dumps(latest))["metadata"], p.get_metadata(latest))
            self.assertEqual(p.metadata_view(refs["bound"])["bl_categories"]["sample_preparation"][0]["bl_ref"], refs["samples"])

    def test_archives_are_checked_by_the_other_native_client(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "r"
            refs = self.native("create", root)
            include = [refs["samples"], refs["libraries"]]
            rzip = Path(tmp) / "r-working.zip"
            self.native("export", root, rzip, "working", json.dumps(include))
            imported = ProjectBundle.import_zip(rzip, Path(tmp) / "python-import")
            report = imported.check_metadata(refs["bound"])
            self.assertEqual(report["bl_status"], "PASS", report)

            p = ProjectBundle.open(root)
            working = Path(tmp) / "python-working.zip"
            p.export_zip(p.preview_export("working", include), working)
            native = self.native("import_check", Path(tmp) / "r-working", working, json.dumps(refs["bound"]))
            self.assertEqual(native["check"]["bl_status"], "PASS", native)
            self.assertEqual(native["view"], p.metadata_view(refs["bound"]))

            partial = Path(tmp) / "partial.zip"
            p.export_zip(p.preview_export("working", [refs["libraries"]]), partial)
            native = self.native("import_check", Path(tmp) / "r-partial", partial, json.dumps(refs["bound"]))
            self.assertEqual(native["check"]["bl_status"], "UNKNOWN")
            self.assertIn("UNVERIFIED_LINK", [x["bl_code"] for x in native["check"]["bl_issues"]])

            context = Path(tmp) / "context.zip"
            p.export_zip(p.preview_export("context"), context)
            native = self.native("import_check", Path(tmp) / "r-context", context, json.dumps(refs["bound"]))
            self.assertEqual(native["check"]["bl_status"], "UNKNOWN")

    def test_bom_and_single_column_single_row_remain_arrays(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "one.csv").write_text("\ufeffsample_id\n001\n", encoding="utf-8")
            p = ProjectBundle.create("Single row", root)
            ref = p.register_metadata("one.csv", "sample_preparation", ["sample_id"], authority="fixture", reason="BOM")
            p.save()
            native = self.native("inspect", root, json.dumps(ref))
            self.assertEqual(native["metadata"], p.get_metadata(ref))
            self.assertEqual(native["metadata"]["bl_rows"], [{"sample_id": "001"}])
            self.assertEqual(native["view"], p.metadata_view(ref))

    def test_optional_animal_ids_and_user_columns_survive_native_exchange(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            text = ("sample_id,mouse_id,sample_type,timepoint,tissue,sorted_population,cells_recovered\n"
                    "S001,M001,individual,before,blood,CD8,50000\n"
                    "S002,,pool,after,lymph_node,CD4_Treg,32000\n")
            (root / "samples.csv").write_text(text)
            p = ProjectBundle.create("Synthetic individual and pooled samples", root)
            ref = p.register_metadata("samples.csv", "sample_preparation", ["sample_id"],
                                      authority="Synthetic scientist sheet", reason="Keep supplied sample identities",
                                      units={"cells_recovered": "cells"})
            p.save()
            self.assertEqual(p.get_data(ref).role, "bl_metadata_table")
            table = p.get_metadata(ref)
            self.assertEqual(table["bl_rows"][1]["mouse_id"], "")
            self.assertEqual(table["bl_rows"][0]["cells_recovered"], "50000")
            self.assertNotIn("bl_mouse_id", table["bl_rows"][1])
            self.assertEqual(table["bl_units"], {"cells_recovered": "cells"})
            self.assertEqual(p.check_metadata(ref)["bl_status"], "PASS")
            native = self.native("inspect", root, json.dumps(ref))
            self.assertEqual(native["metadata"], table)
            self.assertEqual(native["check"]["bl_status"], "PASS")
