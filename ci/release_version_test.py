"""ci/release_version.py is the only place a release version format is written.

The first test holds the format. The second reads every tracked Python
program under ci/ and tools/ and refuses one that writes a version pattern of
its own.
"""

import re
import subprocess
import unittest

import release_version
from workflows import ROOT

# Two escaped dots that each lead into a digit class, whatever groups or counts sit between them.
DIGITS = r"\\\.[(?:\[]*(?:0-9|1-9|\\d|0)"
PATTERN = re.compile(DIGITS + r"""[^"'\n]{0,30}?""" + DIGITS)
# A pattern for another program's version, never glowcap's.
OTHER = {"ci/github_release.py": r'runtime + r" [0-9]+\.[0-9]+\.[0-9]+"'}


class ReleaseVersion(unittest.TestCase):
    def test_only_a_prerelease_version_is_accepted(self):
        for version, accepted in [
            ("0.1.2", True),
            ("0.0.0", True),
            ("0.10.20", True),
            ("1.0.0", False),
            ("10.0.0", False),
            ("0.1", False),
            ("0.1.2.3", False),
            ("0.01.2", False),
            ("0.1.02", False),
            ("0.1.2-alpha.1", False),
            ("0.1.2\n", False),
            ("v0.1.2", False),
            ("", False),
            (None, False),
            (7, False),
        ]:
            with self.subTest(version=version):
                self.assertEqual(release_version.accepted(version), accepted)
                tag = f"v{version}"
                self.assertEqual(release_version.of_tag(tag), version if accepted else None)
        for rejected in ("0.1.2", "V0.1.2", "vv0.1.2", None, 7):
            with self.subTest(tag=rejected):
                self.assertIsNone(release_version.of_tag(rejected))

    def test_no_other_program_writes_a_version_pattern(self):
        listed = subprocess.check_output(["git", "ls-files", "-z", "ci/*.py", "tools/*.py"], cwd=ROOT, text=True)
        programs = [path for path in listed.split("\0") if path and path != "ci/release_version.py"]
        self.assertGreater(len(programs), 40)
        for path in programs:
            source = (ROOT / path).read_text()
            if path in OTHER:
                self.assertIn(OTHER[path], source, f"{path} no longer needs its row in OTHER")
                source = source.replace(OTHER[path], "")
            if path == "ci/release_version_test.py":
                continue
            with self.subTest(path=path):
                self.assertIsNone(PATTERN.search(source), f"{path} writes a version pattern; ask release_version")

    def test_the_pattern_scan_reads_each_digit_form(self):
        for line in (
            r'r"0\.[0-9]+\.[0-9]+"',
            r'r"v\d+\.\d+\.\d+"',
            r'r"[0-9]+\.[0-9]+\.[0-9]+"',
            r'r"^0\.\d*\.[0-9]$"',
            r'r"0\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"',
            r'r"0\.[1-9][0-9]*\.[0-9]+"',
            r'r"\d{1,3}\.\d+\.\d+"',
            r'r"[0-9]{1,}\.[0-9]+\.[0-9]+"',
            r'r"(\d+)\.(\d+)\.(\d+)"',
        ):
            with self.subTest(line=line):
                self.assertIsNotNone(PATTERN.search(line))
        for line in ('"0.1.2"', r'r"sha256:[0-9a-f]{64}"', r'r"[0-9]{4}-[0-9]{2}-[0-9]{2}"'):
            with self.subTest(line=line):
                self.assertIsNone(PATTERN.search(line))


if __name__ == "__main__":
    unittest.main()
