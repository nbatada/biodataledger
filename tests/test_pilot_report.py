import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from biodataledger import pilot, pilot_report


class PilotReviewTests(unittest.TestCase):
    def test_offline_report_keeps_open_tickets_and_does_not_replace_files(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            opened, closed = root / "a.json", root / "b.json"
            pilot.main(["start", "--path", str(opened), "--ticket", "<open>"])
            pilot.main(["start", "--path", str(closed), "--ticket", "completed"])
            pilot.main(["deliver", "--path", str(closed), "--evidence", "sensitive-path"])
            pilot.main(["accept", "--path", str(closed), "--decision", "accepted"])
            dest = root / "review.html"
            pilot_report.main([str(opened), str(closed), "--out", str(dest)])
            page = dest.read_text()
            self.assertIn("&lt;open&gt;", page)
            self.assertIn("completed", page)
            self.assertIn("accepted", page)
            self.assertNotIn("sensitive-path", page)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                pilot_report.main([str(closed), "--out", str(dest)])
            self.assertEqual(dest.read_text(), page)
