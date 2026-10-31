"""tools/gen/set_version.py: the one-command version bump on a copy of the tree.

Copies every file the bump edits into a temporary tree and runs the script
there, so the test proves the script's patterns against the checkout's own
files without touching the checkout. The ordinary path moves every mirror. Each
refusal exits 1 and writes nothing.
"""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/gen/set_version.py'
SPEC = importlib.util.spec_from_file_location('set_version', SCRIPT)
SET_VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SET_VERSION)
CURRENT = json.loads((ROOT / 'bindings/c-abi-resolve.json').read_text())['abi_version']
NEXT = '0.99.0'


def copy_tree():
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name)
    paths = {path for path, _, _, _ in SET_VERSION.edits(ROOT, CURRENT, NEXT)} | {'CHANGELOG.md'}
    for path in paths:
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / path, root / path)
    # The script lists manifests and locks with git, so the copy is a repository.
    subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=root, check=True)
    return temporary, root, paths


def snapshot(root):
    return {path: path.read_bytes() for path in root.rglob('*') if path.is_file()}


def run(root, *args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=root, capture_output=True, text=True, timeout=20)


class SetVersion(unittest.TestCase):
    def test_moves_every_mirror_of_the_version(self):
        temporary, root, paths = copy_tree()
        with temporary:
            changelog = root / 'CHANGELOG.md'
            changelog.write_text(changelog.read_text().replace('## [Unreleased]\n', f'## [Unreleased]\n\n## [{NEXT}] - 2026-12-01\n\n### Added\n\n- A test entry.\n', 1))
            result = run(root, NEXT)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'{CURRENT} -> {NEXT} across {len(paths) - 1} files', result.stdout)
            for path, old_text, new_text, once in SET_VERSION.edits(root, NEXT, '0.100.0'):
                self.assertIn(old_text, (root / path).read_text(), path)
            for lock, member in (('apps/rooms/rust/Cargo.lock', 'glowcap'), ('deno.lock', '@glowcap/runtime')):
                text = (root / lock).read_text()
                self.assertTrue(f'name = "{member}"\nversion = "{NEXT}"' in text or f'jsr:{member}@{NEXT}' in text, lock)
            self.assertNotIn(f'version = "{CURRENT}"', (root / 'transports/Cargo.toml').read_text())
            self.assertIn(f'version = "={NEXT}"', (root / 'transports/webrtc/Cargo.toml').read_text())
            self.assertNotIn(f'"={CURRENT}"', (root / 'transports/webrtc/Cargo.toml').read_text())
            self.assertNotIn(f'"version": "{CURRENT}"', (root / 'apps/ocapnviz/deno.json').read_text())
            major, minor, patch = NEXT.split('.')
            self.assertIn(f'pub const GLOWCAP_VERSION_MINOR: u32 = {minor};', (root / 'src/c_abi/ocapn/mod.zig').read_text())
            self.assertIn(f'.major = {major}, .minor = {minor}, .patch = {patch}', (root / 'build.zig').read_text())
            self.assertNotIn(f'{CURRENT} alpha', (root / 'README.md').read_text())
            self.assertGreaterEqual(len([path for path in paths if path.startswith('bindings/ts/')]), 8)

    def test_refuses_without_writing(self):
        temporary, root, _ = copy_tree()
        with temporary:
            before = snapshot(root)
            for arguments, message in (((CURRENT,), 'is the current version'), (('1.0',), 'one prerelease version'),
                                       (('v0.99.0',), 'one prerelease version'), ((), 'one prerelease version'),
                                       ((NEXT,), f'no "## [{NEXT}]" section')):
                result = run(root, *arguments)
                self.assertEqual(result.returncode, 1, arguments)
                self.assertIn(message, result.stderr, arguments)
            manifest = root / 'bindings/rust/Cargo.toml'
            manifest.write_text(manifest.read_text() + f'\nversion = "{CURRENT}"\n')
            result = run(root, NEXT)
            self.assertEqual(result.returncode, 1)
            self.assertIn('bindings/rust/Cargo.toml states', result.stderr)
            self.assertIn('nothing written', result.stderr)
            manifest.write_bytes(before[manifest])
            self.assertEqual(snapshot(root), before)

    def test_the_build_step_and_the_release_guide_name_the_command(self):
        build = (ROOT / 'tools/build/release.zig').read_text()
        self.assertIn('"python3", "tools/gen/set_version.py", requested', build)
        self.assertLess(build.index('"tools/gen/set_version.py", requested'), build.index('"gen-header-ocapn", "gen-binding-constants", "gen-ts-abi", "gen-rust-wasm-layouts"'))
        tracked = subprocess.check_output(['git', 'ls-files', '*Cargo.toml', '*deno.json'], cwd=ROOT, text=True).split()
        touched = {path for path, _, _, _ in SET_VERSION.edits(ROOT, CURRENT, NEXT)}
        for path in tracked:
            if f'version = "{CURRENT}"' in (ROOT / path).read_text() or f'"version": "{CURRENT}"' in (ROOT / path).read_text():
                self.assertIn(path, touched)
        self.assertIn('zig build set-version -Dversion=<version>', (ROOT / 'docs/maintaining.md').read_text())
        pages = dict(SET_VERSION.stated_pages(ROOT, CURRENT))
        self.assertIn('README.md', pages)
        self.assertIn('site/content/project.smd', pages, 'the code-span form is a stated version too')


if __name__ == '__main__':
    unittest.main()
