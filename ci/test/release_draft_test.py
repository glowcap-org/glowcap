"""Release uploads stay private until the complete verified asset set exists."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from workflow_test import ROOT, shell_step


SPEC = importlib.util.spec_from_file_location('release_draft', ROOT / 'tools/check/release_recovery.py')
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)
TAG = 'v0.1.0'


class ReleaseDraft(unittest.TestCase):
    def test_draft_resumes_only_matching_uploaded_assets_from_the_same_source(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                assets = Path('release-assets')
                assets.mkdir()
                names = {Path(name).name for group in RELEASE.inventory(TAG).values()
                         for name in group if name.endswith('.tar.gz')} | {'SHA256SUMS'}
                for name in names:
                    (assets / name).write_bytes(b'approved')
                digest = 'sha256:' + hashlib.sha256(b'approved').hexdigest()
                for case in ('new', 'complete', 'partial', 'published', 'foreign', 'damaged',
                             'extra', 'duplicate', 'unfinished', 'network'):
                    release = {'tag_name': TAG, 'draft': True, 'body': '<!-- glowcap-source-run: 123 -->',
                               'assets': [{'name': name, 'state': 'uploaded', 'digest': digest} for name in names]}
                    if case == 'partial':
                        release['assets'].pop()
                    elif case == 'published':
                        release['draft'] = False
                    elif case == 'foreign':
                        release['body'] = '<!-- glowcap-source-run: 999 -->'
                    elif case == 'damaged':
                        release['assets'][0]['digest'] = 'sha256:' + '0' * 64
                    elif case == 'extra':
                        release['assets'][0]['name'] = 'extra'
                    elif case == 'duplicate':
                        release['assets'].append(dict(release['assets'][0]))
                    elif case == 'unfinished':
                        release['assets'][0]['state'] = 'starter'
                    response = [[]] if case == 'new' else [[release]]
                    def lookup(*args, **kwargs):
                        if case == 'network':
                            raise subprocess.CalledProcessError(1, ['gh', 'api'])
                        return response
                    with self.subTest(case=case), mock.patch.object(RELEASE, 'api', side_effect=lookup):
                        if case in ('new', 'complete', 'partial'):
                            state = RELEASE.release_state('owner/project', '123', TAG)
                            self.assertEqual(state['draft_exists'], case != 'new')
                            self.assertEqual(len(state['missing_assets']), {'new': 9, 'partial': 1, 'complete': 0}[case])
                            if case == 'complete':
                                RELEASE.release_state('owner/project', '123', TAG, complete=True)
                            else:
                                with self.assertRaises(ValueError):
                                    RELEASE.release_state('owner/project', '123', TAG, complete=True)
                        else:
                            with self.assertRaises((ValueError, subprocess.SubprocessError)):
                                RELEASE.release_state('owner/project', '123', TAG)
            finally:
                os.chdir(previous)

    def test_upload_or_verification_failure_never_publishes_the_draft(self):
        script = shell_step((ROOT / '.github/workflows/release.yml').read_text(),
                            'Create the release with archives')
        gh_stub = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
with open('calls', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['release', 'upload']:
    sys.exit(int(os.environ['UPLOAD_STATUS']))
if sys.argv[1:3] == ['release', 'edit']:
    if not Path('verified').exists(): sys.exit(99)
'''
        verifier_stub = '''import os,sys
from pathlib import Path
Path('verification-attempted').touch()
status = int(os.environ['VERIFY_STATUS'])
if not status: Path('verified').touch()
sys.exit(status)
'''
        for draft in (False, True):
            for upload, verify in ((0, 0), (37, 0), (0, 41)):
                with self.subTest(draft=draft, upload=upload, verify=verify), tempfile.TemporaryDirectory() as temp:
                    directory = Path(temp)
                    (directory / 'artifacts').mkdir()
                    (directory / 'artifacts/release-state.json').write_text(json.dumps(
                        {'draft_exists': draft, 'missing_assets': ['one.tar.gz', 'two.tar.gz']}))
                    gh = directory / 'gh'
                    gh.write_text(gh_stub)
                    gh.chmod(0o755)
                    verifier = directory / 'tools/check/release_recovery.py'
                    verifier.parent.mkdir(parents=True)
                    verifier.write_text(verifier_stub)
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=directory,
                                            env=dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                                                     RELEASE_TAG=TAG, SOURCE_RUN='123', GITHUB_REPOSITORY='owner/project',
                                                     UPLOAD_STATUS=str(upload), VERIFY_STATUS=str(verify)),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, upload or verify, result.stderr)
                    calls = [json.loads(line) for line in (directory / 'calls').read_text().splitlines()]
                    creates = [call for call in calls if call[:2] == ['release', 'create']]
                    edits = [call for call in calls if call[:2] == ['release', 'edit']]
                    self.assertEqual(len(creates), int(not draft))
                    if creates:
                        self.assertIn('--draft', creates[0])
                    self.assertEqual(len(edits), int(not upload and not verify))
                    if edits:
                        self.assertIn('--draft=false', edits[0])
                        self.assertEqual(edits[0][-2:], ['--notes-file', 'artifacts/release-notes.md'])
                    self.assertEqual((directory / 'verification-attempted').exists(), not upload)
