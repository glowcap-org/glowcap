"""Dependabot watches every dependency the repository locks, and nothing else.

Read .github/dependabot.yml against git's index: each committed lockfile's
directory is listed under its ecosystem, each listed directory holds that
ecosystem's manifest, and the Actions entry reaches every composite action.
This does not reach GitHub.
"""

import subprocess
import unittest
from pathlib import PurePosixPath

from workflows import ROOT, workflow

# ecosystem: (lockfile, manifests). A Cargo or Deno manifest without a
# committed lock is still watched, so the manifest decides a listed directory.
ECOSYSTEMS = {
    "cargo": ("Cargo.lock", ("Cargo.toml",)),
    "uv": ("uv.lock", ("pyproject.toml",)),
    "deno": ("deno.lock", ("deno.json", "deno.jsonc")),
}


def tracked(*patterns):
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--", *patterns], cwd=ROOT, check=True, capture_output=True, timeout=30
    ).stdout
    return [PurePosixPath(path) for path in listing.decode().split("\0") if path]


def directory(path):
    parent = str(path.parent)
    return "/" if parent == "." else f"/{parent}"


def entries():
    updates = workflow(".github/dependabot.yml")["updates"]
    return {
        ecosystem: [entry for entry in updates if entry["package-ecosystem"] == ecosystem]
        for ecosystem in dict.fromkeys(entry["package-ecosystem"] for entry in updates)
    }


class Dependabot(unittest.TestCase):
    def test_every_committed_lock_is_watched_by_its_ecosystem(self):
        found = entries()
        for ecosystem, (lock, manifests) in ECOSYSTEMS.items():
            with self.subTest(ecosystem=ecosystem):
                (entry,) = found[ecosystem]
                listed = entry["directories"]
                self.assertEqual(len(listed), len(set(listed)), "one row per directory")
                locked = {directory(path) for path in tracked(f"*{lock}")}
                self.assertTrue(locked)
                self.assertLessEqual(locked, set(listed), f"a committed {lock} Dependabot never reads")
                for path in listed:
                    root = path.removeprefix("/")
                    self.assertTrue(
                        any((ROOT / root / name).is_file() for name in manifests), f"{path} holds no {manifests[0]}"
                    )

    def test_actions_updates_reach_every_composite_action(self):
        (entry,) = entries()["github-actions"]
        self.assertEqual(entry["directories"], ["/", "/.github/actions/*"])
        self.assertTrue(tracked(".github/actions/*/action.yml"))

    def test_the_browser_package_moves_with_its_pin(self):
        (entry,) = entries()["deno"]
        self.assertEqual(entry["ignore"], [{"dependency-name": "playwright"}])
        self.assertIn("PLAYWRIGHT_VERSION=", (ROOT / ".devcontainer/pins.sh").read_text())

    def test_every_update_waits_a_week(self):
        for ecosystem, rows in entries().items():
            for entry in rows:
                with self.subTest(ecosystem=ecosystem):
                    self.assertEqual(entry["cooldown"], {"default-days": 7})


if __name__ == "__main__":
    unittest.main()
