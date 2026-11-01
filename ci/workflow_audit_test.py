"""The shape of the workflow files that zizmor does not audit.

zizmor (check.yml, the `workflows` job, configured in .github/zizmor.yml)
holds action pinning, credential persistence, template injection, release
cache poisoning, and the Dependabot cooldown. These tests hold what remains
this repository's own: no mapping repeats a key (GitHub refuses the file),
the audit's exception list names real files and is a required result, CI
logic is Python called by short steps, and the post-release validation keeps
its cost split between Linux and macOS.
"""

import importlib.util
import re
import unittest

from workflows import ROOT, WORKFLOWS, duplicate_mapping_keys, jobs, text

AUDITED = sorted(WORKFLOWS.glob('*.yml')) + sorted(ROOT.glob('.github/actions/*/action.yml'))
# An inline script is one command's flags or a few lines of glue. A longer
# one is a program, and a program lives in a file with its own test.
MAX_SCRIPT_LINES = 20


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
                self.assertRegex(body, r'(?m)^    (?:ignore:|disable: true|config:)$')
                self.assertRegex(body, r'(?m)^ +#', 'each exception or policy states its reason')
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

    def test_ci_logic_is_python_called_by_short_steps(self):
        self.assertEqual(list(ROOT.glob('ci/**/*.sh')), [])
        for path in AUDITED:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertLessEqual(max(script_blocks(path.read_text()), default=0), MAX_SCRIPT_LINES)

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
