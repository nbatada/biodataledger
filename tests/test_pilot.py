import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from biodataledger import pilot


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.path = self.root / "ticket.json"

    def cli(self, *args):
        self.assertEqual(pilot.main(args), 0)

    def test_ticket_lifecycle_reports_first_pass_and_explicit_unknowns(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-1", "--usage", "tokens=12")
        self.cli("locate", "--path", str(self.path), "--evidence", "registry:DATA-1")
        self.cli("deliver", "--path", str(self.path), "--evidence", "report.md")
        self.cli("accept", "--path", str(self.path), "--decision", "accepted", "--active-review-seconds", "4", "--cost", "usd=1.5")
        report = pilot.summary(self.path)
        self.assertEqual(report["status"], "accepted")
        self.assertTrue(report["first_pass"])
        self.assertEqual(report["declared_usage_increment_total"], {"tokens": 12.0})
        self.assertEqual(report["declared_cost_increment_total"], {"usd": 1.5})
        self.assertGreaterEqual(report["time_to_lookup_seconds"], 0)
        self.assertGreaterEqual(report["review_waiting_seconds"], 0)

    def test_correction_is_not_first_pass_and_existing_log_is_protected(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-2")
        with self.assertRaises(SystemExit): self.cli("start", "--path", str(self.path), "--ticket", "other")
        self.cli("deliver", "--path", str(self.path)); self.cli("correct", "--path", str(self.path), "--reason", "fix")
        self.cli("deliver", "--path", str(self.path)); self.cli("accept", "--path", str(self.path), "--decision", "accepted")
        self.assertFalse(pilot.summary(self.path)["first_pass"])

    def test_state_transitions_reject_early_correction_acceptance_and_late_lookup(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-transition")
        with self.assertRaises(SystemExit): self.cli("correct", "--path", str(self.path))
        with self.assertRaises(SystemExit): self.cli("accept", "--path", str(self.path), "--decision", "accepted")
        self.cli("deliver", "--path", str(self.path))
        with self.assertRaises(SystemExit): self.cli("locate", "--path", str(self.path), "--evidence", "too-late")

    def test_measure_records_child_metrics_and_failure_exit(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-3")
        code = pilot.main(["measure", "--path", str(self.path), "--", sys.executable, "-c", "import sys; sys.exit(3)"])
        self.assertEqual(code, 3)
        event = pilot.summary(self.path)["events"][-1]
        self.assertEqual(event["kind"], "measure"); self.assertEqual(event["exit_code"], 3)
        self.assertIn("elapsed_seconds", event)
        self.assertNotIn("command", event)

    def test_measure_reservation_can_be_explicitly_abandoned(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-reserve")
        pilot._mutate(self.path, lambda ticket: ticket["events"].append(
            pilot._event("measure_started", token="x", owner_pid=os.getpid(), host="other-host")))
        with self.assertRaises(SystemExit):
            self.cli("measure", "--path", str(self.path), "--", sys.executable, "-c", "pass")
        self.cli("abandon-measure", "--path", str(self.path), "--reason", "operator confirmed", "--confirmed-stopped")
        self.cli("deliver", "--path", str(self.path))
        self.assertEqual(pilot.summary(self.path)["events"][-2]["failure"], "abandoned: operator confirmed")

    def test_disk_scope_skips_symlink_and_rejects_log_scope(self):
        scope = self.root / "scope"; scope.mkdir(); (scope / "x").write_bytes(b"abc")
        (scope / "link").symlink_to(scope / "x")
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-4", "--disk", str(scope))
        disk = pilot.summary(self.path)["events"][0]["disk_scope"][0]
        self.assertEqual(disk["bytes"], 3); self.assertEqual(disk["symlinks_skipped"], 1)
        self.assertEqual(pilot._logical_size([str(self.root)], self.path)[0]["status"], "unknown")

    def test_scope_delta_and_sample_do_not_block_acceptance(self):
        scope = self.root / "scope"; scope.mkdir(); (scope / "x").write_bytes(b"a")
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-scope", "--disk", str(scope))
        self.cli("deliver", "--path", str(self.path))
        with patch("biodataledger.pilot.subprocess.check_output", return_value="2\n"):
            self.cli("sample", "--path", str(self.path), "--pid", "9")
        (scope / "x").write_bytes(b"abcd")
        self.cli("accept", "--path", str(self.path), "--decision", "accepted", "--active-review-seconds", "0")
        report = pilot.summary(self.path)
        self.assertEqual(report["active_review_seconds"], 0)
        self.assertEqual(report["disk_scopes"][0]["delta_bytes"], 3)

    def test_sample_records_observation_without_claiming_peak(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-5")
        with patch("biodataledger.pilot.subprocess.check_output", return_value="17\n"):
            self.cli("sample", "--path", str(self.path), "--pid", str(os.getpid()))
        report = pilot.summary(self.path)
        self.assertEqual(report["max_observed_rss_bytes"], 17 * 1024)
        self.assertIn("not a process lifetime", report["rss_note"])

    def test_sample_records_unavailable_as_unknown(self):
        self.cli("start", "--path", str(self.path), "--ticket", "BDL-unknown")
        with patch("biodataledger.pilot.subprocess.check_output", side_effect=OSError("no ps")):
            self.cli("sample", "--path", str(self.path), "--pid", "9")
        event = pilot.summary(self.path)["events"][-1]
        self.assertEqual(event["kind"], "sample")
        self.assertNotIn("rss_bytes", event)
        self.assertIn("reason", event)


if __name__ == "__main__": unittest.main()
