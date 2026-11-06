"""Focused tests of the installed native browser snapshot exporters."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2ZkAAAAASUVORK5CYII="
)
SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"><rect width="40" height="20" fill="#176b80"/></svg>'
ACTIVE_SVG = '<svg xmlns="http://www.w3.org/2000/svg"><script>globalThis.badPreview=true</script></svg>'
MARKUP = 'Synthetic é </template><script>globalThis.badMetadata=true</script>'


def read_snapshot(path):
    html = Path(path).read_text(encoding="utf-8")
    encoded = re.search(r'<template id="bdl-data">([A-Za-z0-9+/=]+)</template>', html)[1]
    return html, json.loads(base64.b64decode(encoded))


def synthetic_project(root):
    project = ProjectBundle.create(MARKUP, root, purpose="Inspect a synthetic sample")
    (root / "input.csv").write_text("sample\nS1\n")
    (root / "plot code.py").write_text("# scientific code contents marker\n")
    (root / "figure panel.png").write_bytes(PNG)
    (root / "static.svg").write_text(SVG)
    (root / "active.svg").write_text(ACTIVE_SVG)
    old = project.register_data("input.csv", "input", name=MARKUP)
    ana = project.register_analysis("Count samples", inputs=[old], code=["plot code.py"],
                                    method="Count sample rows", params={"threshold": 1.1234567890123457,
                                                                       "exact_integer": 9007199254740991})
    figure = project.register_figure("figure panel.png", "qc", analysis=ana,
                                     figure_sources={"rendering_inputs": [old], "relationship": "declared",
                                                     "generating_code": {"record": ana, "index": 0}})
    figure = project.set_presentation(
        figure, primary_topic="QC-samples", description="sample-counts", generated_on="2026-01-01",
        questions=["Which synthetic samples are included?"], title="Sample inclusion", subtitle="Synthetic display",
        uses=[{"kind": "slide", "document_id": "demo-deck", "item_id": "qc", "title": "Demo use"}],
        reason="Record synthetic display")
    new = project.update_record(old, {"name": "Current sample set"}, "Synthetic metadata correction")
    project.set_current(new, "review", "Use current exact reference")
    project.register_figure("static.svg", "qc", analysis=ana, name="Static vector preview")
    project.register_figure("active.svg", "qc", analysis=ana, name="Active vector preview")
    project.record_decision("Synthetic decision", "Display recorded decision metadata", targets=[ana])
    project.save()
    return project, old, new, ana, figure


@unittest.skipUnless(sys.platform == "darwin", "viewer writes currently require macOS")
class ViewerTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.project, self.old, self.new, self.ana, self.figure = synthetic_project(self.root)

    def run_r(self, source, *args):
        library = os.environ.get("BDL_R_LIB")
        if not library or not shutil.which("Rscript"):
            self.skipTest("installed native R client required")
        result = subprocess.run(["Rscript", "-e", source, str(self.root), *args],
                                env={**os.environ, "R_LIBS_USER": library}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_native_installed_payload_parity_and_r_default_path_persistence(self):
        preview_refs = ["FIG-001@2", "FIG-002@1", "FIG-003@1", "FIG-999@1"]
        py = self.project.view("python.html", open_browser=False, preview_refs=preview_refs)
        r_path = Path(self.run_r("""
            a <- commandArgs(TRUE)
            p <- BioDataLedger::ProjectBundle$open(a[[1L]])
            r <- p$view(open_browser = FALSE, preview_refs = a[-1L])
            cat(r$path)
        """, *preview_refs))
        self.addCleanup(shutil.rmtree, r_path.parent)
        self.assertEqual(stat.S_IMODE(r_path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(r_path.stat().st_mode), 0o600)
        _, r_data = read_snapshot(r_path)
        _, py_data = read_snapshot(py["path"])
        for field in ("client", "captured_at_utc"):
            py_data.pop(field)
            r_data.pop(field)
        self.assertEqual(py_data, r_data)

    def test_exact_history_current_metadata_and_caps(self):
        self.project.record_decision("x" * (18 * 1024), "Synthetic cap test", targets=[])
        report = self.project.view("full.html", open_browser=False)
        _, snapshot = read_snapshot(report["path"])
        records = snapshot["records"]
        self.assertTrue(snapshot["unsaved"])
        self.assertFalse(snapshot["imported"])
        self.assertEqual(snapshot["current"], [{"purpose": "review", "ref": self.new}])
        self.assertEqual([r["is_latest"] for r in records], sorted((r["is_latest"] for r in records), reverse=True))
        for latest in (True, False):
            slots = [record["stored_order"] for record in records if record["is_latest"] == latest]
            self.assertEqual(slots, sorted(slots, reverse=True))
        analysis = next(r for r in records if r["ref"] == self.ana)
        self.assertEqual(analysis["info"]["inputs"]["items"][0]["ref"], self.old)
        figure = next(r for r in records if r["ref"] == self.figure)
        self.assertEqual(figure["info"]["plotting_code"]["generating_code"]["selector"]["record"], self.ana)
        self.assertEqual(figure["info"]["rendering_inputs"]["items"][0]["ref"], self.old)
        self.assertEqual(figure["path"], str(self.root / "figure panel.png"))
        self.assertFalse(figure["info"]["availability_checked"])
        self.assertEqual(snapshot["coverage"]["omitted_card_details"], 1)
        self.assertIn("omission", next(r for r in records if r["name"] is None))
        limited = self.project.view("limited.html", open_browser=False, limit=3)
        _, snapshot = read_snapshot(limited["path"])
        self.assertEqual(snapshot["coverage"]["omitted_records"], len(records) - 3)
        self.assertEqual([r["ref"] for r in snapshot["records"]], [r["ref"] for r in records[:3]])
        self.assertEqual(snapshot["records"][0]["ref"]["id"], "DEC-002")
        self.assertNotIn(self.old, [r["ref"] for r in snapshot["records"]])
        self.assertEqual(snapshot["timelines"]["registration"]["omitted"], len(records) - 3)
        self.assertTrue(snapshot["timelines"]["registration"]["pages"][0]["has_more"])
        with patch("biodataledger.viewer._METADATA_BYTES", 6000):
            clipped = self.project.view("clipped.html", open_browser=False)
        self.assertTrue(clipped["coverage"]["byte_limit_hit"])

    def test_metadata_only_and_opt_in_preview_results(self):
        source = self.root / "figure panel.png"
        data = self.root / "input.csv"
        code = self.root / "plot code.py"
        registry = self.root / ".nb_project_bundle/project.json"
        original = registry.read_bytes()
        original_stat, original_open = Path.stat, Path.open

        def forbid_artifact_access(method):
            def access(path, *args, **kwargs):
                if path in (source, data, code, registry):
                    raise AssertionError("metadata-only export touched a registered file")
                return method(path, *args, **kwargs)
            return access

        with patch.object(Path, "stat", forbid_artifact_access(original_stat)), \
                patch.object(Path, "open", forbid_artifact_access(original_open)), \
                patch("biodataledger.viewer._read_preview", side_effect=AssertionError("unexpected preview read")):
            report = self.project.view("metadata.html", open_browser=False)
        self.assertEqual(report["preview_results"], {})
        self.assertEqual(registry.read_bytes(), original)
        source.write_bytes(b"changed")
        (self.root / "active.svg").unlink()
        (self.root / "unsupported.txt").write_text("ordinary text")
        unsupported = self.project.register_figure("unsupported.txt", "qc")
        (self.root / "big.png").write_bytes(PNG + b"\0" * (2 * 1024 * 1024))
        big = self.project.register_figure("big.png", "qc")
        (self.root / "budget.png").write_bytes(PNG + b"\0" * (2 * 1024 * 1024 - len(PNG)))
        budget_refs = [self.project.register_figure("budget.png", "qc") for _ in range(5)]
        report = self.project.view("with-previews.html", open_browser=False,
                                   preview_refs=[*budget_refs, self.figure, "FIG-003@1", unsupported, big, "FIG-999@1"])
        statuses = [x["status"] for x in report["preview_results"].values()]
        self.assertEqual(statuses, ["included"] * 4 + ["oversize", "oversize", "missing",
                                                      "oversize", "oversize", "unresolved"])
        report = self.project.view("diagnostics.html", open_browser=False,
                                   preview_refs=[self.figure, "FIG-002@1", unsupported, big])
        self.assertEqual([x["status"] for x in report["preview_results"].values()],
                         ["tampered", "included", "unsupported", "oversize"])
        _, payload = read_snapshot(report["path"])
        included = next(x for x in payload["previews"].values() if x["status"] == "included")
        self.assertEqual(base64.b64decode(included["base64"]), SVG.encode())
        self.assertEqual(included["digest"], hashlib.sha256(SVG.encode()).hexdigest())
        self.assertEqual(registry.read_bytes(), original)
        with self.assertRaisesRegex(BundleError, "exact FIG"):
            self.project.view("invalid.html", open_browser=False, preview_refs=["FIG-001"])

        # A foreign-style path accepted in the registry must never open from cwd.
        state = json.loads(original)
        figure = next(r for r in state["records"] if r["id"] == self.figure["id"]
                      and r["revision"] == self.figure["revision"])
        figure["locator"] = {"kind": "external", "value": r"C:\folder\outside.png"}
        registry.write_text(json.dumps(state))
        legacy = ProjectBundle.open(self.root)
        original_os_open = os.open

        def check_open(path, *args, **kwargs):
            self.assertNotEqual(str(path), figure["locator"]["value"])
            return original_os_open(path, *args, **kwargs)

        with patch("biodataledger.viewer.os.open", side_effect=check_open):
            report = legacy.view("foreign-path.html", open_browser=False, preview_refs=[self.figure])
        self.assertEqual(next(iter(report["preview_results"].values()))["status"], "unresolved")

    def test_exclusive_private_path_launch_failure_and_mutation_refusal(self):
        path = self.root / "blocked.html"
        path.write_text("original")
        with self.assertRaisesRegex(BundleError, "overwrite prohibited"):
            self.project.view(path, open_browser=False)
        self.assertEqual(path.read_text(), "original")
        path.unlink()
        path.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(BundleError, "overwrite prohibited"):
            self.project.view(path, open_browser=False)
        self.assertTrue(path.is_symlink())
        original_info = self.project.get_info

        def mutate(*args, **kwargs):
            self.project.set_context({"next_task": "Synthetic mutation during capture"})
            return original_info(*args, **kwargs)

        with patch.object(self.project, "get_info", side_effect=mutate):
            with self.assertRaisesRegex(BundleError, "changed during viewer export"):
                self.project.view("mutation.html", open_browser=False)
        self.assertFalse((self.root / "mutation.html").exists())
        with patch("biodataledger.viewer._launch", side_effect=OSError("synthetic failure")) as launch:
            report = self.project.view()
        private = Path(report["path"])
        self.addCleanup(shutil.rmtree, private.parent)
        launch.assert_called_once_with(private)
        self.assertEqual(stat.S_IMODE(private.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
        self.assertTrue(report["browser_open_requested"])
        self.assertIn("synthetic failure", report["launch_error"])
        if os.environ.get("BDL_R_LIB") and shutil.which("Rscript"):
            r_path = self.run_r("""
                p <- BioDataLedger::ProjectBundle$open(commandArgs(TRUE)[[1L]])
                overwrite <- tryCatch(p$view("blocked.html", open_browser = FALSE), error = conditionMessage)
                stopifnot(grepl("overwrite prohibited", overwrite))
                assignInNamespace(".viewer_launch", function(path) stop("synthetic failure"), "BioDataLedger")
                r <- p$view("r browser request.html")
                stopifnot(r$browser_open_requested, grepl("synthetic failure", r$launch_error))
                cat(r$path)
            """)
            self.assertTrue(path.is_symlink())
            self.assertEqual(Path(r_path), self.root / "r browser request.html")
            self.assertEqual(stat.S_IMODE(Path(r_path).stat().st_mode), 0o600)

    def test_metadata_is_encoded_and_csp_matches_installed_code(self):
        result = self.project.view("untrusted.html", open_browser=False, preview_refs=["FIG-003@1"])
        html, payload = read_snapshot(result["path"])
        self.assertNotIn(MARKUP, html)
        self.assertNotIn("badPreview", html)
        self.assertEqual(payload["project"]["name"], MARKUP)
        self.assertNotIn("scientific code contents marker", json.dumps(payload))
        for tag, ident in (("script", "bdl-app"), ("style", "bdl-style")):
            body = re.search(fr'<{tag} id="{ident}">(.*?)</{tag}>', html, re.S)[1]
            digest = base64.b64encode(hashlib.sha256(body.encode()).digest()).decode()
            self.assertIn(f"'sha256-{digest}'", html)
