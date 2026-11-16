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

    def run_r(self, source, *args, root=None):
        library = os.environ.get("BDL_R_LIB")
        if not library or not shutil.which("Rscript"):
            self.skipTest("installed native R client required")
        env = dict(os.environ)
        env["R_LIBS_USER"] = os.pathsep.join(filter(None, (library, env.get("R_LIBS_USER", ""))))
        result = subprocess.run(["Rscript", "-e", source, str(root or self.root), *args],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_native_r_child_prepends_selected_library_to_inherited_paths(self):
        captured = []

        def run(*args, **kwargs):
            captured.append(kwargs["env"])
            return subprocess.CompletedProcess(args[0], 0, "", "")

        with patch.dict(os.environ, {"BDL_R_LIB": "/selected", "R_LIBS_USER": "/first:/second"}), \
                patch("test_viewer.shutil.which", return_value="/usr/bin/Rscript"), \
                patch("test_viewer.subprocess.run", side_effect=run):
            self.run_r("invisible(NULL)")
        self.assertEqual(captured[0]["R_LIBS_USER"], os.pathsep.join(("/selected", "/first", "/second")))

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

    def test_analysis_log_capture_has_exact_links_and_no_payload_reads(self):
        registry = self.root / ".nb_project_bundle/project.json"
        original = registry.read_bytes()
        original_open = Path.open

        def deny_registered_payloads(path, *args, **kwargs):
            if path in (registry, self.root / "input.csv", self.root / "plot code.py", self.root / "figure panel.png"):
                raise AssertionError("analysis log must not read payloads")
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", deny_registered_payloads):
            report = self.project.view("analysis-log.html", open_browser=False)
        _, snapshot = read_snapshot(report["path"])
        rows = snapshot["timelines"]["analyses"]["pages"][0]["rows"]
        row = next(item for item in rows if item["ref"] == self.ana)
        self.assertEqual(row["time_source"], "registration")
        self.assertEqual(row["input_items"][0]["ref"], self.old)
        self.assertEqual(row["input_items"][0]["path"], str(self.root / "input.csv"))
        self.assertEqual(row["associated_figure_items"][0]["ref"],
                         {**self.figure, "revision": 1})
        self.assertEqual(row["associated_figure_items"][0]["revision_status"], "historical")
        self.assertEqual(row["output_items"], [])
        self.assertEqual(row["metadata_descriptors"], [])
        self.assertEqual(registry.read_bytes(), original)

    def test_dependencies_capture_graphs_and_exact_producing_run(self):
        output = self.root / "derived result.csv"
        (self.root / "dependency-run.py").write_text(
            "from pathlib import Path\n"
            "def synthetic_run(inputs, params, seeds, outputs):\n"
            "    Path(outputs[0]).write_text('sample,count\\nS1,1\\n')\n"
        )
        template = self.project.register_analysis("Make derived result", [self.new], code=["dependency-run.py"],
                                                  method="fixture", params={})
        receipt = self.project.run_analysis(template, "synthetic_run", [
            {"path": str(output), "kind": "result"}
        ], verify_inputs=False)
        result_ref = receipt["outputs"][0]["record_ref"]
        downstream = self.project.register_analysis("Summarise derived table", [result_ref],
                                                    method="declared synthetic", params={})
        (self.root / "downstream.csv").write_text("sample,summary\nS1,2\n")
        downstream_result = self.project.register_result("downstream.csv", downstream)
        self.project.save()
        report = self.project.view("dependencies.html", open_browser=False)
        _, snapshot = read_snapshot(report["path"])
        rows = [row for page in snapshot["timelines"]["analyses"]["pages"] for row in page["rows"]]
        row = next(item for item in rows if item["ref"] == receipt["receipt_ref"])
        dependencies = row["dependencies"]
        self.assertEqual(dependencies["selected_ref"], receipt["receipt_ref"])
        self.assertEqual(dependencies["anchor_ref"], receipt["run_ref"])
        self.assertEqual(dependencies["anchor"], "producing_run")
        for direction in ("upstream", "downstream"):
            graph = dependencies[direction]
            self.assertEqual(graph["direction"], direction)
            self.assertEqual(graph["depth"], 3)
            self.assertEqual(graph["limit"], 20)
            self.assertTrue(all(set(edge) >= {"from", "to", "type", "basis", "source_field"}
                                for edge in graph["edges"]))
            self.assertTrue(all("ref" in node and "unknown" in node for node in graph["nodes"]))
        self.assertTrue(any(edge["from"] == receipt["run_ref"] and edge["to"] == result_ref
                            for edge in dependencies["downstream"]["edges"]))
        self.assertTrue(any(edge["from"] == result_ref and edge["to"] == downstream
                            for edge in dependencies["downstream"]["edges"]))
        self.assertTrue(any(edge["from"] == downstream and edge["to"] == downstream_result
                            for edge in dependencies["downstream"]["edges"]))

        archive = self.root / "dependency-context.zip"
        self.project.export_zip(self.project.preview_export("context"), archive)
        imported = ProjectBundle.import_zip(archive, self.root / "dependency-import")
        imported_report = imported.view("dependencies-imported.html", open_browser=False)
        _, imported_snapshot = read_snapshot(imported_report["path"])
        imported_row = next(item for page in imported_snapshot["timelines"]["analyses"]["pages"] for item in page["rows"]
                            if item["ref"] == receipt["receipt_ref"])
        self.assertEqual(imported_row["evidence"], "untrusted_imported")
        self.assertEqual(imported_row["dependencies"]["anchor"], "untrusted_imported_run")
        self.assertEqual(imported_row["dependencies"]["anchor_ref"], receipt["run_ref"])
        self.assertTrue(any(edge["from"] == receipt["run_ref"] and edge["to"] == result_ref
                            for edge in imported_row["dependencies"]["downstream"]["edges"]))
        self.assertTrue(any(edge["to"] == downstream_result
                            for edge in imported_row["dependencies"]["downstream"]["edges"]))

        imported_r_path = self.run_r("""
            a <- commandArgs(TRUE)
            p <- BioDataLedger::ProjectBundle$open(a[[1L]])
            report <- p$view("dependencies-imported-r.html", open_browser = FALSE)
            cat(report$path)
        """, root=imported.root)
        _, imported_r_snapshot = read_snapshot(imported_r_path)
        imported_r_row = next(item for page in imported_r_snapshot["timelines"]["analyses"]["pages"] for item in page["rows"]
                              if item["ref"] == receipt["receipt_ref"])
        self.assertEqual(imported_row["dependencies"], imported_r_row["dependencies"])

        r_path = self.run_r("""
            a <- commandArgs(TRUE)
            p <- BioDataLedger::ProjectBundle$open(a[[1L]])
            report <- p$view("dependencies-r.html", open_browser = FALSE)
            cat(report$path)
        """)
        _, r_snapshot = read_snapshot(r_path)
        py_row = next(item for page in snapshot["timelines"]["analyses"]["pages"] for item in page["rows"]
                      if item["ref"] == receipt["receipt_ref"])
        r_row = next(item for page in r_snapshot["timelines"]["analyses"]["pages"] for item in page["rows"]
                     if item["ref"] == receipt["receipt_ref"])
        self.assertEqual(py_row["dependencies"], r_row["dependencies"])

    def test_analysis_log_uses_incremental_capture_budget(self):
        for index in range(30):
            self.project.register_analysis("Synthetic bounded log %02d" % index, [self.new], method="fixture", params={})
        with patch("biodataledger.viewer._ANALYSIS_LOG_BYTES", 1200):
            report = self.project.view("bounded-log.html", open_browser=False)
        _, snapshot = read_snapshot(report["path"])
        timeline = snapshot["timelines"]["analyses"]
        self.assertGreater(timeline["omitted"], 0)
        self.assertLess(sum(len(page["rows"]) for page in timeline["pages"]), 30)

    def test_analysis_log_bounds_metadata_descriptor_text_and_scan(self):
        metadata = self.root / "metadata.csv"
        metadata.write_text("sample,group\nS1,synthetic\n")
        descriptors = [self.project.register_metadata(
            "metadata.csv", "sample_preparation", ["sample"], authority="é" * 300,
            reason="Synthetic viewer bound", name="名" * 200) for _ in range(11)]
        bound = self.project.bind_metadata(self.ana, descriptors, "Synthetic descriptor scan")
        self.project.save()
        payloads = [Path(self.project.get_data(ref).path) for ref in descriptors]
        for path in payloads:
            self.assertTrue(path.is_file())
            path.unlink()
        # Missing table bytes must not affect either client's descriptor export.
        report = self.project.view("metadata-descriptors.html", open_browser=False)
        _, snapshot = read_snapshot(report["path"])
        row = next(item for page in snapshot["timelines"]["analyses"]["pages"] for item in page["rows"]
                   if item["ref"] == bound)
        self.assertEqual(len(row["metadata_descriptors"]), 10)
        self.assertTrue(row["metadata_descriptor_scan_truncated"])
        item = row["metadata_descriptors"][0]
        self.assertLessEqual(len(item["name"].encode("utf-8")), 256)
        self.assertLessEqual(len(item["authority"].encode("utf-8")), 256)
        self.assertIn("name", item["omitted_text_fields"])
        self.assertIn("authority", item["omitted_text_fields"])
        r_path = self.run_r("""
            a <- commandArgs(TRUE)
            p <- BioDataLedger::ProjectBundle$open(a[[1L]])
            report <- p$view("metadata-descriptors-r.html", open_browser = FALSE)
            cat(report$path)
        """)
        _, r_snapshot = read_snapshot(r_path)
        self.assertEqual(snapshot["timelines"]["analyses"], r_snapshot["timelines"]["analyses"])

    @unittest.skipUnless(shutil.which("node"), "Node is required for deterministic viewer date checks")
    def test_analysis_log_local_date_grouping(self):
        source = (Path(__file__).parents[1] / "shared" / "viewer.html").read_text()
        script = "function localDate" + source.split("function localDate", 1)[1].split("function logRecordLink", 1)[0]
        check = """
            const fs = require('fs');
            eval(fs.readFileSync(0, 'utf8'));
            const late = new Date('2026-01-01T07:59:00Z');
            const dst = new Date('2026-03-08T10:30:00Z');
            const result = {late: localDate(late.toISOString()), day: groupDate(late.toISOString(), 'day'),
              week: groupDate(late.toISOString(), 'week'), month: groupDate(late.toISOString(), 'month'),
              dst: groupDate(dst.toISOString(), 'day'), unknown: groupDate(null, 'day')};
            if (result.late !== '11.59pm, Dec 31, 2025' || result.day.key !== '2025-12-31' ||
                result.week.key !== '2025-12-29' || result.month.label !== 'December 2025' ||
                result.dst.key !== '2026-03-08' || result.unknown.key !== 'unknown') process.exit(1);
        """
        result = subprocess.run(["node", "-e", check], input=script, text=True, capture_output=True,
                                env={**os.environ, "TZ": "America/Los_Angeles"})
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node is required for deterministic file URL checks")
    def test_viewer_safe_file_urls(self):
        source = (Path(__file__).parents[1] / "shared" / "viewer.html").read_text()
        script = "function safeFileURL" + source.split("function safeFileURL", 1)[1].split("function fileActions", 1)[0]
        check = r"""
            const assert = require('assert');
            eval(require('fs').readFileSync(0, 'utf8'));
            assert.equal(safeFileURL('/tmp/a%20\\ #?.csv'), 'file:///tmp/a%2520%5C%20%23%3F.csv');
            assert.equal(safeFileURL('/tmp/é.csv'), 'file:///tmp/%C3%A9.csv');
            const literal = '/tmp/a%20\\ #?é.csv';
            assert.equal(decodeURIComponent(new URL(safeFileURL(literal)).pathname), literal);
            for (const value of ['relative.csv', '//server/share.csv', 'https://example.test/x',
                                 'javascript:alert(1)', 'data:text/plain,x', '/tmp/a\n.csv']) {
              assert.equal(safeFileURL(value), null, value);
            }
        """
        result = subprocess.run(["node", "-e", check], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node is required for deterministic dependency navigation checks")
    def test_dependency_return_restores_exact_analysis_page_and_focus(self):
        source = (Path(__file__).parents[1] / "shared" / "viewer.html").read_text()
        script = "function analysisLogGroups" + source.split("function analysisLogGroups", 1)[1].split("function showAnalysisLog", 1)[0]
        check = r"""
            const assert = require('assert');
            const row = {ref: {project_id: 'p', id: 'ANA-009', revision: 1}, time_utc: '2026-11-01T12:00:00Z'};
            const groups = Array.from({length: 9}, (_, index) => ({ref: {project_id: 'p', id: `ANA-${index + 101}`, revision: 1},
              time_utc: `2026-11-${String(index + 1).padStart(2, '0')}T12:00:00Z`}));
            groups[0] = row;
            const snapshot = {timelines: {analyses: {pages: [{rows: groups}]}}};
            const state = {analysisGrouping: 'day', analysisLogPage: 0, selected: null};
            const ANALYSIS_GROUPS_PER_PAGE = 8;
            const list = value => Array.isArray(value) ? value : [];
            const keyFor = ref => ref.project_id + '/' + ref.id + '@' + ref.revision;
            const groupDate = value => ({key: value.slice(0, 10), label: value.slice(0, 10)});
            const byKey = new Map([[keyFor(row.ref), {}]]);
            const shown = [];
            const rowElement = {dataset: {key: keyFor(row.ref)}, scrollIntoView() { this.scrolled = true; }, focus() { this.focused = true; }};
            const main = {querySelectorAll() { return [rowElement]; }};
            const showMode = mode => shown.push(mode);
            const selectRecord = key => { state.selected = key; };
            eval(require('fs').readFileSync(0, 'utf8'));
            returnToAnalysis(row);
            assert.equal(state.analysisLogPage, 1);
            assert.deepEqual(shown, ['analysis-log']);
            assert.equal(state.selected, keyFor(row.ref));
            assert(rowElement.scrolled && rowElement.focused);
        """
        result = subprocess.run(["node", "-e", check], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node is required for deterministic viewer navigation checks")
    def test_analysis_contents_search_jump_and_return(self):
        source = (Path(__file__).parents[1] / "shared" / "viewer.html").read_text()
        script = "function analysisContentsTop" + source.split("function analysisContentsTop", 1)[1].split("function showAnalysisLog", 1)[0]
        check = r"""
            const assert = require('assert');
            class Element {
              constructor(tag) { this.tag = tag; this.children = []; this.events = {}; }
              append(node) { this.children.push(node); }
              replaceChildren() { this.children = []; }
              setAttribute() {}
              addEventListener(event, action) { this.events[event] = action; }
              scrollIntoView() { this.scrolled = true; }
              focus() { this.focused = true; }
            }
            const walk = node => [node, ...node.children.flatMap(walk)];
            const main = new Element('main'), state = {analysisLogPage: 0};
            const ANALYSIS_GROUPS_PER_PAGE = 8, byKey = new Map([['ANA-009', {}]]);
            const row = new Element('tr'); row.dataset = {key: 'ANA-009'};
            main.querySelectorAll = () => [row];
            const byId = id => walk(main).find(node => node.id === id);
            const keyFor = ref => ref.id, localDate = value => value;
            let rendered, selected;
            const showMode = mode => { rendered = mode; };
            const selectRecord = key => { selected = key; };
            function add(parent, tag, text) {
              const node = new Element(tag); node.textContent = text; parent.append(node); return node;
            }
            function button(parent, text, action) {
              const node = add(parent, 'button', text); node.events.click = action; return node;
            }
            eval(require('fs').readFileSync(0, 'utf8'));
            const groups = Array.from({length: 9}, (_, i) => ({label: `Nov ${i+1}, 2026`, rows: [{
              name: `QC sample ${i+1}`, time_utc: `Nov ${i+1}, 2026`, ref: {id: `ANA-00${i+1}`}
            }]}));
            analysisContents(groups);
            let links = walk(main).filter(node => node.tag === 'button');
            assert.equal(links.length, 9);
            assert(links.every(node => node.textContent.startsWith('QC sample')));
            const search = byId('analysis-log-toc-search');
            search.value = 'Nov 9'; search.events.input();
            links = walk(main).filter(node => node.tag === 'button');
            assert.equal(links.length, 1); assert.equal(links[0].textContent, 'QC sample 9');
            links[0].events.click();
            assert.equal(state.analysisLogPage, 1); assert.equal(rendered, 'analysis-log');
            assert.equal(selected, 'ANA-009'); assert(row.focused && row.scrolled);
            analysisContentsTop();
            assert(byId('analysis-log-contents').focused && byId('analysis-log-contents').scrolled);
            search.value = 'QC sample 1'; search.events.input();
            assert.equal(walk(main).filter(node => node.tag === 'button').length, 1);
            search.value = 'no matching title'; search.events.input();
            assert(walk(main).some(node => node.textContent === 'No matching analysis in this snapshot.'));
            search.value = ''; search.events.input();
            assert.equal(walk(main).filter(node => node.tag === 'button').length, 9);
        """
        result = subprocess.run(["node", "-e", check], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

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
