"""The audit verdict check.yml reads from zizmor's SARIF report, for infrastructure-check."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import sarif as SARIF
from workflows import jobs, step

FINDING = {
    "ruleId": "template-injection",
    "message": {"text": "code injection via template expansion"},
    "locations": [
        {"physicalLocation": {"artifactLocation": {"uri": ".github/workflows/x.yml"}, "region": {"startLine": 7}}}
    ],
}


class SarifTest(unittest.TestCase):
    def setUp(self):
        self.advice = io.StringIO()

    def verdict(self, source):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.sarif"
            report.write_text(source if isinstance(source, str) else json.dumps(source))
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(self.advice):
                status = SARIF.main(["refuse", str(report)])
            return status, printed.getvalue()

    def test_a_clean_report_passes_silently(self):
        self.assertEqual(self.verdict({"runs": [{"results": []}]}), (0, ""))
        self.assertEqual(self.verdict({"runs": [{"tool": {}}]}), (0, ""), "a run with no results key is clean")

    def test_each_finding_is_printed_and_fails(self):
        status, printed = self.verdict({"runs": [{"results": [FINDING, {**FINDING, "ruleId": "artipacked"}]}]})
        self.assertEqual(status, 1)
        self.assertEqual(
            printed.splitlines(),
            [
                "template-injection .github/workflows/x.yml:7 code injection via template expansion",
                "artipacked .github/workflows/x.yml:7 code injection via template expansion",
            ],
        )
        self.assertIn("2 finding(s). Fix each named workflow line and push.", self.advice.getvalue())

    def test_a_report_that_audited_nothing_fails(self):
        source: object
        for source in ({"runs": []}, {}, [], "not json", {"runs": None}):
            with self.subTest(source=source):
                status, _ = self.verdict(source)
                self.assertIsInstance(status, str, "a refusal names the report")
                self.assertIn("sarif:", status)
                self.assertIn("Read the audit step's log", status)

    def test_a_missing_report_fails(self):
        status = SARIF.main(["refuse", "/nonexistent/report.sarif"])
        self.assertIsInstance(status, str)

    def test_the_audit_job_reads_its_verdict_here(self):
        verdict = step(jobs(".github/workflows/check.yml")["workflows"], "Refuse findings")
        self.assertEqual(verdict["run"], 'python3 ci/sarif.py refuse "$REPORT"')
        self.assertEqual(verdict["env"]["REPORT"], "${{ steps.zizmor.outputs.output-file }}")
        self.assertNotIn("continue-on-error", verdict)


if __name__ == "__main__":
    unittest.main()
