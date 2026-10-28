"""Coverage selection contracts, loaded by publication_workflow_test.py."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_plan", ROOT / "ci/plan.py")
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)
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
                self.assertEqual(PLAN.select(event, ref, payload, ["README.md"]),
                                 (list(PLAN.GROUP_NAMES), True))

    def test_development_selects_consumers_and_fails_closed(self):
        cases = [
            (["README.md", "docs/shipped.md"], ["core", "runtime", "shipped"], False),
            (["src/loam/core/mod.zig"], ["core", "runtime", "shipped", "browser"], False),
            (["bindings/python/glowcap/__init__.py"], ["core", "runtime", "shipped", "bindings", "interop", "transports"], False),
            (["conformance/goblins-peer/peer.rkt"], ["core", "runtime", "shipped", "interop", "transports"], False),
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
            ([], ["core", "runtime", "shipped"], False),
        ]
        for paths, lanes, full in cases:
            with self.subTest(paths=paths):
                self.assertEqual(PLAN.select("pull_request", "refs/pull/7/merge", INTO_DEV, paths), (lanes, full))
        self.assertEqual(PLAN.select("pull_request", "refs/pull/7/merge", INTO_DEV,
                                     ["src/loam/core/mod.zig", "bindings/rust/src/lib.rs"]),
                         (DEVELOPMENT, False))

    def test_diff_includes_deletions_and_both_sides_of_renames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-c", "commit.gpgsign=false", *args],
                                               cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
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

    def test_actions_output_from_an_unrelated_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "event.json").write_text('{}')
            env = dict(os.environ, GITHUB_EVENT_PATH=str(root / "event.json"),
                       GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/dev",
                       GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            subprocess.run(["python3", str(ROOT / "ci/plan.py")], cwd=root, env=env, check=True)
            values = dict(line.split("=", 1) for line in (root / "output").read_text().splitlines())
            groups = json.loads(values["groups"])
            self.assertEqual([group["name"] for group in groups], list(PLAN.GROUP_NAMES))
            for group, (name, phases, shards) in zip(groups, PLAN.GROUPS):
                self.assertEqual(group, {"name": name, "phases": list(phases),
                                         "shards": list(range(1, shards + 1))})
            self.assertEqual(values["full"], "true")
            self.assertIn("**full**", (root / "summary").read_text())
