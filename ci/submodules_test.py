"""Submodule checkout contracts, for infrastructure-check."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import submodules as SUBMODULES
from workflows import ROOT, WORKFLOWS, workflow

IDENTITY = ("-c", "user.name=ci", "-c", "user.email=ci@example.invalid")
# The fixture's submodule host is a directory, which git clones from only when told to.
LOCAL_HOST = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"}


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *IDENTITY, *args], capture_output=True, text=True, check=True)


class SubmodulesTest(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.dict(os.environ, LOCAL_HOST)
        patch.start()
        self.addCleanup(patch.stop)
        self.scratch = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.scratch)
        self.upstream = self.scratch / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q")
        (self.upstream / "pinned.txt").write_text("one\n")
        git(self.upstream, "add", "pinned.txt")
        git(self.upstream, "commit", "-q", "-m", "one")
        origin = self.scratch / "origin"
        origin.mkdir()
        git(origin, "init", "-q")
        git(origin, "submodule", "add", "-q", str(self.upstream), "dep")
        git(origin, "commit", "-q", "-m", "pin")
        self.origin = origin

    def clone(self, name):
        """What actions/checkout leaves: the tree with no submodule fetched."""
        root = self.scratch / name
        git(self.scratch, "clone", "-q", str(self.origin), str(root))
        return root

    def test_a_restored_cache_checks_out_with_its_host_gone(self):
        first = self.clone("first")
        SUBMODULES.checkout(first, waits=())
        self.assertEqual((first / "dep/pinned.txt").read_text(), "one\n")
        second = self.clone("second")
        shutil.copytree(first / ".git/modules", second / ".git/modules")
        shutil.rmtree(self.upstream)
        slept: list[int] = []
        SUBMODULES.checkout(second, sleep=slept.append)
        self.assertEqual((second / "dep/pinned.txt").read_text(), "one\n")
        self.assertEqual(slept, [], "a warm cache needs no second attempt")
        self.assertEqual(SUBMODULES.unsettled(second), [])

    def test_an_unreachable_host_is_retried_then_reported(self):
        root = self.clone("cold")
        shutil.rmtree(self.upstream)
        slept: list[int] = []
        with self.assertRaisesRegex(SystemExit, "could not be fetched"):
            SUBMODULES.checkout(root, waits=(1, 2), sleep=slept.append)
        self.assertEqual(slept, [1, 2])

    def test_the_key_follows_the_pin_and_its_source(self):
        root = self.clone("keyed")
        before = SUBMODULES.key(root)
        self.assertEqual(before, SUBMODULES.key(self.clone("again")), "the same pins name the same cache")
        (self.upstream / "pinned.txt").write_text("two\n")
        git(self.upstream, "commit", "-q", "-am", "two")
        SUBMODULES.checkout(root, waits=())
        git(root / "dep", "fetch", "-q", "origin")
        git(root / "dep", "checkout", "-q", "FETCH_HEAD")
        git(root, "add", "dep")
        self.assertNotEqual(SUBMODULES.key(root), before, "a moved pin names a new cache")
        git(root, "reset", "-q", "--hard")
        (root / ".gitmodules").write_text((root / ".gitmodules").read_text().replace("upstream", "elsewhere"))
        git(root, "add", ".gitmodules")
        self.assertNotEqual(SUBMODULES.key(root), before, "a moved source names a new cache")

    def test_every_job_takes_submodules_from_the_cache(self):
        takers = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, job in workflow(path.relative_to(ROOT))["jobs"].items():
                steps = job.get("steps", ())
                with self.subTest(workflow=path.name, job=name):
                    for step in steps:
                        self.assertNotIn(
                            "submodules", step.get("with", {}), "actions/checkout clones each one on every job"
                        )
                    runs = [step.get("run") for step in steps]
                    if "python3 ci/submodules.py checkout" not in runs:
                        continue
                    takers += 1
                    at = runs.index("python3 ci/submodules.py checkout")
                    self.assertEqual(runs[at - 2], "python3 ci/submodules.py key")
                    self.assertEqual(
                        steps[at - 1]["with"], {"path": ".git/modules", "key": "${{ steps.submodules.outputs.key }}"}
                    )
                    self.assertEqual(steps[at - 2]["id"], "submodules")
        self.assertGreater(takers, 0)


if __name__ == "__main__":
    unittest.main()
