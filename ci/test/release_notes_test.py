"""Newcomer release notes follow the shipped archives, not publishing internals."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import tarfile

from workflow_test import ROOT, shell_step


SPEC = importlib.util.spec_from_file_location('release_notes', ROOT / 'tools/gen/release_notes.py')
NOTES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTES)
TAG = 'v0.1.0'
COMMIT = 'a' * 40
SOURCE = {'repository': 'https://github.com/owner/project', 'tag': TAG, 'commit': COMMIT,
          'run': 'https://github.com/owner/project/actions/runs/123'}


def fixture(directory, *, missing=None, dirty=False, revision=COMMIT, minimum=None):
    for target in NOTES.PLATFORMS:
        for role in ('product', 'sdk'):
            if missing == (target, role):
                continue
            metadata = {'version': TAG[1:], 'revision': revision, 'target': target, 'dirty': dirty,
                        'minimum_runtime': minimum or ('macOS 15.0.0' if target.endswith('macos') else 'glibc 2.39.0')}
            files = {'README.md': b'Use the product', 'PROVENANCE.md': b'Provenance',
                     'LICENSE-APACHE': b'License', 'LICENSE-THIRD-PARTY': b'Licenses',
                     'share/glowcap/release.json': json.dumps(metadata).encode()}
            names = ('include/glowcap_ocapn.h', 'lib/libglowcap_ocapn.a') if role == 'sdk' else (
                'bin/glowcap', 'libexec/rooms-server', 'libexec/rooms-session',
                'share/glowcap/rooms/page.html', 'share/glowcap/rooms/page.js',
                'share/glowcap/rooms/rooms_browser_bg.wasm',
                'share/glowcap/skills/rooms-peer/SKILL.md', 'share/glowcap/skills/rooms-team/SKILL.md')
            files.update({name: b'content' for name in names if missing != name})
            filename = f'glowcap{"-c" if role == "sdk" else ""}-{TAG}-{target}.tar.gz'
            with tarfile.open(directory / filename, 'w:gz') as archive:
                for name, content in files.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))


class ReleaseNotes(unittest.TestCase):
    def test_every_download_has_a_role_platform_and_minimum_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture(directory)
            notes = NOTES.render(directory, {'source': SOURCE})
            for path in directory.iterdir():
                self.assertIn(f'https://github.com/owner/project/releases/download/{TAG}/{path.name}', notes)
            self.assertIn('Apple Silicon', notes)
            self.assertIn('macOS 15.0.0 or newer', notes)
            self.assertIn('glibc 2.39.0 or newer', notes)
            self.assertIn('The SDK does not contain the CLI or Rooms.', notes)
            self.assertIn('archive=glowcap-v0.1.0-aarch64-macos.tar.gz', notes)
            self.assertIn('./glowcap-unpacked/bin/glowcap install', notes)
            self.assertIn('--predicate-type ' + NOTES.PREDICATE, notes)
            self.assertIn('--signer-workflow owner/project/.github/workflows/release.yml', notes)
            self.assertIn(f'[project provenance](https://github.com/owner/project/blob/{TAG}/PROVENANCE.md)', notes)
            self.assertNotIn('verify build provenance', notes)
            self.assertIn('ghcr.io/owner/project-rooms:v0.1.0 --http-bind=0.0.0.0', notes)
            self.assertIn('127.0.0.1:8080:8080', notes)
            self.assertIn('<!-- glowcap-source-run: 123 -->', notes)

    def test_refuses_incomplete_or_mislabeled_artifacts_before_publication(self):
        for options in ({'missing': ('aarch64-macos', 'product')}, {'missing': 'bin/glowcap'},
                        {'missing': 'share/glowcap/rooms/rooms_browser_bg.wasm'},
                        {'dirty': True}, {'revision': 'b' * 40}, {'minimum': 'glibc 2.39.0'}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                fixture(directory, **options)
                with self.assertRaises((ValueError, KeyError)):
                    NOTES.render(directory, {'source': SOURCE})

    def test_workflow_generates_instructions_before_remote_effects(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        prepare = shell_step(workflow, 'Verify and assemble tested release artifacts')
        self.assertIn('python3 tools/gen/release_notes.py --assets release-assets', prepare)
        self.assertLess(workflow.index('python3 tools/gen/release_notes.py'), workflow.index('- name: Attest release'))
        publish = shell_step(workflow, 'Create the release with archives')
        self.assertIn('--notes-file artifacts/release-notes.md', publish)
        self.assertNotIn('--notes "', publish)
