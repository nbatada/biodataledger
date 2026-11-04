"""Synthetic tests for the project-local retained-input example helpers."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


SPEC = importlib.util.spec_from_file_location(
    "retained_input_example", Path(__file__).resolve().parents[1] / "examples" / "retained_input.py")
EXAMPLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXAMPLE)


class RetainedInputExampleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, content in {"first.csv": "first\n", "second.csv": "second\n", "plot.svg": "<svg/>\n", "redraw.py": "# declared source\n"}.items():
            (self.root / name).write_text(content)
        self.project = ProjectBundle.create("synthetic retained input", self.root)
        self.first = self.project.register_data("first.csv", "input", hash=True)
        self.second = self.project.register_data("second.csv", "input", hash=True)
        self.project.set_current(self.first, "redraw", "synthetic selected input")
        self.project.save()

    def test_pointer_move_after_load_keeps_original_reference_for_registration(self):
        obj, source = EXAMPLE.load_retained_input(self.project, lambda path: path.read_text(), purpose="redraw")
        self.project.set_current(self.second, "redraw", "synthetic later choice")
        retained = EXAMPLE.register_redraw(self.project, source, name="synthetic redraw",
            figure_path="plot.svg", figure_type="plot", code="redraw.py", method="synthetic", params={})
        self.assertEqual(obj, "first\n")
        self.assertEqual(self.project.get_analysis(retained["analysis"]).inputs, [self.first])
        self.assertEqual(retained["source"].ref, self.first)
        figure = self.project.get_figure(retained["figure"])
        self.assertEqual(figure.rendering_inputs, [self.first])
        self.assertEqual(figure.rendering_relationship, "declared")

    def test_selected_job_loads_only_its_input(self):
        touched = []
        obj, source = EXAMPLE.load_selected_redraw_input(self.project,
            {"first": {"ref": self.first}, "second": {"ref": self.second}}, "second",
            lambda path: touched.append(path.name) or path.read_text())
        self.assertEqual((obj, source.ref, touched), ("second\n", self.second, ["second.csv"]))

    def test_missing_conflicting_and_missing_file_selectors_fail_before_loader(self):
        called = []
        loader = lambda path: called.append(path) or path.read_text()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            EXAMPLE.load_retained_input(self.project, loader)
        with self.assertRaisesRegex(ValueError, "exactly one"):
            EXAMPLE.load_retained_input(self.project, loader, ref=self.first, purpose="redraw")
        (self.root / "first.csv").unlink()
        with self.assertRaisesRegex(BundleError, "MISSING_FILE"):
            EXAMPLE.load_retained_input(self.project, loader, ref=self.first)
        self.assertEqual(called, [])

    def test_sourcing_example_performs_no_project_action(self):
        spec = importlib.util.spec_from_file_location("retained_input_inert", SPEC.origin)
        module = importlib.util.module_from_spec(spec)
        with patch.object(ProjectBundle, "create", side_effect=AssertionError("create called")), \
             patch.object(ProjectBundle, "open", side_effect=AssertionError("open called")):
            spec.loader.exec_module(module)
        self.assertEqual(sorted(name for name in vars(module) if not name.startswith("_")),
                         ["load_retained_input", "load_selected_redraw_input", "register_redraw"])

    def test_native_r_helper(self):
        library = os.environ.get("BDL_R_LIB")
        if not library:
            self.skipTest("set BDL_R_LIB to run the installed native R helper test")
        env = dict(os.environ, BDL_REPO_ROOT=str(Path(__file__).resolve().parents[1]))
        env["R_LIBS_USER"] = os.pathsep.join(filter(None, (library, env.get("R_LIBS_USER", ""))))
        result = subprocess.run(["Rscript", "--vanilla", str(Path(__file__).with_name("r_retained_input.R"))],
                                env=env, capture_output=True, text=True, timeout=30)
        if result.returncode:
            self.fail("native R retained-input helper failed: " + result.stderr + result.stdout)
