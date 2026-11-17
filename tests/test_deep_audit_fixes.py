"""Focused regressions for the 2026-11-17 deep-audit corrections."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


class DeepAuditFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "input.txt").write_text("input\n")
        (self.root / "figure.svg").write_text("<svg/>\n")
        self.project = ProjectBundle.create("Search fixture", self.root)
        self.project.register_data("input.txt", "input")

    def test_legacy_and_compact_pages_preserve_search_order(self):
        refs = [self.project.register_figure("figure.svg", "plot", name="panel %02d" % index)
                for index in range(25)]
        self.assertEqual([item.ref for item in self.project.find_figures("panel")], refs)
        first = self.project.find_figures("panel", limit=20)
        second = self.project.find_figures("panel", limit=20, offset=first["next_offset"])
        self.assertEqual((first["matched"], first["returned"], first["omitted"]), (25, 20, 5))
        self.assertTrue(first["truncated"])
        self.assertEqual([item["ref"] for item in first["items"] + second["items"]], refs)
        self.assertIsNone(second["next_offset"])
        self.assertLessEqual(len(json.dumps(second, ensure_ascii=False, separators=(",", ":")).encode()), 4096)
        with self.assertRaisesRegex(BundleError, "offset requires"):
            self.project.find_figures(offset=1)

    def test_compact_page_clips_text_without_eager_figure_views(self):
        figure = self.project.register_figure("figure.svg", "é" * 200, name="γ" * 200)
        with patch.object(self.project, "get_figure", side_effect=AssertionError("eager view")):
            report = self.project.find_figures(limit=1)
        self.assertEqual(report["items"][0]["ref"], figure)
        self.assertLessEqual(len(report["items"][0]["name"].encode()), 128)
        self.assertLessEqual(len(report["items"][0]["type"].encode()), 64)
        self.assertTrue(report["truncated"])

    def test_byte_capped_pages_reach_every_eligible_figure(self):
        refs = [self.project.register_figure("figure.svg", "é" * 200, name="γ" * 200 + str(index))
                for index in range(25)]
        seen, offset = [], 0
        while offset is not None:
            page = self.project.find_figures(limit=20, offset=offset)
            self.assertLessEqual(len(json.dumps(page, ensure_ascii=False, separators=(",", ":")).encode()), 4096)
            seen.extend(item["ref"] for item in page["items"])
            offset = page["next_offset"]
        self.assertEqual(seen, refs)


    def test_empty_filtered_and_invalid_pages(self):
        first = self.project.register_figure("figure.svg", "QC", name="Alpha")
        self.project.register_figure("figure.svg", "other", name="Beta")
        page = self.project.find_figures("alpha", type="QC", limit=5)
        self.assertEqual(page["items"][0]["ref"], first)
        self.assertEqual((page["matched"], page["omitted"], page["truncated"]), (1, 0, False))
        self.assertIsNone(page["next_offset"])
        empty = self.project.find_figures("absent", limit=5)
        self.assertEqual((empty["items"], empty["matched"], empty["truncated"]), ([], 0, False))
        beyond = self.project.find_figures(limit=5, offset=10)
        self.assertEqual(beyond["items"], [])
        self.assertIsNone(beyond["next_offset"])
        for args in ({"limit": 0}, {"limit": 21}, {"limit": True},
                     {"limit": 1, "offset": -1}, {"limit": 1, "offset": False}):
            with self.subTest(args=args), self.assertRaises(BundleError):
                self.project.find_figures(**args)

    def test_code_snapshot_requires_a_digest(self):
        analysis = self.project.register_analysis("analysis", [])
        bad = {"locator": {"kind": "project", "value": "input.txt"},
               "sha256": None, "snapshot": ".nb_project_bundle/code/None"}
        with self.assertRaisesRegex(BundleError, "snapshot requires code digest"):
            self.project.update_record(analysis, {"code": [bad]}, "invalid snapshot")
        self.assertEqual(self.project.get_analysis(analysis).code, [])



class NativeSnapshotInteropTests(unittest.TestCase):
    def test_r_update_code_preserves_a_python_readable_snapshot(self):
        r_library = os.environ.get("BDL_R_LIB")
        if not r_library:
            self.skipTest("set BDL_R_LIB to an installed BioDataLedger R library")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "input.txt").write_text("input\n")
            (root / "old.R").write_text("old\n")
            (root / "new.R").write_text("new\n")
            project = ProjectBundle.create("R update", root)
            data = project.register_data("input.txt", "input")
            analysis = project.register_analysis("analysis", [data], code="old.R")
            (root / "figure.svg").write_text("<svg/>")
            for index in range(20):
                project.register_figure("figure.svg", "QC", name="γ" * 100 + str(index), analysis=analysis)
            project.save()
            script = r'''library(BioDataLedger, lib.loc = Sys.getenv("BDL_R_LIB")); library(digest)
p <- ProjectBundle$open(commandArgs(TRUE)[[1]])
h <- digest(file.path(commandArgs(TRUE)[[1]], "new.R"), algo = "sha256", serialize = FALSE, file = TRUE)
p$update_record(commandArgs(TRUE)[[2]], list(code = list(list(locator = list(kind = "project", value = "new.R"), sha256 = h, snapshot = paste0(".nb_project_bundle/code/", h)))), "replace code")
p$save()
jsonlite::write_json(p$find_figures(query="γ", limit=20L), file.path(commandArgs(TRUE)[[1]], "r-page.json"), auto_unbox=TRUE, null="null")'''
            result = subprocess.run(["Rscript", "--vanilla", "-", str(root), analysis["id"] + "@1"], input=script,
                                    text=True, capture_output=True, env={**os.environ, "BDL_R_LIB": r_library}, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            reopened = ProjectBundle.open(root)
            self.assertEqual(json.loads((root / "r-page.json").read_text()), reopened.find_figures(query="γ", limit=20))
            updated = reopened.get_analysis({"project_id": reopened.state["project"]["id"], "id": analysis["id"], "revision": 2})
            snapshot = root / updated.code[0]["snapshot"]
            self.assertEqual(snapshot.read_bytes(), b"new\n")
            self.assertEqual(reopened.get_analysis(analysis).code[0]["snapshot"], project.get_analysis(analysis).code[0]["snapshot"])


class OrdinaryReadBoundsTests(unittest.TestCase):
    def test_growth_rejects_without_unbounded_reads_or_staged_changes(self):
        import copy
        import hashlib
        from biodataledger.core import MAX_JSON, STATE_PATH
        for operation in ("open", "save", "register_code", "update_code", "preview", "export_start", "export_final"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve()
                project = ProjectBundle.create("bounded reads", root)
                source = root / "code.py"
                source.write_bytes(b"# x\n")
                analysis = project.register_analysis("pending source", inputs=[])
                project.save()
                descriptor = {"locator": {"kind": "project", "value": "code.py"},
                              "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
                descriptor["snapshot"] = ".nb_project_bundle/code/" + descriptor["sha256"]
                is_code = operation in ("register_code", "update_code")
                limit = 1024 * 1024 if is_code else MAX_JSON
                target = source if is_code else root / STATE_PATH
                if operation == "save":
                    project.set_context({"next_task": "preserve pending work"})
                plan = project.preview_export("context") if operation.startswith("export") else None
                before = copy.deepcopy(project.state), copy.deepcopy(project._snapshots), project.unsaved
                original = Path.open
                reads, opens = [], []
                selected_open = 2 if operation == "export_final" else 1
                grown = []

                def opened(path, *args, **kwargs):
                    stream = original(path, *args, **kwargs)
                    mode = args[0] if args else kwargs.get("mode", "r")
                    if path == target and mode == "rb":
                        opens.append(path)
                        selected = len(opens) == selected_open
                        read = stream.read

                        def grow_then_read(size=-1):
                            if selected and not grown:
                                with original(target, "wb") as writer:
                                    writer.write(b"x" * (limit + 4096))
                                grown.append(True)
                            data = read(size)
                            reads.append((size, len(data)))
                            return data
                        stream.read = grow_then_read
                    return stream

                actions = {
                    "open": lambda: ProjectBundle.open(root),
                    "save": project.save,
                    "register_code": lambda: project.register_analysis("new", inputs=[], code=source),
                    "update_code": lambda: project.update_record(analysis, {"code": [descriptor]}, "replace source"),
                    "preview": lambda: project.preview_export("context"),
                    "export_start": lambda: project.export_zip(plan, root / "out.zip"),
                    "export_final": lambda: project.export_zip(plan, root / "out.zip"),
                }
                with patch.object(Path, "open", opened):
                    with self.assertRaises(BundleError):
                        actions[operation]()
                self.assertTrue(grown, "growth hook did not execute")
                self.assertTrue(reads)
                self.assertTrue(all(0 <= requested <= limit + 1 and received <= limit + 1
                                    for requested, received in reads), reads)
                self.assertEqual((project.state, project._snapshots, project.unsaved), before)
                self.assertFalse((root / "out.zip").exists())
                self.assertFalse((root / ".nb_project_bundle/write.lock").exists())
