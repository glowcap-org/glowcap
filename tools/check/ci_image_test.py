"""CI image preparation contracts, collected by publication_workflow_test.py."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_image', ROOT / '.devcontainer/ci/image.py')
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)
DIGEST = 'sha256:' + 'a' * 64
REF = 'ghcr.io/glowcap-org/glowcap/devcontainer@' + DIGEST


class ImageTest(unittest.TestCase):
    def test_warm_image_never_builds_or_publishes(self):
        with mock.patch.object(IMAGE, 'resolve', return_value=REF), \
                mock.patch.object(IMAGE, 'fingerprint', return_value='b' * 64), \
                mock.patch.object(IMAGE, 'reference', return_value=REF.split('@')[0]), \
                mock.patch.object(IMAGE, 'run') as run, \
                mock.patch.object(IMAGE, 'output') as output:
            IMAGE.prepare(False)
            run.assert_not_called()
            output.assert_called_once_with(image=REF, archive='false')

    def test_cold_paths_build_once_and_only_trusted_run_publishes(self):
        for publish in (False, True):
            with self.subTest(publish=publish), \
                    mock.patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'push',
                                    'GITHUB_REF': 'refs/heads/dev', 'RUNNER_TEMP': '/tmp'}), \
                    mock.patch.object(IMAGE, 'resolve', side_effect=[None, REF]), \
                    mock.patch.object(IMAGE, 'fingerprint', return_value='b' * 64), \
                    mock.patch.object(IMAGE, 'reference', return_value=REF.split('@')[0]), \
                    mock.patch.object(IMAGE, 'run', return_value=DIGEST) as run, \
                    mock.patch.object(IMAGE, 'output') as output:
                IMAGE.prepare(publish)
                calls = [call.args for call in run.call_args_list]
                self.assertEqual(sum(call[:2] == ('devcontainer', 'build') for call in calls), 1)
                self.assertEqual(any(call[:2] == ('docker', 'push') for call in calls), publish)
                self.assertEqual(any(call[:2] == ('docker', 'save') for call in calls), not publish)
                output.assert_called_once_with(image=REF if publish else DIGEST,
                                               archive='false' if publish else 'true')
        with mock.patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/heads/dev'}), \
                mock.patch.object(IMAGE, 'run') as run:
            with self.assertRaises(ValueError):
                IMAGE.prepare(True)
            run.assert_not_called()

    def test_failed_alias_update_cannot_leave_a_completed_cache_entry(self):
        published = set()
        repository = REF.split('@')[0]
        tag = repository + ':inputs-' + 'b' * 64

        def publish(*args, **kwargs):
            if args[:2] == ('docker', 'push'):
                if args[2] == repository + ':ci':
                    raise subprocess.CalledProcessError(1, args)
                published.add(args[2])
            return ''

        with mock.patch.dict(os.environ, {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/dev'}), \
                mock.patch.object(IMAGE, 'reference', return_value=repository), \
                mock.patch.object(IMAGE, 'fingerprint', return_value='b' * 64), \
                mock.patch.object(IMAGE, 'resolve', side_effect=lambda value, **kw: REF if value in published else None), \
                mock.patch.object(IMAGE, 'run', side_effect=publish), \
                mock.patch.object(IMAGE, 'output') as output:
            for attempt in range(2):
                with self.subTest(attempt=attempt):
                    with self.assertRaises(subprocess.CalledProcessError):
                        IMAGE.prepare(True)
                    self.assertNotIn(tag, published)
            output.assert_not_called()

    def test_lookup_distinguishes_miss_permissions_and_outage(self):
        for message, readonly, allowed in [('manifest unknown', False, True),
                                          ('403 denied', True, True),
                                          ('403 denied', False, False),
                                          ('connection timed out', True, False)]:
            result = subprocess.CompletedProcess([], 1, '', message)
            with self.subTest(message=message, readonly=readonly), \
                    mock.patch.object(IMAGE.subprocess, 'run', return_value=result):
                if allowed:
                    self.assertIsNone(IMAGE.resolve(REF.split('@')[0] + ':test', readonly=readonly))
                else:
                    with self.assertRaises(RuntimeError):
                        IMAGE.resolve(REF.split('@')[0] + ':test', readonly=readonly)
        with mock.patch.object(IMAGE.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, DIGEST, '')):
            self.assertEqual(IMAGE.resolve(REF.split('@')[0] + ':test', readonly=True), REF)
        with mock.patch.object(IMAGE.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'mutable', '')):
            with self.assertRaises(ValueError):
                IMAGE.resolve(REF, readonly=True)

    def test_consumer_has_no_build_and_preserves_declared_environment(self):
        # Read the actual declarations used by the startup verifier, then run
        # that verifier with the generated consumer's environment.
        source = (ROOT / '.devcontainer/docker-compose.yml').read_text()
        block = source.split('    environment:\n', 1)[1].split('    volumes:', 1)[0]
        environment = {}
        for line in block.splitlines():
            if line.startswith('      ') and not line.strip().startswith('#') and ':' in line:
                key, value = line.strip().split(':', 1)
                if '${' not in value:
                    environment[key] = value.strip()
        compose = {'services': {'glowcap-dev': {'build': {'context': '..'},
                                               'environment': environment.copy()}}}
        config, compose = IMAGE.consumer_config({'service': 'glowcap-dev', 'features': {'test': {}},
                                                'postCreateCommand': 'bash .devcontainer/hooks/post-create.sh'},
                                                compose, REF, Path('/tmp/compose.json'))
        service = compose['services']['glowcap-dev']
        self.assertNotIn('build', service)
        self.assertNotIn('features', config)
        self.assertNotIn('postCreateCommand', config)
        self.assertEqual(service['image'], REF)
        self.assertEqual(service['environment'], environment)
        work = environment['ZIG_LOCAL_CACHE_DIR'].rsplit('/', 1)[0]
        self.assertEqual({volume['target']: Path(volume['source']).name for volume in service['volumes']},
                         {environment['ZIG_LOCAL_PKG_DIR']: 'zig-pkg',
                          environment['ZIG_LOCAL_CACHE_DIR']: 'zig-local',
                          work + '/cargo': 'cargo-build'})
        self.assertTrue(environment['CARGO_BUILD_BUILD_DIR'].startswith(work + '/cargo/'))
        env = dict(os.environ, **environment, GLOWCAP_DEVCONTAINER_DIR='/test')
        command = ['bash', str(ROOT / '.devcontainer/hooks/verify-compose-env.sh')]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        env['ZIG_LOCAL_PKG_DIR'] = '/home/vscode/.cache/glowcap/ci/zig-pkg'
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ZIG_LOCAL_PKG_DIR', result.stderr)

    def test_archive_start_uses_verified_id_for_uid_adjustment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / '.devcontainer').mkdir()
            archive = root / 'devcontainer.tar'
            archive.write_bytes(b'fixture')
            config = {'configuration': {'service': 'glowcap-dev'}}
            compose = {'services': {'glowcap-dev': {'build': {'context': '..'},
                       'environment': {'ZIG_LOCAL_PKG_DIR': '/declared/work/zig-pkg',
                                       'ZIG_LOCAL_CACHE_DIR': '/declared/work/zig-local'}}}}

            def response(*args, **kwargs):
                if args[:2] == ('devcontainer', 'read-configuration'):
                    return json.dumps(config)
                if args[:2] == ('docker', 'compose'):
                    return json.dumps(compose)
                return ''

            with mock.patch.object(IMAGE, 'ROOT', root), \
                    mock.patch.dict(os.environ, {'RUNNER_TEMP': str(root)}), \
                    mock.patch.object(IMAGE.Path, 'home', return_value=root), \
                    mock.patch.object(IMAGE, 'run', side_effect=response) as run:
                IMAGE.start(DIGEST)
                calls = [call.args for call in run.call_args_list]
                local_name = 'glowcap-ci:' + 'a' * 64
                self.assertIn(('docker', 'tag', DIGEST, local_name), calls)
                self.assertFalse(archive.exists())
                rendered = json.loads((root / '.devcontainer/.ci/compose.json').read_text())
                self.assertEqual(rendered['services']['glowcap-dev']['image'], local_name)
                self.assertFalse(any(call[:2] == ('devcontainer', 'build') for call in calls))
                with self.assertRaises(ValueError):
                    IMAGE.start('ghcr.io/glowcap-org/glowcap/devcontainer:ci')

    def test_fingerprint_covers_contents_names_and_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'input').write_text('one')
            with mock.patch.object(IMAGE, 'ROOT', root), \
                    mock.patch.object(IMAGE, 'run', return_value='100644 hash 0\tinput\0') as run:
                first = IMAGE.fingerprint()
                self.assertEqual(first, IMAGE.fingerprint())
                (root / 'input').write_text('two')
                self.assertNotEqual(first, IMAGE.fingerprint())
                (root / 'input').write_text('one')
                run.return_value = '100755 hash 0\tinput\0'
                self.assertNotEqual(first, IMAGE.fingerprint())
