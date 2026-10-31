"""site/assets/install.sh: the one-command installer against a local release mirror.

Serves a fake releases listing and a release directory over HTTP from this
process, with a product archive whose bin/glowcap records its arguments, and
runs the installer with its two mirror overrides pointed at that server. The
ordinary path installs the newest release or a pinned version. Every refusal
exits 1 before the product runs, and the checksum file is read before any
archive is requested, so a missing release and a missing platform read
differently. Needs sh, curl, tar, and a checksum tool, as
the installer does.
"""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'site/assets/install.sh'
VERSION = '0.9.0'
TARGET = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}[platform.machine()] \
    + '-' + {'Linux': 'linux', 'Darwin': 'macos'}[platform.system()]
ARCHIVE = f'glowcap-v{VERSION}-{TARGET}.tar.gz'


def product_archive():
    """A product whose bin/glowcap writes its arguments to $GLOWCAP_TEST_RECORD."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        script = b'#!/bin/sh\nprintf \'%s\\n\' "$@" > "$GLOWCAP_TEST_RECORD"\n'
        member = tarfile.TarInfo('bin/glowcap')
        member.size, member.mode = len(script), 0o755
        archive.addfile(member, io.BytesIO(script))
    return buffer.getvalue()


class QuietHandler(SimpleHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        type(self).requests.append(self.path)
        super().do_GET()


class Installer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        mirror = Path(cls.temporary.name) / 'mirror'
        release = mirror / f'v{VERSION}'
        release.mkdir(parents=True)
        archive = product_archive()
        (release / ARCHIVE).write_bytes(archive)
        digest = hashlib.sha256(archive).hexdigest()
        (release / 'SHA256SUMS').write_text(f'{digest}  {ARCHIVE}\n{"0" * 64}  glowcap-c-v{VERSION}-{TARGET}.tar.gz\n')
        (mirror / 'releases.json').write_text(json.dumps([{'tag_name': f'v{VERSION}', 'draft': False, 'prerelease': True}]))
        broken = mirror / 'v0.9.1'
        broken.mkdir()
        (broken / f'glowcap-v0.9.1-{TARGET}.tar.gz').write_bytes(archive)
        (broken / 'SHA256SUMS').write_text(f'{"f" * 64}  glowcap-v0.9.1-{TARGET}.tar.gz\n')
        lacking = mirror / 'v0.9.2'
        lacking.mkdir()
        other = 'aarch64-linux' if TARGET != 'aarch64-linux' else 'x86_64-linux'
        (lacking / 'SHA256SUMS').write_text(f'{"a" * 64}  glowcap-v0.9.2-{other}.tar.gz\n')
        handler = type('Handler', (QuietHandler,), {'directory': str(mirror)})
        handler.__init__ = lambda self, *args, **kwargs: QuietHandler.__init__(self, *args, directory=str(mirror), **kwargs)
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f'http://127.0.0.1:{cls.server.server_address[1]}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.temporary.cleanup()

    def run_installer(self, **env):
        QuietHandler.requests.clear()
        record = Path(self.temporary.name) / 'record'
        record.unlink(missing_ok=True)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('GLOWCAP_')}
        environment.update(GLOWCAP_RELEASES_API=f'{self.base}/releases.json', GLOWCAP_RELEASE_BASE_URL=self.base,
                           GLOWCAP_TEST_RECORD=str(record), TMPDIR=self.temporary.name, **env)
        result = subprocess.run(['sh', str(INSTALLER)], env=environment, cwd=self.temporary.name,
                                capture_output=True, text=True, timeout=20)
        return result, record

    def test_installs_the_newest_release_after_verifying_its_checksum(self):
        result, record = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(record.read_text(), 'install\n')
        self.assertIn(f'verified {ARCHIVE}', result.stdout)
        self.assertEqual(QuietHandler.requests, ['/releases.json', f'/v{VERSION}/SHA256SUMS', f'/v{VERSION}/{ARCHIVE}'])
        self.assertEqual(sorted(Path(self.temporary.name).glob('glowcap-install.*')), [], 'the temporary directory is removed')

    def test_pins_a_version_and_forwards_install_arguments(self):
        result, record = self.run_installer(GLOWCAP_VERSION=VERSION, GLOWCAP_INSTALL_ARGS='--prefix /opt/glowcap')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(record.read_text(), 'install\n--prefix\n/opt/glowcap\n')
        self.assertNotIn('/releases.json', QuietHandler.requests)

    def test_refuses_a_checksum_mismatch_before_running_the_product(self):
        result, record = self.run_installer(GLOWCAP_VERSION='0.9.1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse(record.exists())

    def test_plans_before_it_downloads_and_ends_with_the_path_hint(self):
        result, _ = self.run_installer(GLOWCAP_VERSION=VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = f'glowcap install: v{VERSION} for {TARGET} from {self.base}/v{VERSION}'
        lines = result.stdout.splitlines()
        self.assertIn(plan, lines)
        self.assertLess(lines.index(plan), lines.index(f'glowcap install: downloading {ARCHIVE}'))
        self.assertTrue(lines[-1].startswith('glowcap install: done.'), lines[-1])
        self.assertIn('PATH', lines[-1])
        self.assertTrue(result.stdout.endswith('to your PATH.\n'), result.stdout)

    def test_a_missing_release_names_its_checksum_file_and_requests_no_archive(self):
        result, record = self.run_installer(GLOWCAP_VERSION='0.8.0')
        self.assertEqual(result.returncode, 1)
        self.assertIn('SHA256SUMS', result.stderr)
        self.assertIn('v0.8.0', result.stderr)
        self.assertIn('release may not exist', result.stderr)
        self.assertNotIn('has no product for', result.stderr)
        self.assertEqual(QuietHandler.requests, ['/v0.8.0/SHA256SUMS'])
        self.assertFalse(record.exists())

    def test_refuses_a_release_without_this_platform_before_downloading_an_archive(self):
        result, record = self.run_installer(GLOWCAP_VERSION='0.9.2')
        self.assertEqual(result.returncode, 1)
        self.assertIn(f'release v0.9.2 has no product for {TARGET}', result.stderr)
        self.assertEqual(QuietHandler.requests, ['/v0.9.2/SHA256SUMS'])
        self.assertFalse(record.exists())
        self.assertNotIn('downloading', result.stdout)

    def test_refuses_a_malformed_version_without_any_request(self):
        result, record = self.run_installer(GLOWCAP_VERSION='latest')
        self.assertEqual(result.returncode, 1)
        self.assertIn('unexpected version: latest', result.stderr)
        self.assertEqual(QuietHandler.requests, [], 'nothing is downloaded for a malformed version')
        self.assertFalse(record.exists())

    def test_the_installer_is_the_documented_one_command(self):
        command = 'curl -fsSL https://glowcap.org/install.sh | sh'
        for page in ('README.md', 'apps/rooms/host.md', 'site/content/cli.smd'):
            self.assertIn(command, (ROOT / page).read_text(), page)
        self.assertIn('curl -fsSL https://glowcap.org/install.sh | GLOWCAP_VERSION={version} sh', (ROOT / 'tools/gen/release_notes.py').read_text())
        self.assertIn('.static_assets = ["install.sh"]', (ROOT / 'site/zine.ziggy').read_text())


if __name__ == '__main__':
    unittest.main()
