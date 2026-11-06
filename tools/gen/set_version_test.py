"""tools/gen/set_version.py: the one-command version bump on a copy of the tree.

Copies every file the bump edits into a temporary tree and runs the script
there, so the test proves the script's patterns against the checkout's own
files without touching the checkout. The ordinary path moves every mirror. Each
refusal exits 1 and writes nothing.
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/gen/set_version.py"
SPEC = importlib.util.spec_from_file_location("set_version", SCRIPT)
SET_VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SET_VERSION)
CURRENT = json.loads((ROOT / "bindings/c-abi-resolve.json").read_text())["abi_version"]
NEXT = "0.99.0"


def mirrors(root):
    """Every path the bump edits, whatever the changelog's state."""
    paths = set()
    try:
        for path, _, _, _ in SET_VERSION.edits(root, CURRENT, NEXT):
            paths.add(path)
    except ValueError:
        pass
    return paths | {"CHANGELOG.md"}


def copy_tree():
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name)
    paths = mirrors(ROOT)
    for path in paths:
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / path, root / path)
    # Give the fixture known entries whether the checkout has pending changes or not.
    changelog = root / "CHANGELOG.md"
    before, heading, after = changelog.read_text().partition("## [Unreleased]\n")
    _, next_heading, history = after.partition("\n## ")
    changelog.write_text(before + heading + "\n### Added\n\n- A test entry.\n" + next_heading + history)
    # The script lists manifests and locks with git, so the copy is a repository.
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    return temporary, root, paths


def snapshot(root):
    return {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}


def run(root, *args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=root, capture_output=True, text=True, timeout=20)


class SetVersion(unittest.TestCase):
    def test_moves_every_mirror_of_the_version(self):
        temporary, root, paths = copy_tree()
        with temporary:
            result = run(root, NEXT, "--date", "2026-12-01")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"{CURRENT} -> {NEXT} across {len(paths)} files", result.stdout)
            changelog = (root / "CHANGELOG.md").read_text()
            self.assertIn(
                f"## [Unreleased]\n\n## [{NEXT}] - 2026-12-01\n\n### Added\n\n- A test entry.\n\n## [{CURRENT}]",
                changelog,
            )
            self.assertIn(
                f"[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v{NEXT}...HEAD\n"
                f"[{NEXT}]: https://github.com/glowcap-org/glowcap/compare/v{CURRENT}...v{NEXT}\n[{CURRENT}]:",
                changelog,
            )
            for guide in (
                "bindings/ts/web/README.md",
                "bindings/ts/webrtc/README.md",
                "site/content/bindings/browser.smd",
            ):
                text = (root / guide).read_text()
                self.assertIn(f"glowcap-web-v{NEXT}-browser.tar.gz", text)
                self.assertNotIn(f"glowcap-web-v{CURRENT}-browser.tar.gz", text)
            self.assertIn(f'version = "{NEXT}"', (root / "bindings/rust/README.md").read_text())
            # Every mirror now states NEXT exactly where a later bump looks.
            (root / "CHANGELOG.md").write_text(
                changelog.replace("## [Unreleased]\n", "## [Unreleased]\n\n- Next.\n", 1)
            )
            for path, old_text, new_text, once in SET_VERSION.edits(root, NEXT, "0.100.0"):
                self.assertIn(old_text, (root / path).read_text(), path)
            for lock, member in (
                ("apps/rooms/rust/Cargo.lock", "glowcap"),
                ("bindings/python/uv.lock", "glowcap"),
                ("deno.lock", "@glowcap/runtime"),
            ):
                text = (root / lock).read_text()
                self.assertTrue(
                    f'name = "{member}"\nversion = "{NEXT}"' in text or f"jsr:{member}@{NEXT}" in text, lock
                )
                self.assertNotIn(f'name = "{member}"\nversion = "{CURRENT}"', text, lock)
            self.assertNotIn(f'version = "{CURRENT}"', (root / "transports/Cargo.toml").read_text())
            self.assertIn(f'version = "={NEXT}"', (root / "transports/webrtc/Cargo.toml").read_text())
            self.assertNotIn(f'"={CURRENT}"', (root / "transports/webrtc/Cargo.toml").read_text())
            self.assertNotIn(f'"version": "{CURRENT}"', (root / "apps/ocapnviz/deno.json").read_text())
            major, minor, patch = NEXT.split(".")
            self.assertIn(
                f"pub const GLOWCAP_VERSION_MINOR: u32 = {minor};", (root / "src/c_abi/ocapn/mod.zig").read_text()
            )
            self.assertIn(f".major = {major}, .minor = {minor}, .patch = {patch}", (root / "build.zig").read_text())
            self.assertNotIn(f"{CURRENT} alpha", (root / "README.md").read_text())
            self.assertGreaterEqual(len([path for path in paths if path.startswith("bindings/ts/")]), 8)

    def test_refuses_without_writing(self):
        temporary, root, _ = copy_tree()
        with temporary:
            before = snapshot(root)
            changelog = root / "CHANGELOG.md"
            emptied = changelog.read_text().replace("\n### Added\n\n- A test entry.\n", "", 1)
            with_section = emptied.replace(
                "## [Unreleased]\n", f"## [Unreleased]\n\n## [{NEXT}] - 2026-12-01\n\n- By hand.\n", 1
            )
            for arguments, message, text in (
                ((CURRENT,), "is the current version", None),
                (("1.0",), "not a prerelease version", None),
                (("v0.99.0",), "not a prerelease version", None),
                ((), "required: version", None),
                ((NEXT, "--date", "today"), "not a YYYY-MM-DD date", None),
                ((NEXT,), "lists nothing under Unreleased", emptied),
                (
                    (NEXT,),
                    f"both a [{NEXT}] section and Unreleased entries",
                    before[changelog]
                    .decode()
                    .replace("- A test entry.\n", f"- A test entry.\n\n## [{NEXT}] - 2026-12-01\n\n- By hand.\n", 1),
                ),
            ):
                if text is not None:
                    changelog.write_text(text)
                result = run(root, *arguments)
                self.assertNotEqual(result.returncode, 0, arguments)
                self.assertIn(message, result.stderr, arguments)
                changelog.write_bytes(before[changelog])
            self.assertEqual(
                SET_VERSION.changelog_edits(with_section, CURRENT, NEXT, "D"),
                [],
                "a section written by hand stands when Unreleased is empty",
            )
            manifest = root / "bindings/rust/Cargo.toml"
            manifest.write_text(manifest.read_text() + f'\nversion = "{CURRENT}"\n')
            result = run(root, NEXT)
            self.assertEqual(result.returncode, 1)
            self.assertIn("bindings/rust/Cargo.toml states", result.stderr)
            self.assertIn("nothing written", result.stderr)
            manifest.write_bytes(before[manifest])
            self.assertEqual(snapshot(root), before)

    def test_the_build_step_and_the_release_guide_name_the_command(self):
        build = (ROOT / "tools/build/release.zig").read_text()
        self.assertIn('"python3", "tools/gen/set_version.py", requested', build)
        self.assertLess(
            build.index('"tools/gen/set_version.py", requested'),
            build.index('"gen-header-ocapn", "gen-binding-constants", "gen-ts-abi", "gen-rust-wasm-layouts"'),
        )
        tracked = subprocess.check_output(["git", "ls-files", "*Cargo.toml", "*deno.json"], cwd=ROOT, text=True).split()
        touched = mirrors(ROOT)
        for path in tracked:
            if (
                f'version = "{CURRENT}"' in (ROOT / path).read_text()
                or f'"version": "{CURRENT}"' in (ROOT / path).read_text()
            ):
                self.assertIn(path, touched)
        self.assertIn("zig build set-version -Dversion=<version>", (ROOT / "docs/maintaining.md").read_text())
        pages = dict(SET_VERSION.stated_pages(ROOT, CURRENT))
        self.assertIn("README.md", pages)
        self.assertIn("site/content/project.smd", pages, "the code-span form is a stated version too")


if __name__ == "__main__":
    unittest.main()
