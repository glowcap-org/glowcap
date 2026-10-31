"""Hold the workflow files to the static audit's findings without running the audit.

zizmor itself runs in check.yml. These tests read the workflow text directly
so a regression fails in the ordinary Python suite: expressions stay out of
shell scripts, every action is pinned to a commit and every checkout drops its
credentials, the audit's own ignore list names real files, the dependency
updater waits a week, and the post-release validation keeps its cost split
between Linux and macOS. The workflows are block-style YAML written by hand,
so the tests match lines and indentation. They do not run on a GitHub runner.
"""

import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'
PINNED = re.compile(r'^[\w.-]+/[\w.-]+(?:/[\w./-]+)?@[0-9a-f]{40} # v\d+(?:\.\d+)*\S*$')
SHELL_WORKFLOWS = ('check-group', 'release', 'publish', 'validate-release', 'check', 'promote', 'pages')


def text(path):
    return (ROOT / path).read_text()


def jobs(source):
    """Job name to its indented body, for the block-style `jobs:` mapping."""
    listed = source.split('\njobs:\n', 1)[1]
    return dict(re.findall(r'^  ([\w-]+):\n((?: {4}[^\n]*\n|\n)*)', listed, re.M))


def script_lines(source):
    """Every line a shell sees: one-line `run:` values and `run: |` bodies."""
    found, block_indent = [], None
    for number, line in enumerate(source.splitlines(), 1):
        indent = len(line) - len(line.lstrip(' '))
        if block_indent is not None:
            if not line.strip() or indent > block_indent:
                found.append((number, line))
                continue
            block_indent = None
        match = re.match(r'(\s*)(?:- )?run:\s*(.*)$', line)
        if not match:
            continue
        value = match[2]
        if re.fullmatch(r'[|>][-+]?', value):
            block_indent = len(match[1]) + (2 if line.lstrip().startswith('- ') else 0)
        else:
            found.append((number, value))
    return found


class WorkflowAudit(unittest.TestCase):
    def test_the_audit_configuration_names_real_workflows(self):
        source = text('.github/zizmor.yml')
        self.assertRegex(source, r'(?m)^rules:$')
        rules = dict(re.findall(r'(?m)^  ([\w-]+):\n((?:    [^\n]*\n)+)', source))
        self.assertTrue(rules)
        self.assertIn('dangerous-triggers', rules)
        listed = 0
        for rule, body in rules.items():
            with self.subTest(rule=rule):
                self.assertRegex(body, r'(?m)^    (?:ignore:|disable: true)$')
                self.assertRegex(body, r'(?m)^ +#', 'each exception states its reason')
                for name in re.findall(r'(?m)^      - (\S+)$', body):
                    listed += 1
                    self.assertTrue((WORKFLOWS / name).is_file(), name)
        self.assertEqual(listed, len(re.findall(r'(?m)^\s+- ', source)), 'every list item is a workflow name')
        self.assertIn('promote.yml', rules['dangerous-triggers'])

    def test_the_audit_is_a_required_check(self):
        check = text('.github/workflows/check.yml')
        found = jobs(check)
        self.assertRegex(found['workflows'], r'(?m)^      - uses: zizmorcore/zizmor-action@[0-9a-f]{40} # v\d+\.\d+\.\d+$')
        self.assertRegex(found['workflows'], r'(?m)^          persona: regular$')
        self.assertRegex(found['gates'], r'(?m)^    needs: \[[^\]]*\bworkflows\b[^\]]*\]$')
        spec = importlib.util.spec_from_file_location('report', ROOT / 'ci/report.py')
        report = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(report)
        self.assertIn('workflows', report.REQUIRED)

    def test_expressions_reach_scripts_only_through_env(self):
        for name in SHELL_WORKFLOWS:
            source = text(f'.github/workflows/{name}.yml')
            with self.subTest(workflow=name):
                lines = script_lines(source)
                self.assertTrue(lines, 'the scan found no script to hold')
                for number, line in lines:
                    self.assertNotIn('${{', line, f'{name}.yml:{number}')

    def test_every_action_is_pinned_and_every_checkout_drops_credentials(self):
        for path in sorted(WORKFLOWS.glob('*.yml')):
            lines = path.read_text().splitlines()
            for number, line in enumerate(lines):
                match = re.match(r'\s*(?:- )?uses: (\S.*)$', line)
                if not match or match[1].startswith('./'):
                    continue
                with self.subTest(workflow=path.name, line=number + 1):
                    self.assertRegex(match[1], PINNED)
                    if match[1].startswith('actions/checkout@'):
                        indent = len(line) - len(line.lstrip(' '))
                        step = []
                        for following in lines[number + 1:]:
                            if following.strip() and len(following) - len(following.lstrip(' ')) <= indent:
                                break
                            step.append(following.strip())
                        self.assertIn('persist-credentials: false', step)

    def test_release_restores_no_cache(self):
        self.assertNotIn('actions/cache', text('.github/workflows/release.yml'))

    def test_dependency_updates_wait_a_week(self):
        source = text('.github/dependabot.yml')
        blocks = re.split(r'(?m)^  - (?=package-ecosystem:)', source)[1:]
        self.assertGreaterEqual(len(blocks), 3)
        for block in blocks:
            with self.subTest(ecosystem=block.splitlines()[0]):
                self.assertRegex(block, r'(?m)^    cooldown:\n      default-days: 7$')

    def test_release_validation_splits_hosts_by_cost(self):
        source = text('.github/workflows/validate-release.yml')
        self.assertRegex(source, r'(?m)^on:\n  schedule:\n(?:    [^\n]*\n)+  workflow_dispatch:$')
        self.assertRegex(source, r'(?m)^permissions:\n  contents: read\n\njobs:$')
        found = jobs(source)
        self.assertEqual(list(found), ['newest', 'installer-linux', 'installer-macos', 'registries'])
        self.assertIn("    if: github.event_name == 'workflow_dispatch'\n", found['installer-macos'])
        self.assertNotRegex(found['installer-linux'], r'(?m)^    if:')
        for name in ('installer-linux', 'installer-macos'):
            with self.subTest(job=name):
                self.assertIn('VERSION: ${{ needs.newest.outputs.version }}', found[name])
                self.assertIn('glowcap version | tee version.txt', found[name])
                self.assertIn('grep -Fx "glowcap $VERSION" version.txt', found[name])
        self.assertIn('ref: refs/tags/v${{ needs.newest.outputs.version }}', found['registries'])


if __name__ == '__main__':
    unittest.main()
