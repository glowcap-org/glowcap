#!/usr/bin/env python3
"""Behaviour test for tools/evidence/record.py.

The record's fields, the dirty name, the note that only a clean checkout
gets, and the refusals. The caller owns the working directory, so the test
builds its own repository under a temporary directory and runs the script
from there, and once from a directory that is no repository at all.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RECORD = Path(__file__).resolve().parent / "record.py"
STARTED = "2026-10-19T00:00:00Z"
ROWS = "0\t3\tzig build check\n5\t12\tzig build runtime-check\n"

# A hermetic git: no user or system config, so the maintainer's signing and
# hooks never reach the throwaway repository.
GIT_ENV = dict(
    os.environ,
    GIT_CONFIG_GLOBAL=os.devnull,
    GIT_CONFIG_NOSYSTEM="1",
    GIT_AUTHOR_NAME="evidence",
    GIT_AUTHOR_EMAIL="evidence@example.invalid",
    GIT_COMMITTER_NAME="evidence",
    GIT_COMMITTER_EMAIL="evidence@example.invalid",
)


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True
    ).stdout.strip()


def run(cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RECORD), *args], cwd=cwd, env=GIT_ENV, capture_output=True, text=True
    )


class RecordTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / ".devcontainer").mkdir()
        self.pins = self.repo / ".devcontainer/pins.sh"
        self.pins.write_text("ZIG=0.17.0\n")
        (self.repo / ".devcontainer/checksums.sh").write_text("sum=1\n")
        (self.repo / "a.txt").write_text("one\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "first")
        self.commit = git(self.repo, "rev-parse", "HEAD")
        self.rows = Path(self.temporary.name) / "gates.tsv"
        self.rows.write_text(ROWS)

    def record(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return run(self.repo, "--gates", str(self.rows), "--started", STARTED, "--outcome", "failed", *extra)

    def test_clean_checkout_writes_the_record_and_its_note(self) -> None:
        result = self.record("--note")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertEqual(path, self.repo / "zig-out/evidence" / f"{self.commit}.json")
        body = json.loads(path.read_text())
        self.assertEqual(body["format"], 1)
        self.assertEqual(body["outcome"], "failed")
        self.assertEqual(body["started"], STARTED)
        self.assertEqual(body["commit"], self.commit)
        self.assertEqual(body["tree"], git(self.repo, "rev-parse", "HEAD^{tree}"))
        self.assertEqual(body["branch"], "main")
        self.assertFalse(body["dirty"])
        self.assertEqual(body["submodules"], [])
        self.assertEqual(
            body["toolchain"]["pins"][".devcontainer/pins.sh"],
            hashlib.sha256(self.pins.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            body["gates"],
            [
                {"command": "zig build check", "exit": 0, "seconds": 3},
                {"command": "zig build runtime-check", "exit": 5, "seconds": 12},
            ],
        )
        note = git(self.repo, "notes", "--ref=refs/notes/evidence", "show", self.commit)
        self.assertEqual(json.loads(note), body)

    def test_dirty_checkout_is_named_and_gets_no_note(self) -> None:
        (self.repo / "a.txt").write_text("two\n")
        result = self.record("--note")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertEqual(path.name, f"{self.commit}-dirty.json")
        body = json.loads(path.read_text())
        self.assertTrue(body["dirty"])
        self.assertNotEqual(body["tree"], git(self.repo, "rev-parse", "HEAD^{tree}"))
        self.assertEqual(git(self.repo, "diff", "--cached", "--name-only"), "")
        listing = subprocess.run(
            ["git", "notes", "--ref=refs/notes/evidence", "list"],
            cwd=self.repo, env=GIT_ENV, capture_output=True, text=True,
        )
        self.assertEqual(listing.stdout, "")

    def test_unignored_untracked_file_is_dirty_and_an_ignored_one_is_not(self) -> None:
        (self.repo / ".gitignore").write_text("scratch\nzig-out\n")
        git(self.repo, "add", ".gitignore")
        git(self.repo, "commit", "-q", "-m", "ignore")
        commit = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "scratch").write_text("ignored\n")
        self.assertEqual(self.record().stdout.strip(), str(self.repo / "zig-out/evidence" / f"{commit}.json"))
        (self.repo / "b.txt").write_text("new\n")
        self.assertTrue(self.record().stdout.strip().endswith(f"{commit}-dirty.json"))
        self.assertEqual(git(self.repo, "diff", "--cached", "--name-only"), "")

    def test_detached_head_has_no_branch(self) -> None:
        git(self.repo, "checkout", "-q", "--detach")
        result = self.record()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(Path(result.stdout.strip()).read_text())["branch"])

    def test_malformed_rows_write_nothing(self) -> None:
        self.rows.write_text("0\tzig build check\n")
        result = self.record()
        self.assertEqual(result.returncode, 2)
        self.assertIn("three fields", result.stderr)
        self.assertFalse((self.repo / "zig-out").exists())

    def test_missing_rows_exit_two(self) -> None:
        result = run(self.repo, "--gates", "absent.tsv", "--started", STARTED, "--outcome", "passed")
        self.assertEqual(result.returncode, 2)

    def test_note_refusal_keeps_the_record_and_exits_three(self) -> None:
        # The notes ref names a blob, which git refuses to read as a notes
        # tree, under any user.
        blob = git(self.repo, "rev-parse", "HEAD:a.txt")
        git(self.repo, "update-ref", "refs/notes/evidence", blob)
        result = self.record("--note")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("note not attached", result.stderr)
        self.assertTrue((self.repo / "zig-out/evidence" / f"{self.commit}.json").exists())

    def test_outside_a_repository_exits_one(self) -> None:
        elsewhere = Path(self.temporary.name) / "elsewhere"
        elsewhere.mkdir()
        result = run(elsewhere, "--gates", str(self.rows), "--started", STARTED, "--outcome", "passed")
        self.assertEqual(result.returncode, 1)
        self.assertIn("git rev-parse", result.stderr)


if __name__ == "__main__":
    unittest.main()
