"""Native R/Python exchange; runtime tests, not scientific validation."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import zipfile
import stat

from biodataledger import ProjectBundle, BundleError
from biodataledger.core import STATE_PATH
from create_fixtures import make_project

BASE = Path(__file__).resolve().parents[1]
R_LIBRARY = os.environ.get("BDL_R_LIB", "")
RSCRIPT = BASE / "tests/r_exchange.R"


def r_call(action, root, *args):
    result = subprocess.run(["Rscript", "--vanilla", str(RSCRIPT), R_LIBRARY, action, str(root), *map(str, args)],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError("R action " + action + " failed: " + result.stderr + result.stdout)
    return result


class NativeExchangeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_r_python_r_and_r_archive(self):
        root = self.base / "r-created"
        root.mkdir()
        archive = self.base / "r-working.zip"
        r_call("create", root, archive)
        p = ProjectBundle.open(root)
        f = p.get_figure("FIG-001@1")
        self.assertEqual(f.params, {"cutoff": 200, "labels": ["one"], "empty": []})
        p.set_context({"next_task": "updated by Python"})
        p.save()
        result = json.loads(r_call("inspect", root).stdout)
        self.assertEqual(result["params"], f.params)
        q = ProjectBundle.import_zip(archive, self.base / "r-zip-python-import")
        self.assertTrue(q.get_figure("FIG-001@1").code_availability[0]["available"])
        self.assertTrue(q.get_data(purpose="qc").available)

    def test_python_r_python_and_python_archive(self):
        p, d, f, g, _ = make_project(self.base / "python-created")
        r_call("update", p.root)
        q = ProjectBundle.open(p.root)
        self.assertEqual(q.summary()["next_task"], "updated by R")
        self.assertEqual(q.get_figure(f).params, {"min_genes": 200})
        z = self.base / "python-working.zip"
        q.export_zip(q.preview_export("working", [d, f, g]), z)
        target = self.base / "python-zip-r-import"
        r_call("import", target, z)
        reloaded = ProjectBundle.open(target)
        self.assertEqual(reloaded.summary()["next_task"], "imported and updated by R")
        self.assertTrue(reloaded.get_figure(f).code_availability[0]["available"])

    def test_cross_language_stale_writers(self):
        p, *_ = make_project(self.base / "race")
        ready, go = self.base / "ready", self.base / "go"
        worker = subprocess.Popen(["Rscript", "--vanilla", str(RSCRIPT), R_LIBRARY, "stale", str(p.root), str(ready), str(go)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: worker.kill() if worker.poll() is None else None)
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline and worker.poll() is None:
            time.sleep(.02)
        self.assertTrue(ready.exists(), "R writer did not start")
        p.set_context({"next_task": "Python wins"})
        p.save()
        go.write_text("go")
        output, error = worker.communicate(timeout=15)
        self.assertEqual(worker.returncode, 0, error)
        self.assertIn("REJECTED", output)
        p = ProjectBundle.open(p.root)
        p.set_context({"next_task": "Python pending"})
        r_call("update", p.root)
        with self.assertRaisesRegex(BundleError, "stale"):
            p.save()

    def test_hostile_archives_rejected_by_both_clients(self):
        p, d, f, *_ = make_project(self.base / "archive-source")
        good = self.base / "good.zip"
        p.export_zip(p.preview_export("working", [d, f]), good)
        with zipfile.ZipFile(good) as z:
            members = {i.filename: z.read(i) for i in z.infolist()}
        cases = []
        for bad_names in (("../escape",), ("/absolute",), ("A/x", "a/y"), ("x", "x/y"), ("e\u0301/x", "é/y")):
            cases.append(("paths", bad_names))
        cases += [("symlink", None), ("context-payload", None), ("reserved-binding", None), ("corrupt-payload", None)]
        for index, (kind, names) in enumerate(cases):
            payload = dict(members)
            manifest = json.loads(payload["manifest.json"])
            if kind == "context-payload":
                manifest["mode"] = "context"
            if kind == "reserved-binding":
                manifest["bindings"][next(iter(manifest["bindings"]))] = STATE_PATH
            payload["manifest.json"] = json.dumps(manifest).encode()
            if kind == "corrupt-payload":
                key = next(k for k in payload if k.startswith("payload/"))
                payload[key] += b"corrupt"
            archive = self.base / ("hostile-%s.zip" % index)
            with zipfile.ZipFile(archive, "w") as z:
                for name, content in payload.items():
                    z.writestr(name, content)
                for name in names or []:
                    z.writestr(name, "bad")
                if kind == "symlink":
                    link = zipfile.ZipInfo("linked")
                    link.create_system = 3
                    link.external_attr = (stat.S_IFLNK | 0o777) << 16
                    z.writestr(link, "../outside")
            with self.assertRaises(Exception, msg=kind):
                ProjectBundle.import_zip(archive, self.base / ("py-bad-%s" % index))
            result = r_call("archive-invalid", self.base / ("r-bad-%s" % index), archive)
            self.assertEqual(result.stdout.strip(), "REJECTED", kind)

    def test_r_default_large_registration_does_not_hash(self):
        p, *_ = make_project(self.base / "large-r")
        with (p.root / "large.h5ad").open("wb") as stream:
            stream.truncate(1024**3)
        self.assertEqual(r_call("large", p.root).stdout.strip(), "NO-PAYLOAD-HASH")

    def test_r_corrections_and_explicit_rebinding_roundtrip(self):
        p, *_ = make_project(self.base / "corrections")
        ext = self.base / "external.csv"
        ext.write_text("synthetic")
        result = r_call("mutations", p.root, ext)
        self.assertEqual(result.stdout.strip(), "MUTATIONS-OK")
        q = ProjectBundle.open(p.root)
        self.assertIsNone(q.state["project"]["purpose"])
        self.assertEqual(q.get_figure("FIG-001@2").revision, 2)
        self.assertEqual(q.get_data(purpose="qc").ref["id"], "DATA-001")

    def test_shared_invalid_fixtures(self):
        p, *_ = make_project(self.base / "invalid")
        original = copy.deepcopy(p.state)
        states = []
        for modify in (
            lambda s: s["records"][0].update(params=[]),
            lambda s: s.update(schema_version="99"),
            lambda s: s["current"]["qc"].update(revision=999),
            lambda s: s["records"][0].update(sha256="bad"),
            lambda s: s["records"][0].update(method={}),
            lambda s: s["records"][0].update(name=""),
            lambda s: s.update(records=None),
            lambda s: s["records"][2].update(sha256=None),
        ):
            state = copy.deepcopy(original)
            modify(state)
            states.append(json.dumps(state))
        states.append('{"schema_version":"0.1.0","schema_version":"0.1.0"}')
        for raw in states:
            (p.root / STATE_PATH).write_text(raw)
            with self.assertRaises(BundleError):
                ProjectBundle.open(p.root)
            result = r_call("invalid", p.root)
            self.assertEqual(result.stdout.strip(), "REJECTED")


if __name__ == "__main__":
    unittest.main()
