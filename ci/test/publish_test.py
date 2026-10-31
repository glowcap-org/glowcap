"""publish.yml publishes registry packages only from a verified public release.

Read the workflow's own jobs: every registry job runs in its environment with an
OIDC token after the contract job, every action is pinned to a commit, and the
registry steps skip a version the registry already holds. The crate step runs
with stub curl and cargo. This does not reach a registry or GitHub runners.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from workflow_test import ROOT, shell_step


WORKFLOW = ROOT / '.github/workflows/publish.yml'
REGISTRY_JOBS = {'pypi': 'pypi', 'crates-io': 'crates-io', 'jsr': 'jsr'}


def jobs():
    source = WORKFLOW.read_text().split('\njobs:\n', 1)
    found = dict(re.findall(r'^  ([\w-]+):\n((?: {4}[^\n]*\n|\n)*)', source[1], re.M))
    return source[0], found


class PublishWorkflow(unittest.TestCase):
    def test_registry_jobs_follow_the_contract_in_their_environments(self):
        top, found = jobs()
        self.assertEqual(set(found), {'contract', *REGISTRY_JOBS})
        self.assertRegex(top, r'(?m)^permissions:\n  contents: read\n$')
        self.assertNotIn('id-token', top)
        self.assertIn('workflow_dispatch:', top)
        for name, environment in REGISTRY_JOBS.items():
            body = found[name]
            with self.subTest(job=name):
                self.assertRegex(body, r'(?m)^    needs: contract$')
                self.assertRegex(body, rf'(?m)^    environment: {environment}$')
                self.assertRegex(body, r'(?m)^      id-token: write$')
                self.assertNotRegex(body, r'(?m)^      (contents|packages|actions): write$')
                self.assertIn('ref: ${{ needs.contract.outputs.commit }}', body)
                self.assertIn('binding_packages.py --registry "$VERSION"', body)
        self.assertNotIn('id-token', found['contract'])
        self.assertIn('release_recovery.py --published "$RELEASE_TAG"', found['contract'])

    def test_every_action_is_pinned_and_no_checkout_keeps_credentials(self):
        _, found = jobs()
        for name, body in found.items():
            for action in re.finditer(r'(?m)^      - (?:\n|.*\n)?\s*uses: ([^\n]+)\n', body):
                with self.subTest(job=name, action=action[1]):
                    self.assertRegex(action[1], r'^[\w.-]+/[\w.-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$')
            for checkout in re.finditer(r'^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)', body, re.M):
                with self.subTest(job=name):
                    self.assertRegex(checkout[1], r'(?m)^          persist-credentials: false$')

    def test_registry_steps_skip_a_version_the_registry_holds(self):
        source = WORKFLOW.read_text()
        self.assertIn('skip-existing: true', source)
        self.assertIn('run: deno publish\n', source)
        self.assertNotIn('--allow-dirty', source)
        self.assertNotIn('--dry-run', source)
        script = shell_step(source, 'Publish the crate')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / 'calls'
            for tool in ('curl', 'cargo'):
                stub = directory / tool
                stub.write_text(f'#!/bin/sh\necho "{tool} $*" >> "$CALL_LOG"\n'
                                + ('printf "%s" "$CURL_STATUS"\n' if tool == 'curl' else ''))
                stub.chmod(0o755)
            for status, published, accepted in (('200', False, True), ('404', True, True), ('500', False, False)):
                with self.subTest(status=status):
                    log.write_text('')
                    environment = dict(os.environ, PATH=f'{directory}{os.pathsep}{os.environ["PATH"]}',
                                       CALL_LOG=str(log), CURL_STATUS=status, VERSION='0.1.1',
                                       GITHUB_REPOSITORY='owner/project')
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=directory,
                                            env=environment, capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    calls = log.read_text()
                    self.assertIn('crates/glowcap/0.1.1', calls)
                    self.assertEqual('cargo publish' in calls, published)

    def test_each_registry_job_requires_the_tag_of_its_checkout(self):
        script = shell_step(WORKFLOW.read_text(), "Require the tag's version")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'bindings').mkdir()
            (directory / 'bindings/c-abi-resolve.json').write_text(json.dumps({'abi_version': '0.1.1'}))
            for tag, accepted in (('v0.1.1', True), ('v0.1.0', False), ('0.1.1', False)):
                with self.subTest(tag=tag):
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=directory,
                                            env=dict(os.environ, RELEASE_TAG=tag), capture_output=True,
                                            text=True, timeout=20)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_release_dispatches_publication_after_the_release_is_public(self):
        source = (ROOT / '.github/workflows/release.yml').read_text()
        release = re.search(r'(?m)^  release:\n((?: {4}[^\n]*\n|\n)*)', source)[1]
        self.assertRegex(release, r'(?m)^      actions: write$')
        publish = release.index('--draft=false')
        dispatch = release.index('gh workflow run publish.yml')
        self.assertLess(publish, dispatch)
        script = shell_step(source, 'Publish the language packages at the tag')
        self.assertIn('--ref "refs/tags/$RELEASE_TAG" -f tag="$RELEASE_TAG"', script)


if __name__ == '__main__':
    unittest.main()
