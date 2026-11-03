"""Synthetic declared-layout recovery through the existing working ZIP."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from biodataledger import ProjectBundle

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / "examples"))
from recovery_python import preview_recovery, apply_recovery


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        root = self.base / "source"
        root.mkdir()
        (root / "input.csv").write_text("sample,value\nS1,1\n")
        (root / "helper.py").write_text("VALUE = 1\n")
        (root / "plot.py").write_text("import helper\n")
        (root / "figure.svg").write_text("<svg/>\n")
        p = ProjectBundle.create("Recovery fixture", root)
        d = p.register_data("input.csv", "input", hash=True)
        a = p.register_analysis("plot", [d], code=["plot.py", "helper.py"], method="synthetic", params={})
        f = p.register_figure("figure.svg", "plot", analysis=a)
        files = []
        for source, dest, purpose in [({"kind": "record", "ref": d}, "data/input.csv", "input"),
                                      ({"kind": "record", "ref": f}, "results/figure.svg", "output")]:
            path = root / Path(dest).name
            files.append(dict(source=source, destination=dest, sha256=sha(path), size=path.stat().st_size, purpose=purpose))
        for name in ("plot.py", "helper.py"):
            path = root / name
            code = next(x for x in p.get_analysis(a).code if x["locator"]["value"] == name)
            files.append(dict(source={"kind": "code", "analysis_ref": a, "locator": code["locator"], "sha256": code["sha256"]},
                              destination="scripts/" + name, sha256=sha(path), size=path.stat().st_size, purpose="declared code"))
        manifest = dict(version="biodataledger-recovery/1", figure_ref=f, files=files, entrypoint="scripts/plot.py",
                        working_directory=".", import_roots=["scripts"], external_requirements=["Python runtime version unknown"])
        (root / "recovery.json").write_text(json.dumps(manifest))
        m = p.register_data("recovery.json", "recovery_manifest", hash=True)
        p.save()
        archive = self.base / "working.zip"
        p.export_zip(p.preview_export("working", [d, f, m]), archive)
        self.imported_root = self.base / "imported"
        self.project = ProjectBundle.import_zip(archive, self.imported_root)
        self.manifest = manifest
        self.state_before = (self.imported_root / ".nb_project_bundle/project.json").read_bytes()

    def test_preview_apply_and_unchanged_registry(self):
        preview = preview_recovery(self.project, self.manifest)
        result = apply_recovery(self.project, self.manifest, self.base / "restored", preview)
        self.assertEqual(result["entrypoint"], "scripts/plot.py")
        for item in self.manifest["files"]:
            self.assertEqual(sha(self.base / "restored" / item["destination"]), item["sha256"])
        self.assertEqual((self.imported_root / ".nb_project_bundle/project.json").read_bytes(), self.state_before)
        self.assertTrue(self.project.get_data(ref=self.manifest["files"][0]["source"]["ref"]).path.exists())

    def test_refusals_leave_no_tree_or_registry_change(self):
        preview = preview_recovery(self.project, self.manifest)
        cases = []
        def variant(change):
            copy = json.loads(json.dumps(self.manifest))
            change(copy)
            cases.append(copy)
        variant(lambda x: x["files"][1].update(destination="../escape"))
        variant(lambda x: x["files"][1].update(destination="DATA/input.csv"))
        variant(lambda x: x["files"][1].update(destination="data/input.csv"))
        variant(lambda x: x["files"][1].update(destination="Data/input.csv"))
        variant(lambda x: x["files"][1].update(destination="é/input.csv"))
        variant(lambda x: x["files"][0].update(destination="e\u0301/input.csv"))
        variant(lambda x: x["files"][1].update(destination="data"))
        variant(lambda x: x["files"][1].update(sha256="0" * 64))
        variant(lambda x: x["files"].pop())
        for i, bad in enumerate(cases):
            with self.subTest(i=i), self.assertRaises(ValueError):
                apply_recovery(self.project, bad, self.base / ("bad" + str(i)), preview)
            self.assertFalse((self.base / ("bad" + str(i))).exists())
        output = self.base / "exists"
        output.mkdir()
        with self.assertRaises(ValueError):
            apply_recovery(self.project, self.manifest, output, preview)
        self.assertEqual((self.imported_root / ".nb_project_bundle/project.json").read_bytes(), self.state_before)

    def test_manifest_parser_and_ancestor_collisions(self):
        source = self.project.get_data(ref=self.manifest["files"][0]["source"]["ref"]).path
        manifest_path = self.base / "manifest.json"
        valid = json.dumps(self.manifest)
        for payload in (valid.replace('"version":', '"version": "wrong", "version":', 1),
                        valid.replace('"size":', '"extra": NaN, "size":', 1)):
            manifest_path.write_text(payload)
            with self.assertRaises(ValueError):
                preview_recovery(self.project, manifest_path)
        with manifest_path.open("wb") as stream:
            stream.truncate(20 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, "20 MiB"):
            preview_recovery(self.project, manifest_path)
        for parent in ("A", "é"):
            bad = json.loads(valid)
            bad["files"][0]["destination"] = parent + "/input.csv"
            bad["files"][1]["destination"] = ("a" if parent == "A" else "e\u0301") + "/figure.svg"
            with self.assertRaisesRegex(ValueError, "ancestor collision"):
                preview_recovery(self.project, bad)
        bad = json.loads(valid)
        bad["files"][2]["source"]["analysis_ref"]["id"] = "ANA-999"
        with self.assertRaisesRegex(ValueError, "target figure"):
            preview_recovery(self.project, bad)
        self.assertTrue(source.exists())

    def test_missing_corrupt_and_symlink_source(self):
        source = Path(self.project.get_data(ref=self.manifest["files"][0]["source"]["ref"]).path)
        original = source.read_bytes()
        source.unlink()
        with self.assertRaises(ValueError):
            preview_recovery(self.project, self.manifest)
        source.write_bytes(b"X" * len(original))
        with self.assertRaises(ValueError):
            preview_recovery(self.project, self.manifest)
        source.unlink()
        other = self.base / "other.csv"
        other.write_bytes(original)
        source.symlink_to(other)
        with self.assertRaises(ValueError):
            preview_recovery(self.project, self.manifest)
        self.assertEqual((self.imported_root / ".nb_project_bundle/project.json").read_bytes(), self.state_before)

    def test_r_helper_same_imported_project(self):
        script = BASE / "tests/recovery_R.R"
        if not shutil.which("Rscript"):
            self.skipTest("Rscript unavailable")
        library = os.environ.get("BDL_R_LIB")
        env = dict(os.environ)
        if library:
            env["R_LIBS_USER"] = os.pathsep.join(filter(None, (library, env.get("R_LIBS_USER"))))
        probe = subprocess.run(["Rscript", "--vanilla", "-e", "quit(status=if (requireNamespace('BioDataLedger', quietly=TRUE)) 0 else 1)"], env=env, capture_output=True)
        if probe.returncode:
            self.skipTest("BioDataLedger R package not installed")
        result = subprocess.run(["Rscript", "--vanilla", str(script), str(self.imported_root),
                                 str(self.base / "r-restored")], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for item in self.manifest["files"]:
            self.assertEqual(sha(self.base / "r-restored" / item["destination"]), item["sha256"])
        self.assertEqual((self.imported_root / ".nb_project_bundle/project.json").read_bytes(), self.state_before)


if __name__ == "__main__":
    unittest.main()
