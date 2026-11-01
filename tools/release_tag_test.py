"""The release-tag front signs and pushes a promoted version's tag, or refuses before the push.

These tests drive tools/release-tag.py against a local bare origin, a working
clone, and a stub gh placed first on PATH. They prove the ordinary signed tag
push, that every refusal exits 1 and leaves origin without the tag, that
nothing is signed before validation passes, that a stale local tag is never
moved or pushed, that a published version is never replaced, that a failed push
keeps the signed tag for the retry, and that a stalled gh is a refusal, not a
traceback. A failure here means the maintainer could publish a tag main did not
earn, or lose the guarantee that a refusal changes nothing on origin.

Run it with `python3 tools/release_tag_test.py`. infrastructure-check
registers it in tools/build/infrastructure.zig. It needs git, python3, and
ssh-keygen: the fixture signs with an unprotected ed25519 key file through
`gpg.ssh.program ssh-keygen`, so no agent, passphrase prompt, GnuPG, GitHub
credential, or network is used. Git runs without the host's global or system
configuration, and every subprocess has a deadline.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
RELEASE = ROOT / 'tools/release-tag.py'
TIMEOUT = 20
# The stub answers the requests the front and ci/require_main_check.py make.
GH_STUB = r'''#!/usr/bin/env python3
import os
import sys
import time

args = " ".join(sys.argv[1:])
if os.environ.get("GLOWCAP_TEST_GH_HANG"):
    time.sleep(60)
if args == "repo view --json nameWithOwner -q .nameWithOwner":
    print("test-org/glowcap")
elif "/compare/" in args:
    sys.stdout.write('{"status":"identical"}')
elif "check.yml/runs" in args:
    sys.stdout.write(open(os.environ["GLOWCAP_TEST_RUNS"]).read())
elif "/jobs?per_page=100" in args:
    sys.stdout.write('{"jobs":[{"name":"gates","status":"completed","conclusion":"success"},'
                     '{"name":"macos-runtime","status":"completed","conclusion":"success"}]}')
else:
    sys.stderr.write("gh stub: unexpected " + args + "\n")
    sys.exit(1)
'''
REJECT_TAGS = '''#!/bin/sh
while read old new ref; do
    case "$ref" in refs/tags/*) echo "tag pushes are closed" >&2; exit 1 ;; esac
done
'''


def load_front():
    spec = importlib.util.spec_from_file_location('release_tag', RELEASE)
    front = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(front)
    return front


class ReleaseTagTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        keys = tempfile.TemporaryDirectory()
        cls.addClassCleanup(keys.cleanup)
        cls.keys = Path(keys.name)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'test@glowcap.invalid',
                        '-f', str(cls.keys / 'signing-key')], check=True, timeout=TIMEOUT,
                       stdin=subprocess.DEVNULL)
        public = (cls.keys / 'signing-key.pub').read_text().split()[:2]
        (cls.keys / 'allowed_signers').write_text(
            f'test@glowcap.invalid namespaces="git" {public[0]} {public[1]}\n')

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.repo = self.scratch / 'local'
        self.origin = self.scratch / 'origin.git'
        bin_dir = self.scratch / 'bin'
        bin_dir.mkdir()
        stub = bin_dir / 'gh'
        stub.write_text(GH_STUB)
        stub.chmod(0o755)
        self.runs = self.scratch / 'runs.json'
        self.env = {
            **{key: value for key, value in os.environ.items() if key != 'SSH_AUTH_SOCK'},
            'PATH': f'{bin_dir}{os.pathsep}{os.environ["PATH"]}',
            'GLOWCAP_TEST_RUNS': str(self.runs),
            'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_TERMINAL_PROMPT': '0',
            'GIT_CEILING_DIRECTORIES': str(self.scratch),
        }
        self.git('init', '-qb', 'dev', str(self.repo), cwd=self.scratch)
        for key, value in (
            ('user.name', 'glowcap test'),
            ('user.email', 'test@glowcap.invalid'),
            ('commit.gpgsign', 'false'),
            ('gpg.format', 'ssh'),
            # The host may route ssh signing through an agent that prompts; the fixture signs with the file.
            ('gpg.ssh.program', 'ssh-keygen'),
            ('user.signingkey', str(self.keys / 'signing-key')),
            ('gpg.ssh.allowedSignersFile', str(self.keys / 'allowed_signers')),
        ):
            self.git('config', key, value)
        (self.repo / 'bindings').mkdir()
        (self.repo / 'bindings/c-abi-resolve.json').write_text('{"abi_version": "0.9.0"}\n')
        (self.repo / 'CHANGELOG.md').write_text(
            '# Changelog\n\n## [Unreleased]\n\n## [0.9.0] - 2026-01-01\n\n- First.\n')
        self.git('add', '-A')
        self.git('commit', '-qm', 'release 0.9.0')
        self.git('branch', 'main')
        self.git('init', '-q', '--bare', str(self.origin), cwd=self.scratch)
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-q', 'origin', 'main', 'dev')
        self.commit = self.git('rev-parse', 'main')
        self.write_runs(self.commit, 'success')

    def git(self, *args, cwd=None):
        done = subprocess.run(['git', *args], cwd=cwd or self.repo, env=self.env, check=True,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
                              timeout=TIMEOUT)
        return done.stdout.strip()

    def origin_git(self, *args):
        return self.git('--git-dir', str(self.origin), *args)

    def write_runs(self, commit, conclusion):
        self.runs.write_text(json.dumps({'workflow_runs': [{
            'id': 7, 'run_attempt': 1, 'head_sha': commit, 'event': 'push', 'head_branch': 'dev',
            'status': 'completed', 'conclusion': conclusion,
            'html_url': 'https://example.invalid/runs/7',
            'head_repository': {'full_name': 'test-org/glowcap'}}]}))

    def front(self, *args, cwd=None):
        """Run the front as a program from the clone, returning its status and merged output."""
        done = subprocess.run([str(RELEASE), *args], cwd=cwd or self.repo, env=self.env,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, timeout=TIMEOUT)
        return done.returncode, done.stdout

    def refuse(self, *args, message, cwd=None, origin_tags=''):
        """A refusal exits 1 with its message and leaves origin's tags as they were."""
        status, output = self.front(*args, cwd=cwd)
        self.assertEqual(status, 1, output)
        self.assertIn(message, output)
        self.assertTrue(output.rstrip().splitlines()[-1].startswith('release-tag: '), output)
        self.assertEqual(self.origin_git('tag', '-l'), origin_tags)
        return output

    def test_the_front_is_an_executable_program(self):
        self.assertTrue(os.access(RELEASE, os.X_OK))

    def test_usage_needs_exactly_one_version(self):
        self.refuse(message='usage: tools/release-tag.py <version>')
        self.refuse('0.9.0', '0.9.1', message='usage: tools/release-tag.py <version>')

    def test_a_version_that_is_not_a_prerelease_is_refused(self):
        for version in ('0.9', '1.0.0', '0.9.0-rc1', 'v0.9.0'):
            self.refuse(version, message='not a prerelease version')

    def test_outside_a_worktree_is_refused(self):
        plain = self.scratch / 'plain'
        plain.mkdir()
        self.refuse('0.9.0', message='not inside a Git worktree', cwd=plain)

    def test_a_version_main_does_not_state_is_refused(self):
        self.refuse('0.9.1', message='states 0.9.0, not 0.9.1')

    def test_failed_validation_is_refused_before_anything_is_signed(self):
        self.write_runs(self.commit, 'failure')
        self.refuse('0.9.0', message='no successful full validation')
        self.assertEqual(self.git('tag', '-l', 'v0.9.0'), '')

    def test_a_stale_local_tag_at_another_commit_is_never_moved_or_pushed(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'other')
        other = self.git('rev-parse', 'HEAD')
        self.git('tag', 'v0.9.0', 'HEAD')
        output = self.refuse('0.9.0', message='points at')
        self.assertIn(other, output)
        self.assertEqual(self.git('rev-parse', 'v0.9.0^{commit}'), other)

    def test_the_ordinary_path_pushes_a_signed_tag(self):
        status, output = self.front('0.9.0')
        self.assertEqual(status, 0, output)
        self.assertIn(f'pushed v0.9.0 at {self.commit}, validated by https://example.invalid/runs/7', output)
        self.assertIn('https://github.com/test-org/glowcap/actions/workflows/release.yml', output)
        self.assertEqual(self.origin_git('rev-parse', 'v0.9.0^{commit}'), self.commit)
        subprocess.run(['git', 'verify-tag', 'v0.9.0'], cwd=self.repo, env=self.env, check=True,
                       stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=TIMEOUT)

    def test_a_published_version_is_never_replaced(self):
        self.assertEqual(self.front('0.9.0')[0], 0)
        self.refuse('0.9.0', message='already on origin', origin_tags='v0.9.0')

    def test_a_promoted_bump_without_its_changelog_section_is_refused_before_signing(self):
        (self.repo / 'bindings/c-abi-resolve.json').write_text('{"abi_version": "0.9.1"}\n')
        self.git('commit', '-qam', 'bump without notes')
        self.git('push', '-q', 'origin', 'dev:main')
        self.write_runs(self.git('rev-parse', 'dev'), 'success')
        self.refuse('0.9.1', message='no [0.9.1] section')
        self.assertEqual(self.git('tag', '-l', 'v0.9.1'), '')

    def test_a_failed_push_keeps_the_signed_tag_for_the_retry(self):
        hook = self.origin / 'hooks/pre-receive'
        hook.write_text(REJECT_TAGS)
        hook.chmod(0o755)
        self.refuse('0.9.0', message='pushing v0.9.0 failed; the signed tag is kept locally')
        signed = self.git('rev-parse', 'v0.9.0')
        self.assertEqual(self.git('rev-parse', 'v0.9.0^{commit}'), self.commit)
        hook.unlink()
        status, output = self.front('0.9.0')
        self.assertEqual(status, 0, output)
        self.assertEqual(self.origin_git('rev-parse', 'v0.9.0'), signed)

    def test_a_stalled_gh_is_a_refusal_not_a_traceback(self):
        front = load_front()
        errors = io.StringIO()
        environment = {**self.env, 'GLOWCAP_TEST_GH_HANG': '1'}
        previous = Path.cwd()
        try:
            os.chdir(self.repo)
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(front, 'GH_TIMEOUT', 1), \
                    contextlib.redirect_stderr(errors):
                status = front.main(['0.9.0'])
        finally:
            os.chdir(previous)
        self.assertEqual(status, 1)
        self.assertIn('release-tag: gh did not name the repository within 1 seconds', errors.getvalue())
        self.assertNotIn('Traceback', errors.getvalue())
        self.assertEqual(self.origin_git('tag', '-l'), '')
        self.assertEqual(self.git('tag', '-l', 'v0.9.0'), '')


if __name__ == '__main__':
    unittest.main()
