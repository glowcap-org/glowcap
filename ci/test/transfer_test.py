"""CI transfer bounds and retry predicates, loaded by infrastructure-check.

Read the declarations and evaluate their actual predicates. This covers the
runner contract we declare, not remote service behavior or runner scheduling.
"""

from pathlib import Path
import re
import textwrap
import unittest

from workflow_expression import selected

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ('check.yml', 'check-group.yml', 'devcontainer-image.yml')
TRANSFER = re.compile(r'actions/(?:cache(?:/restore|/save)?|download-artifact|upload-artifact)@')


def steps(source, indent=6):
    """Read this repository's scalar step fields and anchored input mappings."""
    anchors = {}
    pattern = rf'^ {{{indent}}}- ([\w-]+): ([^\n]+)\n((?:(?: {{{indent + 2}}}[^\n]*|)\n)*)'
    declarations = list(re.finditer(pattern, source, re.M))
    if len(declarations) != len(re.findall(rf'^ {{{indent}}}- ', source, re.M)):
        raise AssertionError('unsupported workflow step declaration')
    for match in declarations:
        body = match[3]
        fields = dict(re.findall(rf'^ {{{indent + 2}}}([\w-]+):(?: ([^\n]*))?$', body, re.M))
        fields[match[1]] = match[2]
        if 'uses' in fields:
            fields['uses'] = fields['uses'].split(' #', 1)[0].strip('"\'')
        if 'with' in fields:
            reference = fields['with']
            if reference.startswith('*'):
                fields['with'] = anchors[reference[1:]]
            else:
                mapping = re.search(rf'^ {{{indent + 2}}}with:[^\n]*\n((?: {{{indent + 4}}}[^\n]*\n)*)', body, re.M)
                fields['with'] = textwrap.dedent(mapping[1])
                if reference.startswith('&'):
                    anchors[reference[1:]] = fields['with']
        yield fields


class TransferTest(unittest.TestCase):
    def test_consumers_stage_the_image_before_starting_it(self):
        declared = list(steps((ROOT / '.github/workflows/check-group.yml').read_text()))
        start = 0
        consumers = 0
        for index, step in enumerate(declared):
            if step.get('uses', '').startswith('actions/checkout@'):
                start = index
            if step.get('uses') != './.devcontainer/ci/start':
                continue
            consumers += 1
            preceding = declared[start:index]
            reclaim = [i for i, item in enumerate(preceding)
                       if item.get('run') == '.devcontainer/ci/reclaim-disk.sh']
            images = [i for i, item in enumerate(preceding)
                      if 'name: devcontainer-image\n' in item.get('with', '')]
            self.assertEqual(len(reclaim), 1)
            self.assertEqual(len(images), 2, 'stage the image, with one bounded retry, before startup')
            self.assertLess(reclaim[0], images[0])
            for archive, successful in (('true', True), ('false', True), ('true', False)):
                self.assertEqual(selected(preceding[images[0]]['if'],
                                          context={'inputs': {'archive': archive}}, success=successful),
                                 archive == 'true' and successful)
        self.assertTrue(consumers, 'no image consumers were read')

    def test_ci_transfers_have_step_deadlines(self):
        paths = [('.github/workflows/' + name, 6) for name in WORKFLOWS]
        paths += [('.devcontainer/ci/action.yml', 4), ('.devcontainer/ci/start/action.yml', 4)]
        found = []
        for path, indent in paths:
            for step in steps((ROOT / path).read_text(), indent):
                if TRANSFER.match(step.get('uses', '')):
                    found.append(step)
                    with self.subTest(path=path, name=step.get('name', step['uses'])):
                        self.assertEqual(indent, 6, 'transfer deadlines belong to workflow steps, not composites')
                        self.assertRegex(step.get('timeout-minutes', ''), r'^[1-5]$')
        self.assertTrue(found, 'no transfer declarations were read')

    def test_required_handoffs_retry_identical_inputs_without_hiding_failure(self):
        pairs = []
        for name in WORKFLOWS:
            declared = list(steps((ROOT / '.github/workflows' / name).read_text()))
            for index, first in enumerate(declared):
                if first.get('continue-on-error') != 'true' or '-artifact@' not in first.get('uses', ''):
                    continue
                retry = declared[index + 1]
                pairs.append(first)
                with self.subTest(workflow=name, transfer=first.get('name')):
                    self.assertEqual(retry['uses'], first['uses'])
                    self.assertEqual(retry['with'], first['with'])
                    self.assertNotEqual(retry.get('continue-on-error'), 'true',
                                        'the final transfer attempt must fail the job')
                    self.assertIn('id', first)
                    for outcome in ('success', 'failure', 'cancelled', 'skipped'):
                        context = {'inputs': {'archive': 'true'}, 'needs': {'build': {'result': 'success'}},
                                   'steps': {'prepare': {'outputs': {'archive': 'true'}},
                                             'fetch': {'outcome': 'success'}, first['id']: {'outcome': outcome}}}
                        for cancelled in (False, True):
                            self.assertEqual(selected(retry['if'], context=context,
                                                      success=not cancelled, cancelled=cancelled),
                                             outcome == 'failure' and not cancelled)
                        if first.get('id') == 'hand' and outcome == 'failure':
                            self.assertTrue(selected(retry['if'], context=context, success=False),
                                            'a compile failure must not suppress its state handoff retry')
                    if 'name: devcontainer-image\n' in first['with']:
                        context['inputs']['archive'] = 'false'
                        context['steps']['prepare']['outputs']['archive'] = 'false'
                        self.assertFalse(selected(first['if'], context=context))
        self.assertTrue(any('name: devcontainer-image\n' in step['with'] for step in pairs),
                        'the unpublished image needs a bounded handoff too')
