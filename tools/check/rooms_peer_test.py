#!/usr/bin/env python3
"""infrastructure-check: Rooms journey deadlines and failure diagnostics."""
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import rooms_peer


class RoomsPeerTest(unittest.TestCase):
    def test_success_reports_insufficient_deadline_headroom(self):
        for elapsed, warning in ((4, False), (5, True), (6.75, True)):
            with self.subTest(elapsed=elapsed), redirect_stderr(io.StringIO()) as output:
                with patch.object(rooms_peer.time, "monotonic", side_effect=[0, elapsed]), \
                     patch.object(rooms_peer.subprocess, "run", return_value=
                                  subprocess.CompletedProcess([], 0, '{"ok":true}', '')):
                    self.assertEqual(rooms_peer.cli(Path("peer"), "status"), {"ok": True})
                self.assertEqual("2x slower" in output.getvalue(), warning)

    def test_timeout_preserves_partial_evidence_without_retry(self):
        failure = subprocess.TimeoutExpired("fixture", 10, output=b"partial reply", stderr=b"peer error")
        with redirect_stderr(io.StringIO()) as output, \
             patch.object(rooms_peer.subprocess, "run", side_effect=failure) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                rooms_peer.cli(Path("peer"), "status")
        run.assert_called_once()
        self.assertIn("partial reply", output.getvalue())
        self.assertIn("peer error", output.getvalue())

    def test_inbox_without_name_is_not_complete_registration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "peer-options.json").write_text("{}")
            (root / "control.sock").touch()
            for name, registered in ((None, False), ("name-key", True)):
                status = {"workspace": {"directories": [{"name": name, "inbox": "inbox-key"}]}}
                reply = subprocess.CompletedProcess([], 0, json.dumps(status), '')
                with redirect_stderr(io.StringIO()) as output, \
                     patch.object(rooms_peer.subprocess, "run", return_value=reply):
                    rooms_peer.failure_logs(root)
                evidence = json.loads(output.getvalue().splitlines()[-1])
                self.assertEqual(evidence["directories"][0]["registered"], registered)


if __name__ == "__main__":
    unittest.main()
