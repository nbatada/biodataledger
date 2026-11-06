"""Installed-client coverage of semantic naming, navigation and verified copies."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle


PRESENTATION = "biodataledger.presentation"
GENERATION = "2026-11-05"
USES = [
    {"kind": "slide", "document_id": "deck-2026", "item_id": "slide-qc",
     "title": "Échantillons by donor"},
    {"kind": "manuscript", "document_id": "draft-2026", "item_id": "panel-clones",
     "title": "Clonality across donors"},
]


class OutputDiscoveryTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.project = ProjectBundle.create("Synthetic output discovery", self.root)
        (self.root / "samples.csv").write_text("sample\nS1\nS2\n")
        (self.root / "panel.svg").write_text("<svg>original</svg>")
        self.export_dir = self.root / "copies"
        self.export_dir.mkdir()

    def tag(self, ref, **kwargs):
        return self.project.set_presentation(ref, **{
            "primary_topic": "QC-samples", "description": "umap-by-donor", "generated_on": GENERATION,
            "reason": "Record the supplied display labels", **kwargs,
        })

    def test_facets_multiple_uses_and_exact_recorded_lineage(self):
        p = self.project
        parent = p.register_data("samples.csv", "input", hash=True)
        child = p.register_data("samples.csv", "subset", parent=parent)
        (self.root / "qc.py").write_text("# Synthetic analytical code\n")
        plot_code = b"# Synthetic rendering code\n"
        (self.root / "plot.py").write_bytes(plot_code)
        script_ref = p.register_data("plot.py", "plotting-script", hash=True)
        a = p.register_analysis("Donor view", [child, parent], method="declared method", params={"seed": 7},
                                code=["qc.py", "plot.py"])
        raw = p.register_result("samples.csv", a, hash=True)
        result = self.tag(raw, primary_topic="QC-filtering", description="selected-samples")
        f = p.register_figure("panel.svg", "umap", analysis=a,
                              figure_sources={"rendering_inputs": [result], "relationship": "declared",
                                              "generating_code": {"record": a, "index": 1, "registered_ref": script_ref}})
        tagged = self.tag(f, topics=["CLONALITY", "qc-samples"], questions=["Échantillons par donneur ?", "Which clones persist?"],
                          uses=USES, title="Donor view", subtitle="Subset as supplied")
        boundary = p.register_figure("panel.svg", "other", analysis=a)
        boundary_tagged = self.tag(boundary, primary_topic="QCness")
        page = p.find_outputs(topic="qc", limit=1)
        self.assertEqual([x["ref"] for x in page["items"]], [result])
        self.assertEqual((page["total"], page["next_offset"], page["truncated"]), (2, 1, True))
        page = p.find_outputs(topic="QC", offset=1, limit=1)
        self.assertEqual([x["ref"] for x in page["items"]], [tagged])
        self.assertIsNone(page["next_offset"])
        self.assertTrue(page["truncated"])
        matches = p.find_outputs(topic="clonality", question="ÉCHANTILLONS", query="clones donor",
                                 kind="FIG", document_id="deck-2026")
        self.assertEqual([x["ref"] for x in matches["items"]], [tagged])
        self.assertEqual(matches["items"][0]["presentation"]["uses"], USES)
        self.assertEqual(matches["items"][0]["presentation"]["topics"], ["QC-samples", "CLONALITY"])
        self.assertEqual(p.find_outputs(document_id="DECK-2026")["total"], 0)
        with patch.object(p, "_resolve", side_effect=AssertionError("unexpected path resolution")), \
                patch.object(Path, "stat", side_effect=AssertionError("unexpected stat")), \
                patch.object(Path, "open", side_effect=AssertionError("unexpected read")):
            view = p.get_info("F001r2", limit=1)
        self.assertEqual(view["producer_ref"], a)
        self.assertEqual(view["producer"]["name"], "Donor view")
        self.assertEqual(view["producer"]["ref"], a)
        self.assertEqual([x["ref"] for x in view["inputs"]["items"]], [child])
        self.assertEqual(view["inputs"]["items"][0]["kind"], "data")
        self.assertEqual(view["inputs"]["next_offset"], 1)
        self.assertEqual(p.get_info(tagged, limit=1, offset=1)["inputs"]["items"][0]["ref"], parent)
        self.assertEqual(view["analytical_source"]["params"], {"seed": 7})
        self.assertEqual([x["ref"] for x in view["rendering_inputs"]["items"]], [result])
        self.assertEqual(view["rendering_inputs"]["relationship"], "declared")
        plotting = view["plotting_code"]
        self.assertEqual(plotting["status"], "declared")
        self.assertEqual(plotting["candidates"]["next_offset"], 1)
        code = plotting["generating_code"]
        self.assertEqual(code["selector"], {"record": a, "index": 1, "registered_ref": script_ref,
                                            "sha256": hashlib.sha256(plot_code).hexdigest()})
        self.assertEqual(code["snapshot"], ".nb_project_bundle/code/" + code["sha256"])
        self.assertEqual(code["locator"], {"kind": "project", "value": "plot.py"})
        self.assertFalse(code["availability_checked"])
        unknown = p.get_info(boundary)["plotting_code"]
        self.assertEqual(unknown["status"], "unknown")
        self.assertIsNone(unknown["generating_code"])
        self.assertEqual(unknown["candidates"]["total"], 2)
        self.assertFalse(view["availability_checked"])
        self.assertEqual(p.get_info(child)["record"]["details"]["parent"], parent)
        self.assertIsNone(p.get_info(child)["producer_ref"])
        self.assertEqual(p.get_info("A001r1")["presentation_status"], "not_applicable")
        outputs = p.get_info(a)["outputs"]["items"]
        self.assertEqual([e["to"] for e in outputs], [raw, result, f, tagged, boundary, boundary_tagged])
        self.assertEqual([e["type"] for e in outputs[:3]],
                         ["produced_result", "produced_result", "analytical_association"])
        self.assertEqual(outputs[2]["output"]["ref"], f)
        self.assertEqual(outputs[2]["output"]["name"], "panel")
        large = p.register_analysis("Large parameters", [parent], params={"declared": "x" * 20000})
        compact = p.get_info(large)
        self.assertIsNone(compact["record"])
        self.assertIsNone(compact["analytical_source"])
        self.assertEqual(compact["record_fields_status"], "size_limit")
        self.assertEqual(compact["analytical_source_status"], "size_limit")
        self.assertEqual(compact["analytical_source_ref"], large)
        self.assertEqual(compact["inputs"]["items"][0]["ref"], parent)
        self.assertEqual(len(p.get_analysis(large).params["declared"]), 20000)

    def test_naming_is_exact_safe_and_metadata_only(self):
        p = self.project
        (self.root / "coordinates.tar.gz").write_bytes(b"opaque")
        raw = p.register_data("coordinates.tar.gz", "archive", keep={"assay": "RNA", "fields": [1, None]})
        with self.assertRaisesRegex(BundleError, "missing"):
            p.output_name(raw)
        for changes in [
            {"generated_on": "2026-02-29"}, {"generated_on": "2026-1-01"}, {"generated_on": "0000-01-01"},
            {"primary_topic": "../QC"}, {"primary_topic": "QC_samples"}, {"description": "résumé"},
            {"description": "line\n"}, {"questions": [" " * 4]}, {"uses": [{**USES[0], "file_path": "/no"}]},
        ]:
            with self.assertRaises(BundleError):
                self.tag(raw, **changes)
        tagged = self.tag(raw, generated_on="2024-02-29", uses=USES)
        self.assertEqual(self.tag(tagged, generated_on="2024-02-29", uses=USES), tagged)
        revised = self.tag(tagged, generated_on="2024-02-29", primary_topic="CLONALITY")
        self.assertEqual(p.output_name(revised)["uses"], USES)
        cleared = self.tag(revised, generated_on="2024-02-29", primary_topic="CLONALITY", uses=[])
        self.assertEqual(p.output_name(cleared)["uses"], [])
        with self.assertRaisesRegex(BundleError, "latest exact"):
            self.tag(tagged)
        self.assertEqual(p.get_data(ref=revised).details["keep"], {"assay": "RNA", "fields": [1, None]})
        wrong_project = {**tagged, "project_id": "11111111-1111-4111-8111-111111111111"}
        with self.assertRaises(BundleError):
            p.output_name(wrong_project)
        self.assertEqual(p.find_outputs(document_id="deck-2026")["total"], 0)
        self.assertEqual([x["ref"] for x in p.find_outputs(document_id="deck-2026", historical=True)["items"]],
                         [revised, tagged])
        self.assertEqual(p.get_info(raw)["presentation_status"], "missing")
        (self.root / "coordinates.tar.gz").unlink()
        with patch.object(p, "_resolve", side_effect=AssertionError("unexpected path resolution")), \
                patch.object(Path, "stat", side_effect=AssertionError("unexpected stat")), \
                patch.object(Path, "open", side_effect=AssertionError("unexpected read")):
            self.assertEqual(p.output_name("D001r2")["filename"], "20240229_QC-samples_D001r2_umap-by-donor.tar.gz")
            self.assertEqual(p.output_name(revised)["tag"], "CLONALITY:D001r3")
            self.assertEqual(p.find_outputs(topic="clonality")["total"], 1)
            self.assertEqual(p.get_info("DATA-001@3")["ref"], revised)
        (self.root / "no-extension").write_text("opaque")
        no_ext = self.tag(p.register_data("no-extension", "artifact"))
        with self.assertRaisesRegex(BundleError, "extension"):
            p.output_name(no_ext)
        remote = self.tag(p.register_data("https://example.org/file.csv", "remote"))
        with self.assertRaisesRegex(BundleError, "local"):
            p.output_name(remote)
        for block, status in [({"version": "future/7"}, "unsupported"),
                              ({"version": "biodataledger-presentation/1", "primary_topic": "QC"}, "invalid")]:
            legacy = p.register_data("no-extension", "artifact", **{PRESENTATION: block})
            self.assertEqual(p.get_info(legacy)["presentation_status"], status)
            with self.assertRaisesRegex(BundleError, status):
                p.output_name(legacy)
        self.assertEqual(p.find_outputs(topic="QC", historical=True)["presentation_status_counts"]["unsupported"], 1)

    def test_verified_export_collision_tamper_and_rerun(self):
        p = self.project
        old = self.tag(p.save_figure("panel.svg", "umap"))
        (self.root / "panel.svg").write_text("<svg>rerun</svg>")
        rerun = p.save_figure("panel.svg", ref=old)
        with self.assertRaisesRegex(BundleError, "missing"):
            p.output_name(rerun)
        new = self.tag(rerun)
        p.save()
        registry = self.root / ".nb_project_bundle" / "project.json"
        before = registry.read_bytes()
        named = p.output_name(old)
        target = self.export_dir / named["filename"]
        target.symlink_to("missing")
        with self.assertRaisesRegex(BundleError, "exists"):
            p.export_named_output(old, self.export_dir)
        self.assertTrue(target.is_symlink())
        target.unlink()
        result = p.export_named_output("F001r2", self.export_dir)
        self.assertEqual(result["ref"], old)
        self.assertEqual(target.read_text(), "<svg>original</svg>")
        self.assertEqual(result["sha256"], hashlib.sha256(target.read_bytes()).hexdigest())
        self.assertEqual(result["integrity"], "match")
        with self.assertRaisesRegex(BundleError, "exists"):
            p.export_named_output(old, self.export_dir)
        copied = p.export_named_output(new, self.export_dir)
        self.assertNotEqual(copied["filename"], named["filename"])
        self.assertEqual(Path(copied["path"]).read_text(), "<svg>rerun</svg>")
        self.assertEqual(registry.read_bytes(), before)
        self.assertFalse(p.unsaved)
        self.assertEqual(len(list(self.export_dir.iterdir())), 2)
        data = self.tag(p.register_data("samples.csv", "artifact", hash=True))
        (self.root / "samples.csv").write_text("sample\nT1\nT2\n")  # Same size, different bytes.
        with self.assertRaisesRegex(BundleError, "DIGEST_MISMATCH"):
            p.export_named_output(data, self.export_dir)
        self.assertEqual(len(list(self.export_dir.iterdir())), 2)
        new_data = p.update_record(data, {"path": "samples.csv"}, "Record a different file revision")
        with self.assertRaisesRegex(BundleError, "missing"):
            p.output_name(new_data)
        unhashed = self.tag(p.register_data("samples.csv", "artifact"))
        with self.assertRaisesRegex(BundleError, "MISSING_DIGEST"):
            p.export_named_output(unhashed, self.export_dir)

    def test_presentation_only_update_keeps_existing_membership_guard(self):
        p = self.project
        member = p.register_data("samples.csv", "membership", hash=True)
        subject = p.register_data("samples.csv", "input", hash=True, membership=member, label={"one": True})
        sha = p.get_data(ref=subject).sha256
        report = {"report_version": "biodataledger-membership-check/1", "subject_sha256": sha,
                  "membership_ref": member, "membership_sha256": sha, "key_columns": ["sample"],
                  "key_namespace": "synthetic", "comparison": "ordered_keys", "result": "match",
                  "checked_at": "2026-11-05T12:00:00Z",
                  "checker": {"method": "Synthetic identical input", "origin": "native_check", "analysis_ref": None},
                  "counts": {"subject_rows": 2, "membership_rows": 2, "subject_duplicate_keys": 0,
                             "membership_duplicate_keys": 0, "missing_keys": 0, "extra_keys": 0}}
        (self.root / "membership.json").write_text(json.dumps(report))
        evidence = p.register_data("membership.json", "membership_report", hash=True)
        d = p.set_data_scope(subject, {"membership_evidence": {"status": "verification_recorded",
                                                             "report_ref": evidence}}, "Bind synthetic report")
        with patch.object(p, "_verify_file", side_effect=AssertionError("unexpected payload verification")):
            tagged = self.tag(d)
        old, new = p.get_data(ref=d), p.get_data(ref=tagged)
        self.assertEqual((old.scope, old.sha256, old.locator), (new.scope, new.sha256, new.locator))
        desc = new.details.pop(PRESENTATION)
        self.assertEqual(old.details, new.details)
        with self.assertRaisesRegex(BundleError, "membership"):
            p.update_record(tagged, {"details": {**new.details, PRESENTATION: desc, "label": {"one": 1}}},
                            "Different type inside unrelated metadata")
        with self.assertRaisesRegex(BundleError, "membership"):
            p.update_record(tagged, {"path": "samples.csv"}, "Change a protected path")
        self.assertEqual(p.resolve_data(ref=tagged, verify="sha256", require_membership=True).verification["membership"],
                         "verified_against_recorded_evidence")

    def test_installed_native_roundtrip_and_legacy_preservation(self):
        if not os.environ.get("BDL_R_LIB"):
            self.skipTest("Set BDL_R_LIB to the installed BioDataLedger library")
        p = self.project
        d = p.register_data("samples.csv", "input", hash=True, legacy={"items": ["γδ", None]})
        (self.root / "plot.R").write_text("# Synthetic rendering code\n")
        a = p.register_analysis("Donor view", [d], method="Declared", params={"seed": 5}, code="plot.R")
        result = self.tag(p.register_result("samples.csv", a, hash=True), questions=["Quelle est la diversité γδ ?"],
                          uses=USES, title="Diversité γδ")
        figure = p.save_figure("panel.svg", "umap", analysis=a,
                               figure_sources={"rendering_inputs": [result], "relationship": "declared",
                                               "generating_code": {"record": a, "index": 0}})
        large = p.register_analysis("Large parameters", [d], params={"declared": "x" * 20000})
        p.save()
        script = Path(__file__).with_name("r_output_discovery_exchange.R")

        def invoke(action):
            completed = subprocess.run(["Rscript", "--vanilla", str(script), action, str(self.root)],
                                       capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            return json.loads(completed.stdout)

        r = invoke("write")
        p = ProjectBundle.open(self.root)
        self.project = p
        self.assertEqual(p.get_data(ref=d).details["legacy"], {"items": ["γδ", None]})
        self.assertEqual(p.get_info(figure)["presentation_status"], "missing")
        self.assertEqual(r["python_name"], p.output_name(result))
        self.assertEqual(r["r_name"], p.output_name(r["ref"]))
        self.assertEqual(r["r_info"], p.get_info(r["ref"]))
        self.assertEqual(r["analysis_info"], p.get_info(a, limit=1, offset=1))
        self.assertEqual(r["large_info"], p.get_info(large))
        self.assertEqual(r["qc"], p.find_outputs(topic="qc", historical=True))
        self.assertEqual(r["by_question"], p.find_outputs(question="DIVERSITÉ γδ", document_id="deck-2026"))
        self.assertEqual(r["export"]["ref"], r["ref"])
        self.assertEqual(Path(r["export"]["path"]).read_text(), "<svg>original</svg>")
        changed = self.tag(r["ref"], primary_topic="CLONALITY", description="new-presentation")
        p.save()
        fresh = invoke("read")
        self.assertEqual(fresh["latest"], p.output_name(changed))
        self.assertEqual(fresh["older"], p.output_name(r["ref"]))
        self.assertEqual(fresh["clonality"], p.find_outputs(topic="clonality"))


if __name__ == "__main__":
    unittest.main()
