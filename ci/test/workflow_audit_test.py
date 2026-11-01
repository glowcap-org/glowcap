"""Hold every workflow and composite action to the static audit's findings without running the audit.

zizmor runs in check.yml. These tests read the workflow text so a regression
fails in the ordinary Python suite: expressions stay out of shell scripts,
every action is pinned to a commit and every checkout drops its credentials,
no mapping repeats a key, the audit's own ignore list names real files, the
dependency updater waits a week, and the post-release validation keeps its
cost split between Linux and macOS. CI logic is Python called by one-line
steps, so a workflow reads as a list of commands.
"""

import importlib.util
import re
import unittest

from workflows import ROOT, WORKFLOWS, duplicate_mapping_keys, jobs, text

PINNED = re.compile(r'^[\w.-]+/[\w.-]+(?:/[\w./-]+)?@[0-9a-f]{40} # v\d+(?:\.\d+)*\S*$')
AUDITED = sorted(WORKFLOWS.glob('*.yml')) + sorted(ROOT.glob('.devcontainer/ci/**/action.yml'))
# An inline script is one command's flags or a few lines of glue. A longer
# one is a program, and a program lives in a file with its own test.
MAX_SCRIPT_LINES = 20


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


def script_blocks(source):
    """The line count of each `run: |` block."""
    counts, block_indent, count = [], None, 0
    for line in source.splitlines() + ['end']:
        indent = len(line) - len(line.lstrip(' '))
        if block_indent is not None:
            if line.strip() and indent > block_indent:
                count += 1
                continue
            counts.append(count)
            block_indent = None
        match = re.match(r'(\s*)(?:- )?run:\s*([|>][-+]?)$', line)
        if match:
            block_indent = len(match[1]) + (2 if line.lstrip().startswith('- ') else 0)
            count = 0
    return counts


class WorkflowAudit(unittest.TestCase):
    def test_the_audit_configuration_names_real_workflows(self):
        source = text('.github/zizmor.yml')
        self.assertRegex(source, r'(?m)^rules:$')
        rules = dict(re.findall(r'(?m)^  ([\w-]+):\n((?:    [^\n]*\n)+)', source))
        self.assertTrue(rules)
        self.assertIn('dangerous-triggers', rules)
        audited = {path.name for path in AUDITED}
        self.assertIn('action.yml', audited, 'the composite actions zizmor audits beside the workflows')
        listed = 0
        for rule, body in rules.items():
            with self.subTest(rule=rule):
                self.assertRegex(body, r'(?m)^    (?:ignore:|disable: true)$')
                self.assertRegex(body, r'(?m)^ +#', 'each exception states its reason')
                for name in re.findall(r'(?m)^      - (\S+)$', body):
                    listed += 1
                    self.assertIn(name, audited)
        self.assertEqual(listed, len(re.findall(r'(?m)^\s+- ', source)), 'every list item names an audited file')
        self.assertIn('promote.yml', rules['dangerous-triggers'])

    def test_the_audit_is_a_required_check(self):
        found = jobs('.github/workflows/check.yml')
        self.assertRegex(found['workflows'].body, r'(?m)^      - uses: zizmorcore/zizmor-action@[0-9a-f]{40} # v\d+\.\d+\.\d+$')
        self.assertRegex(found['workflows'].body, r'(?m)^          persona: regular$')
        self.assertRegex(found['gates'].body, r'(?m)^    needs: \[[^\]]*\bworkflows\b[^\]]*\]$')
        spec = importlib.util.spec_from_file_location('report', ROOT / 'ci/report.py')
        report = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(report)
        self.assertIn('workflows', report.REQUIRED)

    def test_workflows_repeat_no_mapping_key(self):
        self.assertEqual(duplicate_mapping_keys('a:\n  b: 1\n  b: 2\nc:\n  - d: 1\n    d: 2\n  - d: 3\n'), [(3, 'b'), (6, 'd')])
        self.assertEqual(duplicate_mapping_keys('a:\n  b: 1\nc:\n  b: 2\n  run: |\n    x: 1\n    x: 2\n  run: 3\n'), [(8, 'run')],
                         'a block scalar holds text, and the key after it is still in its mapping')
        self.assertEqual(duplicate_mapping_keys('a:\n  path: &p |\n    x: 1\n    x: 2\n  key: 1\n'), [],
                         'an anchored block scalar holds text too')
        for path in AUDITED:
            with self.subTest(path=path.name):
                self.assertEqual(duplicate_mapping_keys(path.read_text()), [])

    def test_expressions_reach_scripts_only_through_env(self):
        held = 0
        for path in AUDITED:
            lines = script_lines(path.read_text())
            held += len(lines)
            for number, line in lines:
                self.assertNotIn('${{', line, f'{path.relative_to(ROOT)}:{number}')
        self.assertTrue(held, 'the scan found no script to hold')

    def test_ci_logic_is_python_called_by_short_steps(self):
        self.assertEqual(list(ROOT.glob('ci/**/*.sh')), [])
        for path in AUDITED:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertLessEqual(max(script_blocks(path.read_text()), default=0), MAX_SCRIPT_LINES)

    def test_every_action_is_pinned_and_every_checkout_drops_credentials(self):
        for path in AUDITED:
            lines = path.read_text().splitlines()
            for number, line in enumerate(lines):
                match = re.match(r'\s*(?:- )?uses: (\S.*)$', line)
                if not match or match[1].startswith('./'):
                    continue
                with self.subTest(path=path.relative_to(ROOT), line=number + 1):
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
        found = jobs('.github/workflows/validate-release.yml')
        self.assertEqual(list(found), ['newest', 'installer-linux', 'installer-macos', 'registries'])
        self.assertEqual(found['installer-macos'].condition, "github.event_name == 'workflow_dispatch'")
        self.assertIsNone(found['installer-linux'].condition)
        for name in ('installer-linux', 'installer-macos'):
            with self.subTest(job=name):
                self.assertIn('VERSION: ${{ needs.newest.outputs.version }}', found[name].body)
                self.assertIn('glowcap version | tee version.txt', found[name].body)
                self.assertIn('grep -Fx "glowcap $VERSION" version.txt', found[name].body)
        self.assertIn('ref: refs/tags/v${{ needs.newest.outputs.version }}', found['registries'].body)


if __name__ == '__main__':
    unittest.main()
