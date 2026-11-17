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
            self.assertEqual(len(summary["adoption_saves"]), 2)
            for receipt in summary["adoption_saves"]:
                self.assertEqual(receipt["status"], "persisted")
                self.assertTrue(receipt["registry_written"])
                self.assertEqual(receipt["scope"], "all_pending_changes")
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

    def test_python_alternate_names_and_library_location(self):
        """The personal flat nb_utils convention is not a package restriction."""
        with tempfile.TemporaryDirectory() as tmp:
            library_root = Path(tmp) / "team utilities"
            module = library_root / "src" / "table_ops.py"
            module.parent.mkdir(parents=True)
            module.write_text("def missing_fields(row, required):\n"
                              "    return [key for key in required if key not in row]\n")
            library = ProjectBundle.create("Team code", library_root)
            contract = dict(inputs="Dictionary", parameters="required field names",
                            outputs="Missing names", example="missing_fields(row, ['id'])",
                            limitations="Structural check only")
            source_ref = library.register_helper(
                "Field check", language="Python", purpose="Check required fields",
                source=module, function="missing_fields", contract=contract)
            library.save()
            project_root = Path(tmp) / "existing project"
            project_root.mkdir()
            project = ProjectBundle.create("Project", project_root)
            existing = project.record_decision("Existing note", "Preserve it", [])
            project.save()
            before = project.get_decision(existing)
            settings = {"shared_custom_library_folder": library_root}
            cards = project.find_helpers(
                "required fields", sources=[settings["shared_custom_library_folder"]])["helpers"]
            chosen = next(card for card in cards if card["ref"] == source_ref)
            self.assertEqual(library.get_helper(chosen["ref"])["descriptor"]["contract"], contract)
            local_ref = project.register_helper_from(chosen)
            self.assertNotEqual(project.get_helper(local_ref, verify="snapshot")["verification"]["status"], "pass")
            self.assertEqual(project.save_and_confirm()["status"], "persisted")
            retained = project.get_helper(local_ref, verify="snapshot")
            self.assertEqual(retained["verification"]["status"], "pass")
            path = Path(retained["verification"]["files"][0]["path"])
            namespace = {}
            exec(compile(path.read_text(), str(path), "exec"), namespace)
            self.assertEqual(namespace["missing_fields"]({"id": 1}, ["id", "value"]), ["value"])
            analysis = project.register_analysis("Alternate convention", [], helper_refs=[local_ref])
            project.save()
            reopened = ProjectBundle.open(project_root)
            self.assertEqual(reopened.get_analysis(analysis).details["bl_helper_refs"], [local_ref])
            self.assertEqual(reopened.get_helper(local_ref)["foreign_refs"][0]["ref"], source_ref)
            self.assertEqual(reopened.get_decision(existing), before)

    @unittest.skipUnless(os.environ.get("BDL_R_LIB"), "installed R library required")
    def test_r_alternate_names_and_library_location(self):
        with tempfile.TemporaryDirectory() as tmp:
            rcode = '''a<-commandArgs(TRUE);library(BioDataLedger)
            root<-normalizePath(a[[1]]);libroot<-file.path(root,"team utilities")
            dir.create(file.path(libroot,"src"),recursive=TRUE)
            module<-file.path(libroot,"src","table_ops.R")
            writeLines("missing_fields <- function(row, required) setdiff(required, names(row))",module)
            lib<-ProjectBundle$create("Team code",libroot)
            contract<-list(inputs="Named list",parameters="required fields",outputs="Missing names",
                           example="missing_fields(row, 'id')",limitations="Structural only")
            ref<-lib$register_helper("Field check",language="R",purpose="Check required fields",
                                    source=module,function_name="missing_fields",contract=contract)
            lib$save();dest<-file.path(root,"existing project");dir.create(dest)
            p<-ProjectBundle$create("Project",dest)
            old<-p$record_decision("Existing note","Preserve it",list());p$save()
            before<-p$get_decision(old)
            settings<-list(shared_custom_library_folder=libroot)
            cards<-p$find_helpers("required fields",sources=list(settings$shared_custom_library_folder))$helpers
            selected<-Filter(function(x)identical(x$ref,ref),cards)
            stopifnot(length(selected)==1L,identical(lib$get_helper(selected[[1]]$ref)$descriptor$contract,contract))
            local<-p$register_helper_from(selected[[1]])
            stopifnot(p$get_helper(local,verify="snapshot")$verification$status!="pass")
            receipt<-p$save_and_confirm();stopifnot(receipt$status=="persisted",receipt$registry_written)
            retained<-p$get_helper(local,verify="snapshot");stopifnot(retained$verification$status=="pass")
            helpers<-new.env(parent=baseenv());sys.source(retained$verification$files[[1]]$path,helpers)
            stopifnot(identical(helpers$missing_fields(list(id=1),c("id","value")),"value"))
            ana<-p$register_analysis("Alternate convention",list(),helper_refs=list(local));p$save()
            q<-ProjectBundle$open(dest)
            stopifnot(identical(q$get_analysis(ana)$details$bl_helper_refs,list(local)),
                      identical(q$get_helper(local)$foreign_refs[[1]]$ref,ref),
                      identical(q$get_decision(old),before))'''
            run = subprocess.run(["Rscript", "--vanilla", "-e", rcode, tmp],
                                 capture_output=True, text=True, timeout=30,
                                 env=dict(os.environ, R_LIBS_USER=os.environ["BDL_R_LIB"]))
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
