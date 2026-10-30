"""PR jobs use read-only tokens and never receive publishing credentials."""

import re
import unittest

from workflow_expression import selected
from workflow_test import ROOT, jobs


def read_only_job(body):
    permissions = re.search(r'^    permissions:([^\n]*)\n((?: {6}[^\n]*\n)*)', body, re.M)
    if permissions is None:
        return True  # The workflow's contents: read applies.
    return not permissions[1].strip() and all(
        re.fullmatch(r'      [\w-]+: (read|none)', line)
        for line in permissions[2].splitlines())


class WorkflowPrivileges(unittest.TestCase):
    def test_pr_execution_is_unprivileged(self):
        source = (ROOT / ".github/workflows/check.yml").read_text()
        self.assertIn("\n  pull_request:\n", source)
        self.assertNotIn("pull_request_target:", source)
        self.assertIn("\npermissions:\n  contents: read\n", source)
        self.assertNotIn("secrets.", source)
        group = (ROOT / ".github/workflows/check-group.yml").read_text()
        self.assertIn("\npermissions:\n  contents: read\n  packages: read\n", group)
        self.assertNotIn("secrets", group)
        linux = jobs(".github/workflows/check.yml")["linux"][1]
        self.assertIn("    uses: ./.github/workflows/check-group.yml\n", linux)
        self.assertNotIn("secrets", linux)
        bodies = [(name, body) for name, (_, body) in jobs(".github/workflows/check.yml").items()
                  if name in ("plan", "gates", "macos-runtime")]
        bodies += [(f"group {name}", body) for name, (_, body) in jobs(".github/workflows/check-group.yml").items()]
        self.assertEqual(len(bodies), 5)
        for name, body in bodies:
            with self.subTest(job=name):
                self.assertTrue(read_only_job(body), name)
                self.assertNotIn("self-hosted", body)
                self.assertNotRegex(body, r"(?m)^\s+ref:")
                checkout = re.search(r"^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)", body, re.M)
                self.assertIsNotNone(checkout)
                self.assertRegex(checkout[1], r"(?m)^          persist-credentials: false$")

    def test_job_permissions_refuse_write_and_dynamic_grants(self):
        for value, allowed in (
            ('\n      actions: read\n      contents: read', True),
            ('\n      actions: write\n      contents: read', False),
            ('\n      contents: write', False),
            (' write-all', False),
            (' ${{ inputs.permissions }}', False),
        ):
            with self.subTest(value=value):
                self.assertEqual(read_only_job(f'    permissions:{value}\n    steps:\n'), allowed)

    def test_image_preparation_privileges_and_consumer_dependency(self):
        workflow = (ROOT / '.github/workflows/devcontainer-image.yml').read_text()
        self.assertIn('  workflow_call:', workflow)
        self.assertNotIn('  push:', workflow)
        conditions = jobs('.github/workflows/devcontainer-image.yml')
        for event, ref, trusted in [('push', 'refs/heads/dev', True),
                                    ('push', 'refs/heads/main', True),
                                    ('pull_request', 'refs/heads/dev', False),
                                    ('pull_request', 'refs/pull/7/merge', False),
                                    ('workflow_dispatch', 'refs/heads/topic', False)]:
            context = {'event_name': event, 'ref': ref}
            self.assertEqual(selected(conditions['trusted'][0], context), trusted)
            self.assertEqual(selected(conditions['readonly'][0], context), not trusted)
        self.assertIn('packages: write', conditions['trusted'][1])
        self.assertIn('packages: read', conditions['readonly'][1])
        self.assertNotIn('packages: write', conditions['readonly'][1])
        consumer = jobs('.github/workflows/check.yml')['linux'][1]
        self.assertIn('needs: [plan, image]', consumer)
        self.assertNotIn('devcontainers/ci@', consumer)
        self.assertNotIn('cacheFrom:', consumer)
        self.assertNotIn('--remote-env ZIG_LOCAL_PKG_DIR=', consumer)
        self.assertIn('needs.image.outputs.image', consumer)
        self.assertIn('needs.image.outputs.archive', consumer)

    def test_other_consumers_share_readonly_image_startup(self):
        for name in ('pages', 'agent-tools'):
            workflow = (ROOT / f'.github/workflows/{name}.yml').read_text()
            with self.subTest(workflow=name):
                self.assertNotIn('devcontainers/ci@', workflow)
                self.assertIn('packages: read', workflow)
                self.assertNotIn('packages: write', workflow)
                self.assertIn('run: python3 .devcontainer/ci/image.py prepare\n', workflow)
                self.assertNotIn('--publish', workflow)
                self.assertIn('IMAGE: ${{ steps.image.outputs.image }}', workflow)
                self.assertIn('run: python3 .devcontainer/ci/image.py start "$IMAGE"', workflow)
                self.assertIn('--config .devcontainer/.ci/devcontainer.json', workflow)
