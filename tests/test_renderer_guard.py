"""Ordinary API renderer guard; synthetic inputs, installed native clients."""
from pathlib import Path
import copy
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle
from biodataledger.core import canonical, fingerprint, validate_state


class RendererGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "old.svg").write_text("<svg/>")
        self.p = ProjectBundle.create("Synthetic renderer guard", self.root)
        self.table = {"PC1": [1., 2., 3.], "PC2": [3., 1., 2.]}

    def test_strict_direct_registration_refused_without_mutation(self):
        self.p.require_approved_figures("retain approved renderer outputs")
        before = canonical(self.p.state)
        with self.assertRaisesRegex(BundleError, "APPROVED_RENDERER_REQUIRED.*render_figure"):
            self.p.register_figure("old.svg", "plot")
        self.assertEqual(before, canonical(self.p.state))

    def render(self, **kwargs):
        args = dict(renderer="pca", data=self.table, plot_args={"x": "PC1", "y": "PC2"},
                    width=2, height=2, dpi=72)
        args.update(kwargs)
        return self.p.render_figure(**args)

    def test_policy_is_opt_in_staged_enable_only_and_persisted(self):
        self.assertEqual(self.p.figure_policy(), "unrestricted")
        old = self.p.register_figure("old.svg", "plot")
        self.p.save_figure("old.svg", ref=old)
        self.p.save()
        self.p.require_approved_figures("native renderers")
        self.assertEqual(ProjectBundle.open(self.root).figure_policy(), "unrestricted")
        self.p.save()
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.figure_policy(), "approved_renderers_v1")
        self.assertNotIn("renderer_receipt", reopened.get_figure(old).details)
        before = canonical(reopened.state)
        reopened.require_approved_figures("already required")
        self.assertEqual(before, canonical(reopened.state))
        with self.assertRaises(BundleError):
            reopened.set_context({"figure_policy": None})
        for policy in (None, "unknown"):
            state = copy.deepcopy(reopened.state)
            state["project"]["figure_policy"] = policy
            with self.assertRaises(BundleError):
                validate_state(state)
        state = copy.deepcopy(reopened.state)
        state["schema_version"] = "0.3.0"
        with self.assertRaises(BundleError):
            validate_state(state)

    def test_direct_copy_and_scientific_corrections_refused(self):
        old = self.p.register_figure("old.svg", "plot")
        self.p.require_approved_figures("native renderers")
        before = canonical(self.p.state)
        for action in (lambda: self.p.save_figure("old.svg", "plot"),
                       lambda: self.p.save_figure("old.svg", ref=old),
                       lambda: self.p.update_record(old, {"path": "old.svg"}, "replace"),
                       lambda: self.p.update_record(old, {"params": {}}, "context"),
                       lambda: self.p.update_record(old, {"details": {"renderer_receipt": {}}}, "forge")):
            with self.subTest(action=action), self.assertRaisesRegex(BundleError, "APPROVED_RENDERER_REQUIRED"):
                action()
            self.assertEqual(before, canonical(self.p.state))
        self.assertFalse((self.root / ".nb_project_bundle/outputs").exists())
        revised = self.p.update_record(old, {"name": "Renamed", "status": "inactive"}, "presentation")
        self.assertEqual(self.p.get_figure(revised).name, "Renamed")

    def test_fresh_render_receipt_and_explicit_save(self):
        original = copy.deepcopy(self.table)
        self.p.require_approved_figures("native renderers")
        self.p.set_context({"next_task": "preserve pending work"})
        ref = self.render()
        figure = self.p.resolve_figure(ref, verify="sha256")
        receipt = figure.details["renderer_receipt"]
        self.assertEqual(receipt["output_sha256"], fingerprint(figure.path))
        self.assertEqual(receipt["renderer"], "pca")
        self.assertEqual(receipt["backend"], "matplotlib")
        self.assertEqual(receipt["panels"], [])
        self.assertEqual(receipt["scientific_acceptance"], "not_assessed")
        self.assertEqual(original, self.table)
        self.assertEqual(ProjectBundle.open(self.root).state["records"], [])
        self.assertTrue(self.p.unsaved)
        other = self.render(format="svg")
        self.assertNotEqual(figure.path, self.p.get_figure(other).path)
        self.p.save()
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.state["project"]["next_task"], "preserve pending work")
        self.assertEqual(reopened.get_figure(ref).details["renderer_receipt"], receipt)
        Path(figure.path).write_bytes(b"tamper")
        with self.assertRaisesRegex(BundleError, "SIZE_MISMATCH|DIGEST_MISMATCH"):
            reopened.resolve_figure(ref, verify="sha256")

    def test_nondefault_export_settings_persist_and_malformed_settings_reject(self):
        self.p.require_approved_figures("native renderers")
        ref = self.render(format="svg", width=3.5, height=2.25, dpi=144)
        expected = {"format": "svg", "width": 3.5, "height": 2.25, "units": "in", "dpi": 144}
        self.p.save()
        self.assertEqual(ProjectBundle.open(self.root).get_figure(ref).details["renderer_receipt"]["export_settings"], expected)
        for field, value in [("width", 0), ("height", 101), ("dpi", 2401), ("units", "cm"),
                             ("format", "png"), ("width", True)]:
            state = copy.deepcopy(self.p.state)
            state["records"][0]["details"]["renderer_receipt"]["export_settings"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(BundleError):
                validate_state(state)
        state = copy.deepcopy(self.p.state)
        state["records"][0]["details"]["renderer_receipt"]["export_settings"].update(width=100, height=100, dpi=2400)
        with self.assertRaises(BundleError):
            validate_state(state)
        state = copy.deepcopy(self.p.state)
        state["records"][0]["details"]["renderer_receipt"].pop("export_settings")
        with self.assertRaises(BundleError):
            validate_state(state)

    def test_first_failed_render_restores_absent_output_parent_and_preserves_existing(self):
        self.p.require_approved_figures("native renderers")
        self.p.set_context({"next_task": "pending"})
        before, files = canonical(self.p.state), set(self.root.rglob("*"))
        with self.assertRaisesRegex(ValueError, "missing column"):
            self.render(plot_args={"x": "missing", "y": "PC2"})
        self.assertEqual(before, canonical(self.p.state))
        self.assertEqual(files, set(self.root.rglob("*")))
        base = self.root / ".nb_project_bundle/outputs"
        base.mkdir()
        for keep_contents in (False, True):
            if keep_contents:
                (base / "keep.txt").write_text("preserve existing content")
            files = set(self.root.rglob("*"))
            with self.subTest(keep_contents=keep_contents), self.assertRaisesRegex(ValueError, "missing column"):
                self.render(plot_args={"x": "missing", "y": "PC2"})
            self.assertEqual(files, set(self.root.rglob("*")))
            self.assertEqual(before, canonical(self.p.state))

    def test_seven_fixed_renderers_and_declarative_composition(self):
        self.p.require_approved_figures("native renderers")
        cases = [
            ("umap_split", {**self.table, "batch": ["a", "b", "a"]}, {"x": "PC1", "y": "PC2", "split_by": "batch"}),
            ("violin_qc", {"g": ["a", "a", "b"], "v": [1., 2., 3.]}, {"group": "g", "value": "v", "value_label": "metric"}),
            ("group_comparison", {"g": ["a", "b"], "v": [1., 2.], "id": ["s1", "s2"]},
             {"group": "g", "value": "v", "value_label": "metric", "sample_id": "id", "observation_unit": "donor"}),
            ("heatmap", [[1., 2.], [3., 4.]], {"value_label": "prepared value", "row_labels": ["a", "b"], "column_labels": ["x", "y"]}),
            ("volcano", {"fc": [-2., 1., 3.], "p": [.01, .2, .001]},
             {"log2fc": "fc", "padj": "p", "contrast": "treated vs control", "lfc_threshold": 1, "padj_threshold": .05}),
            ("ma", {"fc": [-2., 1., 3.], "mean": [3., 10., 5.]},
             {"log2fc": "fc", "abundance": "mean", "contrast": "treated vs control", "abundance_scale": "linear"})]
        self.render()
        for renderer, data, args in cases:
            with self.subTest(renderer=renderer):
                ref = self.render(renderer=renderer, data=data, plot_args=args, format="pdf")
                self.assertEqual(self.p.get_figure(ref).details["renderer_receipt"]["renderer"], renderer)
        panels = [{"renderer": "pca", "data": self.table, "plot_args": {"x": "PC1", "y": "PC2"}},
                  {"renderer": "heatmap", "data": [[1., 2.]], "plot_args": {"value_label": "value", "row_labels": ["a"], "column_labels": ["x", "y"]}}]
        ref = self.render(renderer="compose", data=None, panels=panels, plot_args={"ncols": 2, "labels": ["a", "b"]})
        receipt = self.p.get_figure(ref).details["renderer_receipt"]
        self.assertEqual(len(receipt["panels"]), 2)
        self.assertNotIn("data", receipt["panels"][0])

    def test_invalid_specifications_and_objects_leave_state_and_files(self):
        from biodataledger import pl
        self.p.require_approved_figures("native renderers")
        ax = pl.plt.subplots()[1]
        self.addCleanup(lambda: pl.plt.close(ax.figure))
        before = canonical(self.p.state)
        invalid = [dict(renderer=lambda: None), dict(renderer="os.system"), dict(data=ax),
                   dict(plot_args={"x": "PC1", "y": "PC2", "ax": ax}),
                   dict(plot_args={"x": "PC1", "y": "PC2", "callback": lambda: None}),
                   dict(plot_args={"x": "PC1", "y": "PC2", "data": self.table}),
                   dict(plot_args={"x": "PC1", "y": "PC2", "filename": "injected.svg"}),
                   dict(renderer="compose", data=None, panels=[lambda ax: None], plot_args={}),
                   dict(renderer="compose", data=None, panels=[{"renderer": "umap_split", "data": self.table}], plot_args={}),
                   dict(width=100, height=100, dpi=2400), dict(dpi=float("nan")), dict(format="../file")]
        for args in invalid:
            with self.subTest(args=args), self.assertRaises(BundleError):
                self.render(**args)
            self.assertEqual(before, canonical(self.p.state))
        self.assertTrue(pl.plt.fignum_exists(ax.figure.number))
        self.assertFalse((self.root / ".nb_project_bundle/outputs").exists())

    def test_render_and_stage_failure_clean_only_new_files_preserving_pending(self):
        from biodataledger import pl
        self.p.require_approved_figures("native renderers")
        existing = self.render()
        kept = Path(self.p.get_figure(existing).path)
        (self.root / "pending.py").write_text("# pending source snapshot\n")
        self.p.register_analysis("Pending source", [], code="pending.py")
        self.p.set_context({"next_task": "pending"})
        before, snapshots = canonical(self.p.state), copy.deepcopy(self.p._snapshots)
        files = set(self.root.rglob("*"))
        for target in ("biodataledger.pl.pca", "biodataledger.core.ProjectBundle._stage"):
            with self.subTest(target=target), patch(target, autospec=True, side_effect=RuntimeError("synthetic failure")):
                with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                    self.render()
            self.assertEqual(before, canonical(self.p.state))
            self.assertEqual(self.p._snapshots, snapshots)
            self.assertTrue(self.p.unsaved)
            self.assertTrue(kept.exists())
            self.assertEqual(files, set(self.root.rglob("*")))
        self.assertEqual(pl.plt.get_fignums(), [])

    def test_receipts_reserved_immutable_validated_and_presentation_preserved(self):
        for call in (lambda: self.p.register_data("old.svg", "data", renderer_receipt={}),
                     lambda: self.p.register_analysis("analysis", [], renderer_receipt={}),
                     lambda: self.p.register_figure("old.svg", "plot", renderer_receipt={})):
            with self.assertRaises(BundleError):
                call()
        self.p.require_approved_figures("native renderers")
        ref = self.render()
        rec = self.p._record(ref)
        receipt = copy.deepcopy(rec["details"]["renderer_receipt"])
        for details in ({}, {**rec["details"], "renderer_receipt": {}}, {**rec["details"], "new_context": 3}):
            with self.assertRaises(BundleError):
                self.p.update_record(ref, {"details": details}, "alter")
        revised = self.p.set_presentation(ref, primary_topic="PCA", description="coordinates",
                                          generated_on="2026-11-13", reason="presentation")
        self.assertEqual(self.p.get_figure(revised).details["renderer_receipt"], receipt)
        for field, value in [("output_sha256", "0" * 64), ("scientific_acceptance", "approved"),
                             ("rendered_at", "2026-99-99T00:00:00Z"), ("panels", [{}])]:
            state = copy.deepcopy(self.p.state)
            state["records"][0]["details"]["renderer_receipt"][field] = value
            with self.subTest(field=field), self.assertRaises(BundleError):
                validate_state(state)

    def test_strict_external_rebind_requires_digest_and_size(self):
        # Historical external figures are not relabeled, but rebinding stays byte-identical.
        external = self.root.parent / (self.root.name + "-external.svg")
        external.write_text("<svg/>")
        self.addCleanup(lambda: external.unlink(missing_ok=True))
        ref = self.p.register_figure(external, "plot")
        self.p.require_approved_figures("native renderers")
        self.p.rebind_external(ref, self.root / "old.svg", "same bytes")
        before = canonical(self.p.state)
        for content in ("otherxx", "longer replacement"):
            (self.root / "replacement.svg").write_text(content)
            with self.assertRaisesRegex(BundleError, "APPROVED_RENDERER_REQUIRED"):
                self.p.rebind_external(ref, self.root / "replacement.svg", "different bytes")
            self.assertEqual(before, canonical(self.p.state))
        self.p._record(ref)["sha256"] = None
        with self.assertRaisesRegex(BundleError, "APPROVED_RENDERER_REQUIRED"):
            self.p.rebind_external(ref, self.root / "old.svg", "missing digest")

    def test_policy_and_receipt_survive_working_zip(self):
        self.p.require_approved_figures("native renderers")
        ref = self.render()
        self.p.save()
        archive = self.root / "working.zip"
        self.p.export_zip(self.p.preview_export("working", include=[ref]), archive)
        target = self.root / "imported"
        q = ProjectBundle.import_zip(archive, target)
        self.assertEqual(q.figure_policy(), "approved_renderers_v1")
        self.assertEqual(q.resolve_figure(ref, verify="sha256").details["renderer_receipt"],
                         self.p.get_figure(ref).details["renderer_receipt"])
        with self.assertRaisesRegex(BundleError, "APPROVED_RENDERER_REQUIRED"):
            q.save_figure(q.get_figure(ref).path, ref=ref)

    def test_execution_figure_auto_registration_uses_guard(self):
        (self.root / "run.py").write_text("from pathlib import Path\ndef make(inputs, params, seeds, outputs):\n    Path(outputs[0]).write_text('<svg/>')\n")
        analysis = self.p.register_analysis("synthetic callback", [], code="run.py")
        self.p.require_approved_figures("native renderers")
        with self.assertRaises(BundleError) as raised:
            self.p.run_analysis(analysis, "make", [{"kind": "figure", "path": "bypass.svg", "type": "plot"}])
        output = raised.exception.receipt["outputs"][0]
        self.assertEqual(output["status"], "registration_failed")
        self.assertIn("APPROVED_RENDERER_REQUIRED", output["error"])
        self.assertEqual(self.p.state["records"][-1]["kind"], "analysis")

    @unittest.skipUnless(os.environ.get("BDL_R_LIB"), "installed native R library required")
    def test_native_r_python_policy_receipt_and_zip_exchange(self):
        script = Path(__file__).with_name("r_renderer_guard_exchange.R")
        def r_call(action, root, *args):
            result = subprocess.run(["Rscript", "--vanilla", str(script), os.environ["BDL_R_LIB"], action,
                                     str(root), *map(str, args)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            return json.loads(result.stdout)
        self.p.require_approved_figures("native renderers")
        ref = self.render(renderer="compose", data=None,
                          panels=[{"renderer": "pca", "data": self.table,
                                   "plot_args": {"x": "PC1", "y": "PC2"}}], plot_args={"ncols": 1})
        self.p.save()
        report = r_call("append", self.root, ref["id"] + "@1")
        q = ProjectBundle.open(self.root)
        self.assertEqual(q.get_figure(report["figure"]).details["renderer_receipt"]["backend"], "ggplot2")
        self.assertEqual(q.get_figure(report["composition"]).details["renderer_receipt"]["panels"][0]["renderer"], "pca")
        self.assertEqual(q.get_figure(report["composition"]).details["renderer_receipt"]["export_settings"],
                         {"format": "png", "width": 2, "height": 2, "units": "in", "dpi": 72})
        other = self.root / "r-created"
        other.mkdir()
        made = r_call("create", other)
        created = ProjectBundle.open(other)
        self.assertEqual(created.figure_policy(), "approved_renderers_v1")
        self.assertEqual(created.resolve_figure(made["figure"], verify="sha256").details["renderer_receipt"]["backend"], "ggplot2")
        self.assertEqual(created.get_figure(made["composition"]).details["renderer_receipt"]["plot_args"], {"ncol": 1})
        archive = self.root / "r-exchange.zip"
        created.export_zip(created.preview_export("working", include=[made["figure"]]), archive)
        r_call("import", self.root / "r-imported", archive, made["figure"]["id"] + "@1")


if __name__ == "__main__":
    unittest.main()
