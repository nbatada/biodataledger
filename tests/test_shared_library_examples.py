"""Execute installed-client examples and independently inspect their retained lineage."""
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from biodataledger import ProjectBundle

ROOT = Path(__file__).resolve().parents[1]
PYTHON_EXAMPLE = ROOT / "examples/shared_library_python.py"
R_EXAMPLE = ROOT / "examples/shared_library_R.R"


def python_module():
    spec = importlib.util.spec_from_file_location("shared_library_example", PYTHON_EXAMPLE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # Import must define functions without running the example.
    return module


class SharedLibraryExamplesTests(unittest.TestCase):
    def run_example(self, language, destination):
        command = ([sys.executable, str(PYTHON_EXAMPLE)] if language == "Python" else
                   ["Rscript", "--vanilla", str(R_EXAMPLE)])
        env = dict(os.environ)
        if language == "R":
            env["R_LIBS_USER"] = os.environ["BDL_R_LIB"]
        return subprocess.run(command + ["--destination", str(destination)],
                              capture_output=True, text=True, env=env, timeout=30)

    def check_workflow(self, language):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.run_example(language, Path(tmp) / "new-demo")
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            summary = json.loads(run.stdout)
            self.assertEqual(summary["function"], "nb_utils_general_check_columns")
            self.assertEqual(summary["results"], [["currency"], ["currency"]])
            self.assertEqual(summary["strict_error"], "Missing columns: currency")
            library = ProjectBundle.open(summary["library_root"])
            project = ProjectBundle.open(summary["analysis_root"])
            suffix = "py" if language == "Python" else "R"
            self.assertTrue((library.root / f"nb_utils_general.{suffix}").is_file())
            self.assertFalse((library.root / "R").exists())
            self.assertFalse((library.root / "python").exists())
            self.assertEqual([ref["revision"] for ref in summary["source_refs"]], [1, 2])
            self.assertEqual(summary["source_refs"][0]["id"], summary["source_refs"][1]["id"])
            snapshots = []
            for source, local, analysis, result in zip(
                    summary["source_refs"], summary["local_refs"],
                    summary["analysis_refs"], summary["result_refs"]):
                self.assertNotEqual(source["project_id"], local["project_id"])
                self.assertEqual(project.get_analysis(analysis).details["bl_helper_refs"], [local])
                output = project.get_data(ref=result)
                self.assertEqual(output.scope["transformation_ref"], analysis)
                self.assertEqual(json.loads(output.path.read_text()), ["currency"])
                self.assertEqual(hashlib.sha256(output.path.read_bytes()).hexdigest(), output.sha256)
                helper = project.get_helper(local, verify="snapshot")
                self.assertEqual(helper["foreign_refs"][0]["ref"], source)
                self.assertEqual(helper["verification"]["status"], "pass")
                snapshots.append(Path(helper["verification"]["files"][0]["path"]))
            self.assertEqual(project.get_data(ref=summary["result_refs"][0]).sha256,
                             summary["original_result_sha256"])
            self.assertNotEqual(snapshots[0].read_bytes(), snapshots[1].read_bytes())
            self.assertNotIn("strict", snapshots[0].read_text())
            self.assertIn("strict", snapshots[1].read_text())

            # A healthy mutable library is not a fallback for a damaged retained version.
            snapshots[0].write_text("stop('corrupt')" if language == "R" else "raise Exception('corrupt')")
            if language == "Python":
                with self.assertRaisesRegex(RuntimeError, "no working-file fallback"):
                    python_module().load_reviewed_snapshot(project, summary["local_refs"][0])
            else:
                rcode = '''a<-commandArgs(TRUE);e<-new.env();sys.source(a[[1]],envir=e)
                p<-ProjectBundle$open(a[[2]]);ref<-jsonlite::fromJSON(a[[3]],simplifyVector=FALSE)
                message<-tryCatch({e$load_reviewed_snapshot(p,ref);""},error=conditionMessage)
                stopifnot(grepl("no working-file fallback",message,fixed=TRUE))'''
                check = subprocess.run(
                    ["Rscript", "--vanilla", "-e", rcode, str(R_EXAMPLE), str(project.root),
                     json.dumps(summary["local_refs"][0])], capture_output=True, text=True,
                    env=dict(os.environ, R_LIBS_USER=os.environ["BDL_R_LIB"]), timeout=30)
                self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_python_workflow_and_no_mutable_fallback(self):
        self.check_workflow("Python")

    @unittest.skipUnless(os.environ.get("BDL_R_LIB"), "installed R library required")
    def test_r_workflow_and_no_mutable_fallback(self):
        self.check_workflow("R")

    def check_existing_destination(self, language):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sentinel = root / "existing.txt"
            sentinel.write_text("Keep existing work")
            before = sentinel.read_bytes(), sentinel.stat().st_mtime_ns
            run = self.run_example(language, root)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("Destination must be new", run.stderr)
            self.assertEqual((sentinel.read_bytes(), sentinel.stat().st_mtime_ns), before)
            self.assertEqual(list(root.iterdir()), [sentinel])

    def test_python_refuses_existing_destination(self):
        self.check_existing_destination("Python")

    @unittest.skipUnless(os.environ.get("BDL_R_LIB"), "installed R library required")
    def test_r_refuses_existing_destination(self):
        self.check_existing_destination("R")
