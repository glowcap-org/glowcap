"""ci/plan.py, which selects the groups a run needs, for infrastructure-check."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import plan as PLAN
from workflows import ROOT

INTO_DEV = {"pull_request": {"base": {"ref": "dev"}}}
# Development validation never fuzzes.
DEVELOPMENT = [name for name in PLAN.GROUP_NAMES if name != "fuzz"]


class PlanTest(unittest.TestCase):
    def test_full_qualification_never_uses_paths(self):
        for event, ref, payload in (
            ("push", "refs/heads/main", {}),
            ("push", "refs/heads/dev", {}),
            ("schedule", "refs/heads/main", {}),
            ("workflow_dispatch", "refs/heads/dev", {}),
            ("pull_request", "refs/pull/7/merge", {"pull_request": {"base": {"ref": "main"}}}),
        ):
            with self.subTest(event=event):
                self.assertEqual(PLAN.select(event, ref, payload, ["README.md"]), (list(PLAN.GROUP_NAMES), True))

    def test_development_selects_consumers_and_fails_closed(self):
        cases = [
            (["README.md", "docs/shipped.md"], ["source", "core", "runtime", "tls", "shipped"], False),
            (["src/loam/core/mod.zig"], ["source", "core", "runtime", "tls", "shipped", "browser"], False),
            (
                ["bindings/python/glowcap/__init__.py"],
                ["source", "core", "runtime", "tls", "shipped", "bindings", "interop", "transports"],
                False,
            ),
            (
                ["conformance/goblins-peer/peer.rkt"],
                ["source", "core", "runtime", "tls", "shipped", "interop", "transports"],
                False,
            ),
            (["apps/rooms/lib/peer.ts"], DEVELOPMENT, False),
            (["bindings/rust/src/lib.rs"], DEVELOPMENT, False),
            (["bindings/proofs/scenario.ts"], DEVELOPMENT, False),
            (["bindings/ts/host.ts"], DEVELOPMENT, False),
            (["src/ocapn/session.zig"], DEVELOPMENT, False),
            (["src/c_abi/shared/archive_pin.zig"], DEVELOPMENT, False),
            ([".github/workflows/check.yml"], list(PLAN.GROUP_NAMES), True),
            ([".agents/skills/work/bin/glowcap-dev"], list(PLAN.GROUP_NAMES), True),
            (["build.zig.zon"], list(PLAN.GROUP_NAMES), True),
            (["test/driver/fuzz_test.zig"], list(PLAN.GROUP_NAMES), True),
            (["an-unclassified-file"], list(PLAN.GROUP_NAMES), True),
            (None, list(PLAN.GROUP_NAMES), True),
            ([], ["source", "core", "runtime", "tls", "shipped"], False),
        ]
        for paths, selected, full in cases:
            with self.subTest(paths=paths):
                self.assertEqual(PLAN.select("pull_request", "refs/pull/7/merge", INTO_DEV, paths), (selected, full))
        self.assertEqual(
            PLAN.select(
                "pull_request", "refs/pull/7/merge", INTO_DEV, ["src/loam/core/mod.zig", "bindings/rust/src/lib.rs"]
            ),
            (DEVELOPMENT, False),
        )

    def test_a_change_plans_a_nightly_phase_only_for_its_owners(self):
        def interop(event, paths):
            # A pull request into dev selects groups by path, so each owner
            # must also reach the interop group that holds the phase.
            groups, _ = PLAN.plan(event, "refs/pull/7/merge", INTO_DEV, paths)
            return next(group["phases"] for group in groups if group["name"] == "interop")

        self.assertNotIn("goblins-matrix", interop("pull_request", ["src/ocapn/session.zig"]))
        self.assertIn("goblins-live", interop("pull_request", ["src/ocapn/session.zig"]))
        for owner in PLAN.NIGHTLY["goblins-matrix"]:
            with self.subTest(owner=owner):
                self.assertIn("goblins-matrix", interop("pull_request", [owner + ("x" if owner.endswith("/") else "")]))
        self.assertIn("goblins-matrix", interop("pull_request", None), "unknown paths run everything")
        for event in ("schedule", "workflow_dispatch"):
            self.assertIn("goblins-matrix", interop(event, ["src/ocapn/session.zig"]))
        # A push to dev is full validation, and still waits for no nightly phase.
        pushed, full = PLAN.plan("push", "refs/heads/dev", {}, ["src/ocapn/session.zig"])
        self.assertTrue(full)
        self.assertNotIn("goblins-matrix", [phase for group in pushed for phase in group["phases"]])
        for group in PLAN.GROUPS:
            self.assertTrue(PLAN.phases(group, "push", []), "a group keeps a phase on every run")

    def test_diff_includes_deletions_and_both_sides_of_renames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "commit.gpgsign=false", *args], cwd=root, stderr=subprocess.DEVNULL, text=True
                ).strip()

            git("init", "-q")
            git("config", "user.name", "CI fixture")
            git("config", "user.email", "ci@example.invalid")
            (root / "source.zig").write_text("fixture\n")
            (root / "delete.zig").write_text("delete\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("mv", "source.zig", "README.md")
            git("rm", "delete.zig")
            git("commit", "-qm", "rename and delete")
            for event in ({"before": base}, {"pull_request": {"base": {"sha": base}}}):
                paths = PLAN.changed_paths(event, root)
                self.assertEqual(set(paths), {"source.zig", "README.md", "delete.zig"})
                self.assertTrue(PLAN.select("pull_request", "refs/pull/7/merge", INTO_DEV, paths)[1])
            for base in ("", "0" * 40, "1" * 40, "--help"):
                self.assertIsNone(PLAN.changed_paths({"before": base}, root))

    def test_docs_followup_keeps_the_pull_requests_code_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "commit.gpgsign=false", *args], cwd=root, stderr=subprocess.DEVNULL, text=True
                ).strip()

            git("init", "-q")
            git("config", "user.name", "CI fixture")
            git("config", "user.email", "ci@example.invalid")
            (root / "README.md").write_text("base\n")
            git("add", "README.md")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            peer = root / "conformance/goblins-peer/peer.rkt"
            peer.parent.mkdir(parents=True)
            peer.write_text("fixture\n")
            git("add", "conformance/goblins-peer/peer.rkt")
            git("commit", "-qm", "code change")
            before = git("rev-parse", "HEAD")
            (root / "README.md").write_text("follow-up docs\n")
            git("add", "README.md")
            git("commit", "-qm", "docs followup")

            event = {"before": before, "pull_request": {"base": {"ref": "dev", "sha": base}}}
            paths = PLAN.changed_paths(event, root)
            self.assertEqual(set(paths), {"README.md", "conformance/goblins-peer/peer.rkt"})
            groups, full = PLAN.select("pull_request", "refs/pull/7/merge", event, paths)
            self.assertIn("interop", groups)
            self.assertIn("transports", groups)
            self.assertFalse(full)
            self.assertEqual(PLAN.changed_paths({"before": before}, root), ["README.md"])
            for metadata in ({}, {"sha": ""}, {"sha": "--help"}, {"sha": "0" * 40}, {"sha": "1" * 40}):
                with self.subTest(base=metadata):
                    event["pull_request"]["base"] = metadata
                    self.assertIsNone(PLAN.changed_paths(event, root))
            del event["pull_request"]["base"]
            self.assertIsNone(PLAN.changed_paths(event, root))

    def test_actions_output_from_an_unrelated_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text("{}")
            env = dict(
                os.environ,
                GITHUB_EVENT_PATH=str(root / "event.json"),
                GITHUB_EVENT_NAME="workflow_dispatch",
                GITHUB_REF="refs/heads/dev",
                GITHUB_OUTPUT=str(root / "output"),
                GITHUB_STEP_SUMMARY=str(root / "summary"),
            )
            subprocess.run(["python3", str(ROOT / "ci/plan.py")], cwd=root, env=env, check=True)
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            groups = json.loads(values["groups"])
            self.assertEqual([group["name"] for group in groups], list(PLAN.GROUP_NAMES))
            for rendered, group in zip(groups, PLAN.GROUPS):
                self.assertEqual(
                    rendered,
                    {"name": group.name, "phases": list(group.phases), "shards": list(range(1, group.shards + 1))},
                )
            self.assertEqual(values["full"], "true")
            self.assertIn("**full**", (root / "summary").read_text())
