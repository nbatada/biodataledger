"""Installed-client migration, compact status and actual README examples."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import ProjectBundle, BundleError, __version__
from biodataledger.core import STATE_PATH, canonical
from create_fixtures import make_project
from test_interop import r_call, R_LIBRARY

BASE = Path(__file__).resolve().parents[1]


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_installed_identity_and_legacy_archives(self):
        self.assertEqual(__version__, "0.11.1")
        import biodataledger
        self.assertIn("site-packages", biodataledger.__file__)
        for mode in ("context", "working"):
            archive = BASE / "tests/legacy" / ("synthetic-" + mode + ".zip")
            before = hashlib.sha256(archive.read_bytes()).hexdigest()
            q = ProjectBundle.import_zip(archive, self.root / ("python-" + mode))
            self.assertEqual(q.get_figure("FIG-001@1", check_files=True).params, {"min_genes": 200})
            self.assertEqual(q.state["schema_version"], "0.1.0")
            self.assertEqual(q.get_figure("FIG-001@1", check_files=True).available, mode == "working")
            r_call("legacy", self.root / ("r-" + mode), archive, mode)
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), before)

    def test_legacy_registry_and_immutable_schema(self):
        project = self.root / "legacy"
        (project / ".nb_project_bundle").mkdir(parents=True)
        source = BASE / "tests/fixtures/with-provenance.json"
        shutil.copyfile(source, project / STATE_PATH)
        before = (project / STATE_PATH).read_bytes()
        p = ProjectBundle.open(project)
        self.assertEqual(p.get_data(purpose="qc", check_files=True).ref["id"], "DATA-001")
        self.assertEqual((project / STATE_PATH).read_bytes(), before)
        self.assertEqual((BASE / "schema/project.schema.json").read_bytes(),
                         (BASE / "python/src/biodataledger/project.schema.json").read_bytes())

    def test_compact_status_parity_bound_and_no_payload_reads(self):
        p, d, f, *_ = make_project(self.root / "status")
        large = p.root / "opaque.h5ad"
        with large.open("wb") as stream:
            stream.truncate(1024**3)
        p.register_data(large, "opaque")
        for i in range(8):
            p.set_current(d, "用途" + str(i) + "é" * 70, "synthetic purpose")
        p.set_context({"next_task": "漢字" * 500})
        p.save()
        before = (p.root / STATE_PATH).read_bytes()
        real_open = Path.open
        def guarded_open(path, *args, **kwargs):
            if path.suffix.lower() in (".h5ad", ".rds"):
                raise AssertionError("scientific payload read")
            return real_open(path, *args, **kwargs)
        with patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected hash")), patch.object(Path, "open", guarded_open), patch("os.scandir", side_effect=AssertionError("directory crawl")):
            loaded = ProjectBundle.open(p.root)
            status = loaded.status(check_files=True)
            self.assertTrue(loaded.get_data(purpose="qc", check_files=True).available)
            loaded.get_figure(f, check_files=True)
            out = loaded.get_output_dir("qc")
            self.assertFalse(out.exists())
        self.assertEqual((p.root / STATE_PATH).read_bytes(), before)
        self.assertLessEqual(len(canonical(status)), 4096)
        self.assertNotIn("history", status)
        self.assertIsNone(status["active_question"])
        self.assertTrue(status["truncated"]["text"])
        native = json.loads(r_call("status", p.root).stdout)
        self.assertEqual(native, status)
        p.set_context({"next_task": "unsaved"})
        self.assertTrue(p.status(check_files=True)["unsaved"])

    def test_status_checks_pinned_current_revision_after_new_version(self):
        p, d, *_ = make_project(self.root / "pinned")
        (p.root / "replacement.csv").write_text("sample,genes\nS1,999\n")
        p.update_record(d, {"path": "replacement.csv"}, "new retained version, not a current-pointer change")
        p.save()
        (p.root / "input.csv").unlink()
        status = p.status(check_files=True)
        self.assertTrue(any(item["ref"] == d for item in status["missing"]["items"]))
        self.assertEqual(json.loads(r_call("status", p.root).stdout), status)

    def test_status_missing_candidates_are_bounded(self):
        folder = self.root / "many"
        folder.mkdir()
        p = ProjectBundle.create("Synthetic candidate cap", folder)
        for i in range(105):
            path = folder / ("file%03d.csv" % i)
            path.write_text("synthetic")
            p.register_data(path, "input")
            path.unlink()
        p.save()
        s = p.status(check_files=True)
        self.assertEqual(s["missing"]["checked"], 100)
        self.assertEqual(s["missing"]["unchecked"], 5)
        self.assertEqual(s["missing"]["found"], 100)
        self.assertEqual(s["truncated"]["missing"], 95)
        self.assertEqual(json.loads(r_call("status", folder).stdout), s)

    def test_synthetic_prmt5_four_inputs_and_metric(self):
        folder = self.root / "prmt5-synthetic"
        folder.mkdir()
        p = ProjectBundle.create("PRMT5 (synthetic)", folder)
        refs = []
        for i, label in enumerate(("hashed-only", "hashed-plus-unassigned", "Vehicle + LowDose", "all-treatment")):
            path = folder / ("dataset-%s.csv" % i)
            path.write_text("cell_key\n" + "\n".join("synthetic-%s" % j for j in range(i + 1)))
            refs.append(p.register_data(path, "analysis_ready", name=label, hash=True))
        p.set_current(refs[1], "qc", "explicit synthetic scientist choice")
        p.save()
        self.assertEqual(p.get_data(purpose="qc", check_files=True).ref, refs[1])
        with self.assertRaises(BundleError):
            p.get_data(role="analysis_ready", check_files=True)
        status = p.status(check_files=True)
        metric = {"fixture": "PRMT5 synthetic four distinct registered datasets; one current-purpose pointer", "status_utf8_bytes": len(canonical(status)), "full_state_utf8_bytes": len(canonical(p.state)), "byte_target": 4096, "token_count": None, "token_note": "No tokenizer installed; exact UTF-8 bytes are the reproducible bound, not a universal token claim."}
        self.assertLessEqual(metric["status_utf8_bytes"], metric["byte_target"])
        if os.environ.get("BDL_METRICS_PATH"):
            Path(os.environ["BDL_METRICS_PATH"]).write_text(json.dumps(metric, indent=2) + "\n")

    def test_readme_python_examples_installed(self):
        blocks = re.findall(r"```python\n(.*?)```", (BASE / "README.md").read_text(), re.S)
        self.assertEqual(len(blocks), 3)
        folder = self.root / "python-readme"
        shutil.copytree(BASE / "examples/input-files", folder)
        scope = {"project_root": folder, "archive_path": self.root / "python-readme.zip", "import_root": self.root / "python-import"}
        with contextlib.redirect_stdout(io.StringIO()):
            for block in blocks:
                exec(compile(block, "README.md", "exec"), scope)
        self.assertEqual(scope["q"].get_figure(scope["f1"], check_files=True).params, {"min_genes": 200})
        self.assertEqual(len(scope["q"].find_figures(type="qc")), 2)

    def test_readme_r_examples_installed(self):
        # Installation is verified separately from the usage examples.
        examples = (BASE / "README.md").read_text().split("## Record data, analyses and figures", 1)[1]
        blocks = re.findall(r"```r\n(.*?)```", examples, re.S)
        self.assertEqual(len(blocks), 3)
        folder = self.root / "r-readme"
        shutil.copytree(BASE / "examples/input-files", folder)
        script = self.root / "readme.R"
        prelude = '.libPaths(c(Sys.getenv("BDL_R_LIB"), .libPaths()))\nproject_root <- Sys.getenv("BDL_README_ROOT")\narchive_path <- Sys.getenv("BDL_README_ZIP")\nimport_root <- Sys.getenv("BDL_README_IMPORT")\n'
        script.write_text(prelude + "\n".join(blocks) + '\nstopifnot(q$get_figure(f1)$params$min_genes == 200)\n')
        env = dict(os.environ, BDL_R_LIB=R_LIBRARY, BDL_README_ROOT=str(folder), BDL_README_ZIP=str(self.root / "r-readme.zip"), BDL_README_IMPORT=str(self.root / "r-import"))
        result = subprocess.run(["Rscript", "--vanilla", str(script)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "r-import" / STATE_PATH).is_file())


if __name__ == "__main__":
    unittest.main()
