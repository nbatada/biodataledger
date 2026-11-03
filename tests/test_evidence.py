"""Declared relationships never establish that an analysis actually executed."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import ProjectBundle
from biodataledger.core import STATE_PATH, canonical


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "input.csv").write_text("sample,value\nS1,1\n")
        (self.root / "plot.py").write_text("# Declared source only.\n")
        (self.root / "figure.svg").write_text("<svg>synthetic</svg>")
        self.p = ProjectBundle.create("Synthetic evidence", self.root)
        self.d = self.p.register_data("input.csv", "input", hash=True)
        self.a = self.p.register_analysis("Declared", [self.d], code="plot.py",
                                          method="synthetic", params={"n": 1})
        self.f = self.p.register_figure("figure.svg", "plot", analysis=self.a)
        self.p.save()

    def test_complete_declarations_still_lack_execution_evidence(self):
        view = self.p.get_figure(self.f)
        self.assertEqual(view.evidence, {
            "input_relationships": "declared", "code_relationships": "declared",
            "execution": "unknown", "execution_evidence": "not_captured",
            "missing": ["execution_evidence"]})
        self.assertEqual(view.unknown, ["execution_evidence"])
        self.assertEqual(self.p.get_analysis(self.a).evidence, view.evidence)
        verified = self.p.resolve_figure(self.f, verify="sha256")
        self.assertEqual(verified.verification["file_integrity"], "match")
        self.assertEqual(verified.evidence, view.evidence)
        self.assertEqual(verified.provenance["execution"], "unknown")
        expected = {"execution": "unknown", "execution_evidence": "not_captured",
                    "missing": ["execution_evidence"]}
        self.assertEqual(self.p.status()["evidence"], expected)
        self.assertEqual(self.p.summary()["evidence"], expected)
        self.assertIn("Execution evidence: not captured by registry.", self.p.summary_text())

    def test_legacy_claims_are_unverified_and_queries_preserve_bytes(self):
        raw = copy.deepcopy(self.p.state)
        for record in raw["records"]:
            if record["id"] == self.a["id"]:
                record["details"]["provenance"] = {"analytical": "observed", "execution": "observed"}
                record["details"]["execution_evidence"] = {"status": "observed", "actor": "caller"}
            if record["id"] == self.f["id"]:
                record["details"]["provenance"] = {"file": "verified_execution"}
        path = self.root / STATE_PATH
        path.write_bytes(canonical(raw))
        before = path.read_bytes()
        p = ProjectBundle.open(self.root)
        with patch("biodataledger.core.fingerprint", side_effect=AssertionError("unexpected hash")), \
                patch.object(Path, "open", side_effect=AssertionError("unexpected file open")), \
                patch.object(p, "_latest", side_effect=AssertionError("registry scan")):
            view = p.get_figure(self.f)
            p.get_analysis(self.a)
            status = p.status()
            p.summary()
        self.assertEqual(view.provenance, {"figure_file": "unknown", "analytical": "unknown", "execution": "unknown"})
        self.assertEqual(view.evidence["input_relationships"], "unknown")
        self.assertEqual(view.evidence["code_relationships"], "unknown")
        self.assertIn("analytical_provenance", view.evidence["missing"])
        self.assertIn("execution_evidence", view.unknown)
        self.assertEqual(p.get_analysis(self.a).details["provenance"]["execution"], "observed")
        self.assertFalse(p.unsaved)
        self.assertEqual(path.read_bytes(), before)
        self.assertLessEqual(len(canonical(status)), 4096)

    def test_exact_history_standalone_and_missing_fields(self):
        new = self.p.update_record(self.a, {"inputs": None, "code": [], "method": None, "params": None}, "unknown context")
        revised = self.p.register_figure("figure.svg", "plot", analysis=new)
        self.assertEqual(self.p.get_figure(self.f).unknown, ["execution_evidence"])
        self.assertEqual(set(self.p.get_figure(revised).unknown), {"inputs", "code", "method", "params", "execution_evidence"})
        standalone = self.p.register_figure("figure.svg", "plot", inputs=[self.d], code="plot.py",
                                             method="synthetic", params={"n": 1})
        self.assertEqual(self.p.get_figure(standalone).evidence, self.p.get_figure(self.f).evidence)
        (self.root / "plot.py").unlink()
        self.assertTrue(self.p.get_figure(self.f, check_files=True).code_availability[0]["available"])
        self.assertEqual(self.p.get_figure(self.f).evidence["execution_evidence"], "not_captured")

    def test_native_query_parity_and_caller_claims(self):
        script = r'''
args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc=args[[2]])
p <- ProjectBundle$open(args[[1]])
f <- p$get_figure("FIG-001@1"); a <- p$get_analysis("ANA-001@1")
claimed <- p$register_analysis("Caller claim", a$inputs, code="plot.py", method="synthetic",
  params=list(n=1), provenance=list(analytical="observed", execution="observed"))
figure <- p$register_figure("figure.svg", "plot", analysis=claimed,
  provenance=list(file="observed", analytical="observed", execution="observed"))
invisible(p$save())
cat(jsonlite::toJSON(list(evidence=f$evidence, provenance=f$provenance, unknown=f$unknown,
  analysis_evidence=a$evidence, status=p$status()$evidence, summary=p$summary()$evidence,
  text=p$summary_text(), claimed_analysis=claimed, claimed_figure=figure), auto_unbox=TRUE, null="null"))
'''
        result = subprocess.run(["Rscript", "--vanilla", "-", str(self.root), os.environ["BDL_R_LIB"]],
                                input=script, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        native = json.loads(result.stdout)
        view = self.p.get_figure(self.f)
        self.assertEqual(native["evidence"], view.evidence)
        self.assertEqual(native["analysis_evidence"], view.evidence)
        self.assertEqual(native["provenance"], view.provenance)
        self.assertEqual(native["unknown"], view.unknown)
        self.assertEqual(native["status"], self.p.status()["evidence"])
        self.assertEqual(native["summary"], self.p.summary()["evidence"])
        self.assertIn("Execution evidence: not captured by registry.", native["text"])
        reopened = ProjectBundle.open(self.root)
        declared = reopened.get_figure(native["claimed_figure"])
        self.assertEqual(declared.evidence["input_relationships"], "declared")
        self.assertEqual(declared.provenance["analytical"], "declared")
        self.assertEqual(declared.provenance["execution"], "unknown")
        self.assertEqual(declared.unknown, ["execution_evidence"])


if __name__ == "__main__":
    unittest.main()
