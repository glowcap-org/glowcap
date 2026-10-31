"""Publication accepts only the signed source run and its exact tested bytes."""

import copy
import hashlib
import io
import importlib.util
import os
import json
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

from workflow_test import ROOT, shell_step


SPEC = importlib.util.spec_from_file_location('release_recovery', ROOT / 'tools/check/release_recovery.py')
RECOVERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECOVERY)
REPOSITORY = 'owner/project'
COMMIT = 'a' * 40
TAG = 'v0.1.0'


def responses():
    jobs = [{'name': name, 'status': 'completed', 'conclusion': 'success'} for name in {
        'contract', *RECOVERY.IMAGE_JOBS,
        *(f'archives ({runner}, {target})' for runner, (_, target) in RECOVERY.HOSTS.items()),
    }]
    artifacts = [{'id': index, 'name': name, 'expired': False, 'size_in_bytes': 10,
                  'digest': 'sha256:' + 'b' * 64, 'workflow_run': {'id': 123, 'head_sha': COMMIT}}
                 for index, name in enumerate(RECOVERY.inventory(TAG), 1)]
    return {
        f'git/ref/tags/{TAG}': {'object': {'type': 'tag', 'sha': 'c' * 40}},
        'git/tags/' + 'c' * 40: {'verification': {'verified': True},
                                'object': {'type': 'commit', 'sha': COMMIT}},
        'actions/runs/123': {'event': 'push', 'head_branch': TAG, 'head_sha': COMMIT,
                            'path': '.github/workflows/release.yml', 'status': 'completed',
                            'conclusion': 'success', 'head_repository': {'full_name': REPOSITORY}},
        'actions/runs/123/jobs?filter=latest&per_page=100': [{'jobs': jobs}],
        'actions/runs/123/artifacts?per_page=100': [{'artifacts': artifacts}],
    }


class ReleaseRecovery(unittest.TestCase):
    def test_source_requires_signed_tag_matching_run_and_successful_producers(self):
        source = responses()
        mutations = [
            (f'git/ref/tags/{TAG}', ['object', 'type'], 'commit'),
            ('git/tags/' + 'c' * 40, ['verification', 'verified'], False),
            ('actions/runs/123', ['event'], 'workflow_dispatch'),
            ('actions/runs/123', ['head_branch'], 'dev'),
            ('actions/runs/123', ['head_sha'], 'd' * 40),
            ('actions/runs/123', ['path'], '.github/workflows/check.yml'),
            ('actions/runs/123', ['head_repository', 'full_name'], 'other/project'),
            ('actions/runs/123', ['status'], 'in_progress'),
            ('actions/runs/123', ['conclusion'], 'cancelled'),
        ]
        for endpoint, keys, value in [(None, [], None), *mutations]:
            candidate = copy.deepcopy(source)
            if endpoint:
                parent = candidate[endpoint]
                for key in keys[:-1]:
                    parent = parent[key]
                parent[keys[-1]] = value
            with self.subTest(endpoint=endpoint, keys=keys), mock.patch.object(
                    RECOVERY, 'api', side_effect=lambda repo, path, **kw: candidate[path]):
                if endpoint:
                    with self.assertRaises(ValueError):
                        RECOVERY.validate_source(REPOSITORY, '123', TAG)
                else:
                    commit, artifacts = RECOVERY.validate_source(REPOSITORY, '123', TAG)
                    self.assertEqual(commit, COMMIT)
                    self.assertEqual(len(artifacts), 6)
        for job in source['actions/runs/123/jobs?filter=latest&per_page=100'][0]['jobs']:
            for conclusion in ('failure', 'skipped', 'cancelled'):
                with self.subTest(job=job['name'], conclusion=conclusion):
                    saved = job['conclusion']
                    job['conclusion'] = conclusion
                    with mock.patch.object(RECOVERY, 'api', side_effect=lambda repo, path, **kw: source[path]):
                        with self.assertRaisesRegex(ValueError, 'producer did not pass'):
                            RECOVERY.validate_source(REPOSITORY, '123', TAG)
                    job['conclusion'] = saved

    def test_active_run_requires_exact_current_tag_context(self):
        source = responses()
        source['actions/runs/123']['status'] = 'in_progress'
        env = {'GITHUB_RUN_ID': '123', 'GITHUB_SHA': COMMIT,
               'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': f'refs/tags/{TAG}'}
        with mock.patch.object(RECOVERY, 'api', side_effect=lambda repo, path, **kw: source[path]):
            with mock.patch.dict(os.environ, env):
                RECOVERY.validate_source(REPOSITORY, '123', TAG, current=True)
            for key in env:
                with self.subTest(key=key), mock.patch.dict(os.environ, {**env, key: 'wrong'}):
                    with self.assertRaisesRegex(ValueError, 'not ready'):
                        RECOVERY.validate_source(REPOSITORY, '123', TAG, current=True)

    def test_missing_duplicate_expired_or_unbound_artifacts_are_refused(self):
        for problem in ('missing', 'duplicate', 'expired', 'digest', 'commit', 'run'):
            source = responses()
            artifacts = source['actions/runs/123/artifacts?per_page=100'][0]['artifacts']
            if problem == 'missing':
                artifacts.pop()
            elif problem == 'duplicate':
                artifacts.append(copy.deepcopy(artifacts[0]))
            elif problem in ('expired', 'digest'):
                artifacts[0][problem] = True if problem == 'expired' else None
            else:
                artifacts[0]['workflow_run']['head_sha' if problem == 'commit' else 'id'] = 'wrong'
            with self.subTest(problem=problem), mock.patch.object(
                    RECOVERY, 'api', side_effect=lambda repo, path, **kw: source[path]):
                with self.assertRaises(ValueError):
                    RECOVERY.validate_source(REPOSITORY, '123', TAG)

    def test_unpack_refuses_extra_paths_symlinks_and_bad_checksums(self):
        name = 'release/product.tar.gz'
        digest = hashlib.sha256(b'product').hexdigest()
        for problem in (None, 'path', 'symlink', 'checksum', 'missing'):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                archive = root / 'artifact.zip'
                with zipfile.ZipFile(archive, 'w') as output:
                    entry = zipfile.ZipInfo(name)
                    if problem == 'symlink':
                        entry.external_attr = 0o120777 << 16
                    if problem != 'missing':
                        output.writestr(entry, b'product')
                    output.writestr('release/SHA256SUMS',
                                    f'{"0" * 64 if problem == "checksum" else digest}  product.tar.gz\n')
                    if problem == 'path':
                        output.writestr('../escape', b'untrusted')
                if problem:
                    with self.assertRaises(ValueError):
                        RECOVERY.unpack(archive, root / 'output', {name: 'release/SHA256SUMS'})
                else:
                    RECOVERY.unpack(archive, root / 'output', {name: 'release/SHA256SUMS'})
                    self.assertEqual((root / 'output' / name).read_bytes(), b'product')
                self.assertFalse((root / 'escape').exists())

    def test_prepare_checks_github_digest_before_extracting(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                artifact = {'id': 1, 'name': 'rooms-image-amd64', 'digest': 'sha256:' + '0' * 64}
                def download(command, *, stdout, **kwargs):
                    stdout.write(b'wrong artifact')
                with mock.patch.object(RECOVERY.subprocess, 'run', side_effect=download), \
                        mock.patch.object(RECOVERY, 'unpack') as unpack:
                    with self.assertRaisesRegex(ValueError, 'GitHub artifact digest mismatch'):
                        RECOVERY.prepare(REPOSITORY, '123', TAG, COMMIT, [artifact])
                    unpack.assert_not_called()
            finally:
                os.chdir(previous)

    def test_prepare_preserves_every_archive_byte(self):
        payloads, artifacts = {}, []
        for index, (name, expected) in enumerate(RECOVERY.inventory(TAG).items(), 1):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, 'w') as output:
                for product, checksum in expected.items():
                    data = product.encode()
                    output.writestr(product, data)
                    output.writestr(checksum, f'{hashlib.sha256(data).hexdigest()}  {Path(product).name}\n')
            payloads[index] = buffer.getvalue()
            artifacts.append({'id': index, 'name': name,
                              'digest': 'sha256:' + hashlib.sha256(payloads[index]).hexdigest()})
        with tempfile.TemporaryDirectory() as temp:
            previous = Path.cwd()
            os.chdir(temp)
            try:
                def download(command, *, stdout, **kwargs):
                    stdout.write(payloads[int(command[-1].split('/')[-2])])
                with mock.patch.object(RECOVERY.subprocess, 'run', side_effect=download):
                    RECOVERY.prepare(REPOSITORY, '123', TAG, COMMIT, artifacts)
                archives = list(Path('release-assets').glob('*.tar.gz'))
                self.assertEqual(len(archives), 8)
                for archive in archives:
                    original = next(product for expected in RECOVERY.inventory(TAG).values()
                                    for product in expected if Path(product).name == archive.name)
                    self.assertEqual(archive.read_bytes(), original.encode())
                lines = Path('release-assets/SHA256SUMS').read_text().splitlines()
                self.assertEqual(len(lines), 8)
                self.assertEqual([line.split()[1] for line in lines], sorted(archive.name for archive in archives))
            finally:
                os.chdir(previous)

    def test_image_publication_reuses_matching_tags_and_refuses_conflicts(self):
        script = shell_step((ROOT / '.github/workflows/release.yml').read_text(),
                            'Publish the versioned multi-platform Rooms image')
        stub = r'''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open('calls', 'a') as output:
    output.write(json.dumps(args) + '\n')
mode = os.environ['IMAGE_MODE']
def manifest(arch):
    return json.dumps({'config': {'digest': 'sha256:expected'}, 'arch': arch})
def index():
    return json.dumps({'manifests': [
        {'platform': {'os': 'linux', 'architecture': arch},
         'digest': 'sha256:' + hashlib.sha256((manifest(arch) + '\n').encode()).hexdigest()}
        for arch in ('amd64', 'arm64')]})
if args[0] == 'login':
    sys.stdin.read()
elif args[:2] == ['image', 'inspect']:
    print('sha256:expected')
elif args[:2] == ['image', 'push']:
    Path(args[-1].split('-')[-1] + '.pushed').touch()
elif args[:3] == ['buildx', 'imagetools', 'create']:
    Path('index.pushed').touch()
elif args[:3] == ['buildx', 'imagetools', 'inspect']:
    arch = args[-1].split('-')[-1]
    arch = arch if arch in ('amd64', 'arm64') else 'index'
    if mode == 'network':
        sys.exit('connection refused')
    if ((mode == 'new' or (mode == 'partial' and arch != 'amd64')
         or (mode == 'missing-platform' and arch == 'amd64'))
        and not Path(arch + '.pushed').exists()):
        sys.exit('manifest unknown')
    if mode == 'conflict' and arch == 'arm64':
        print(json.dumps({'config': {'digest': 'sha256:other'}}))
    elif arch == 'index':
        print(index().replace('sha256:', 'sha256:other') if mode == 'index-conflict' else index())
    else:
        print(manifest(arch))
'''
        for mode in ('new', 'existing', 'partial', 'conflict', 'index-conflict', 'missing-platform', 'network'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                docker = directory / 'docker'
                docker.write_text(stub)
                docker.chmod(0o755)
                # The publisher runs on Linux. Supply its checksum command on
                # macOS too, where infrastructure-check exercises this shell.
                checksum = directory / 'sha256sum'
                checksum.write_text('#!/usr/bin/env python3\nimport hashlib,sys\nfrom pathlib import Path\n'
                                    'if sys.argv[1:]:\n'
                                    '    for line in Path(sys.argv[2]).read_text().splitlines():\n'
                                    '        digest,name = line.split()\n'
                                    '        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest: sys.exit(1)\n'
                                    'else: print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())\n')
                checksum.chmod(0o755)
                for arch in ('amd64', 'arm64'):
                    image = directory / f'artifacts/rooms-image-{arch}'
                    image.mkdir(parents=True)
                    name = f'glowcap-rooms-{TAG}-{arch}.docker.tar'
                    (image / name).write_bytes(b'image')
                    (image / 'SHA256SUMS').write_text(f'{hashlib.sha256(b"image").hexdigest()}  {name}\n')
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=directory,
                                        env=dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                                                 GH_TOKEN='test', IMAGE='ghcr.io/owner/rooms', VERSION='0.1.0',
                                                 GITHUB_ACTOR='actor', IMAGE_MODE=mode,
                                                 GITHUB_OUTPUT=str(directory / 'output')),
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, mode in ('new', 'existing', 'partial'), result.stderr)
                if result.returncode == 0:
                    # The attestation subject is the digest of the index the registry serves.
                    self.assertRegex((directory / 'output').read_text(), r'^digest=sha256:[0-9a-f]{64}\n$')
                calls = [json.loads(line) for line in (directory / 'calls').read_text().splitlines()]
                effects = [call for call in calls if call[:2] == ['image', 'push'] or
                           call[:3] == ['buildx', 'imagetools', 'create']]
                self.assertEqual(len(effects), {'new': 3, 'partial': 2}.get(mode, 0), calls)

    def test_published_release_requires_a_public_complete_release_of_the_signed_tag(self):
        names = sorted({Path(name).name for group in RECOVERY.inventory(TAG).values()
                        for name in group if name.endswith('.tar.gz')} | {'SHA256SUMS'})
        release = {'draft': False, 'tag_name': TAG,
                   'assets': [{'name': name, 'state': 'uploaded'} for name in names]}
        answers = {**responses(), f'releases/tags/{TAG}': release}
        with mock.patch.object(RECOVERY, 'api', lambda repository, endpoint, pages=False: answers[endpoint]):
            self.assertEqual(RECOVERY.signed_commit(REPOSITORY, TAG), COMMIT)
            self.assertEqual(RECOVERY.published_release(REPOSITORY, TAG), release)
            for broken in ({'draft': True}, {'assets': release['assets'][1:]},
                           {'assets': release['assets'] + [{'name': 'extra.tar.gz', 'state': 'uploaded'}]},
                           {'assets': [dict(asset, state='starter') for asset in release['assets']]}):
                with self.subTest(broken=broken):
                    answers[f'releases/tags/{TAG}'] = {**release, **broken}
                    with self.assertRaises(ValueError):
                        RECOVERY.published_release(REPOSITORY, TAG)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            output.write_text('')
            with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': REPOSITORY, 'GITHUB_OUTPUT': str(output)}), \
                    mock.patch.object(RECOVERY, 'signed_commit', return_value=COMMIT), \
                    mock.patch.object(RECOVERY, 'published_release', return_value=release), \
                    mock.patch.object(RECOVERY.subprocess, 'run') as run, \
                    mock.patch.object(RECOVERY.sys, 'argv', ['release_recovery.py', '--published', TAG]):
                RECOVERY.main()
            self.assertEqual(run.call_args[0][0][1:], ['tools/check/require-main-check.py', COMMIT])
            self.assertEqual(output.read_text(), f'version=0.1.0\ntag={TAG}\ncommit={COMMIT}\n')
            with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': REPOSITORY}), \
                    mock.patch.object(RECOVERY.sys, 'argv', ['release_recovery.py', '--published', '123', TAG]), \
                    self.assertRaises(ValueError):
                RECOVERY.main()

    def test_publication_predicate_identifies_original_source_and_publication(self):
        with mock.patch.dict(os.environ, {'GITHUB_RUN_ID': '456',
                             'GITHUB_WORKFLOW_REF': 'owner/project/.github/workflows/release.yml@refs/heads/fix'}):
            predicate = RECOVERY.provenance(REPOSITORY, '123', TAG, COMMIT, [])
        self.assertEqual(predicate['source']['run'], f'https://github.com/{REPOSITORY}/actions/runs/123')
        self.assertEqual(predicate['source']['commit'], COMMIT)
        self.assertTrue(predicate['publication']['run'].endswith('/456'))
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertIn('predicate-path: artifacts/publication-provenance.json', workflow)
        self.assertIn('predicate-type: https://glowcap.org/attestations/release-publication/v1', workflow)
        script = shell_step(workflow, 'Create the release with archives')
        self.assertIn('gh release create "$RELEASE_TAG"', script)
        self.assertNotIn('GITHUB_REF_NAME', script)
