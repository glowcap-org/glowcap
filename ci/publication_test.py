"""What publishes main: pages.yml and release.yml require the commit's check run.

ci/require_main_check.py is run against a stub Actions API, and the
workflow steps that call it run the same way. Nothing here reaches GitHub.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from workflows import ROOT, jobs, on_path, selected, shell_step, step, stub, text

RUN = {'id': 42, 'run_attempt': 1, 'head_sha': 'a' * 40, 'head_branch': 'dev', 'event': 'push',
       'status': 'completed', 'conclusion': 'success',
       'head_repository': {'full_name': 'owner/project'},
       'html_url': 'https://example.invalid/dev-run'}


class EvidenceTest(unittest.TestCase):
    def evidence(self, runs, commit='a' * 40, repository='owner/project', status=0, raw=None,
                 command=None, current='a' * 40, job_records=None, relation='identical'):
        with tempfile.TemporaryDirectory() as temporary:
            stub(temporary, 'gh', """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['EVIDENCE_CALL'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
if int(os.environ['EVIDENCE_STATUS']):
    print('Actions API unavailable', file=sys.stderr)
    sys.exit(int(os.environ['EVIDENCE_STATUS']))
if any('/git/ref/heads/main' in argument for argument in sys.argv):
    print(os.environ['EVIDENCE_CURRENT'])
    sys.exit(0)
if any('/compare/' in argument for argument in sys.argv):
    print(json.dumps({'status': os.environ['EVIDENCE_RELATION']}))
    sys.exit(0)
if any('/jobs?' in argument for argument in sys.argv):
    print(os.environ['EVIDENCE_JOBS'])
else:
    print(os.environ['EVIDENCE_RESPONSE'])
""")
            call = Path(temporary) / 'call.json'
            environment = on_path(temporary, GITHUB_REPOSITORY=repository, EVIDENCE_CALL=str(call),
                                  EVIDENCE_STATUS=str(status), EVIDENCE_CURRENT=current,
                                  EVIDENCE_RELATION=relation,
                                  DEPLOY_SHA=commit, GITHUB_SHA=commit, GH_TOKEN='test-token',
                                  EVIDENCE_RESPONSE=raw if raw is not None else json.dumps({'workflow_runs': runs}),
                                  EVIDENCE_JOBS=json.dumps({'jobs': job_records if job_records is not None else [
                                      {'name': name, 'status': 'completed', 'conclusion': 'success'}
                                      for name in ('gates', 'macos-runtime')]}))
            arguments = ([sys.executable, str(ROOT / 'ci/require_main_check.py'), commit]
                         if command is None else ['bash', '-e', '-o', 'pipefail', '-c', command])
            result = subprocess.run(arguments, cwd=temporary if command is None else ROOT,
                                    env=environment, capture_output=True, text=True)
            self.api_calls = [json.loads(line) for line in call.read_text().splitlines()] if call.exists() else []
            runs_call = next((c for c in self.api_calls if any('/runs' in a for a in c)), None)
            return result, runs_call

    def test_publication_requires_the_dev_push_run_of_a_main_commit(self):
        result, call = self.evidence([RUN])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), RUN['html_url'])
        self.assertIn('repos/owner/project/compare/' + 'a' * 40 + '...main', self.api_calls[0])
        for value in ('status=completed', 'head_sha=' + 'a' * 40):
            self.assertIn(value, call)
        self.assertEqual(self.evidence([RUN], relation='ahead')[0].returncode, 0)
        for relation in ('behind', 'diverged'):
            with self.subTest(relation=relation):
                refused, _ = self.evidence([RUN], relation=relation)
                self.assertEqual(refused.returncode, 1, refused.stderr)
                self.assertIn('is not on main', refused.stderr)
                self.assertEqual(len(self.api_calls), 1)
        for key, value in [('head_sha', 'b' * 40), ('head_branch', 'main'), ('head_branch', 'feature'),
                           ('event', 'pull_request'), ('status', 'in_progress'),
                           ('conclusion', 'failure'), ('head_repository', {'full_name': 'fork/project'}),
                           ('html_url', '')]:
            with self.subTest(field=key):
                refused, _ = self.evidence([dict(RUN, **{key: value})])
                self.assertEqual(refused.returncode, 1, refused.stderr)
                self.assertEqual(refused.stdout, '')
        empty, _ = self.evidence([])
        self.assertEqual(empty.returncode, 1)

    def test_manual_recovery_requires_both_successful_gate_jobs(self):
        run = dict(RUN, run_attempt=2, head_branch='main', event='workflow_dispatch',
                   html_url='https://example.invalid/manual-run')
        accepted, _ = self.evidence([run])
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn('repos/owner/project/actions/runs/42/attempts/2/jobs?per_page=100', self.api_calls[2])
        for event in ('push', 'workflow_dispatch'):
            for conclusion in ('skipped', 'failure', 'cancelled', None):
                records = [{'name': 'gates', 'status': 'completed', 'conclusion': 'success'},
                           {'name': 'macos-runtime', 'status': 'completed', 'conclusion': conclusion}]
                refused, _ = self.evidence([dict(run, event=event)], job_records=records)
                self.assertEqual(refused.returncode, 1, refused.stderr)
            refused, _ = self.evidence([dict(run, event=event)], job_records=[
                {'name': 'scheduled-fuzz', 'status': 'completed', 'conclusion': 'success'}])
            self.assertEqual(refused.returncode, 1, refused.stderr)
        for records in ([{'name': 'dev-gates', 'status': 'completed', 'conclusion': 'success'},
                         {'name': 'macos-runtime', 'status': 'completed', 'conclusion': 'success'}],
                        [], [None, {'name': {}}, {'name': 'gates', 'status': 'in_progress', 'conclusion': 'success'}]):
            refused, _ = self.evidence([run], job_records=records)
            self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertEqual(self.evidence([dict(run, head_branch='dev')])[0].returncode, 0)
        refused, _ = self.evidence([dict(run, event='schedule')])
        self.assertEqual(refused.returncode, 1)

    def test_evidence_errors_remain_failures(self):
        failed, _ = self.evidence([], status=7)
        self.assertEqual(failed.returncode, 7)
        self.assertIn('Actions API unavailable', failed.stderr)
        for raw in ('{', '{}', '{"workflow_runs": null}', '{"workflow_runs": {}}'):
            malformed, _ = self.evidence([], raw=raw)
            self.assertEqual(malformed.returncode, 1, malformed.stderr)
            self.assertIn('invalid Actions response', malformed.stderr)
        for arguments in ({'commit': 'main'}, {'repository': ''}):
            invalid, call = self.evidence([], **arguments)
            self.assertEqual(invalid.returncode, 2)
            self.assertIsNone(call)

    def test_evidence_lookup_has_a_deadline_and_setup_diagnostic(self):
        spec = importlib.util.spec_from_file_location('main_check', ROOT / 'ci/require_main_check.py')
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        for error, status, diagnostic in [
            (subprocess.TimeoutExpired('gh', 30), 124, 'exceeded 30 seconds'),
            (FileNotFoundError('gh unavailable'), 1, 'cannot run gh'),
        ]:
            output = io.StringIO()
            with mock.patch.object(sys, 'argv', ['require-main-check.py', 'a' * 40]), \
                    mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': 'owner/project'}), \
                    mock.patch.object(helper.subprocess, 'run', side_effect=error) as lookup, \
                    contextlib.redirect_stderr(output):
                self.assertEqual(helper.main(), status)
            self.assertIn(diagnostic, output.getvalue())
            self.assertIn('timeout', lookup.call_args.kwargs)
            self.assertGreater(lookup.call_args.kwargs['timeout'], 0)
            self.assertLessEqual(lookup.call_args.kwargs['timeout'], 30)

    def test_workflow_steps_enforce_publication_evidence(self):
        for path, name in [('pages', 'Verify the exact commit passed check'),
                           ('release', "Require this commit's successful check workflow")]:
            command = shell_step(text(f'.github/workflows/{path}.yml'), name)
            with self.subTest(workflow=path):
                accepted, _ = self.evidence([RUN], command=command)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                refused, _ = self.evidence([RUN], command=command, relation='diverged')
                self.assertNotEqual(refused.returncode, 0, refused.stderr)
                if path == 'pages':
                    stale, _ = self.evidence([RUN], command=command, current='b' * 40)
                    self.assertNotEqual(stale.returncode, 0)

    def test_publication_cannot_skip_its_evidence(self):
        release = jobs('.github/workflows/release.yml')
        self.assertRegex(release['release'].body, r'(?m)^    needs: \[contract, ')
        verifier = step(release['contract'].body, "Require this commit's successful check workflow")
        self.assertIn("if: github.ref_type == 'tag'\n", verifier)
        pages = jobs('.github/workflows/pages.yml')
        self.assertRegex(pages['deploy'].body, r'(?m)^    needs: build$')
        step(pages['build'].body, 'Verify the exact commit passed check')
        top = text('.github/workflows/pages.yml').split('\njobs:\n', 1)[0]
        self.assertNotRegex(top, r'(?m)^  (pages|id-token): write$')
        self.assertNotRegex(pages['build'].body, r'(?m)^      (pages|id-token): write$')
        for path, found in (('release.yml', release), ('pages.yml', pages)):
            for name, job in found.items():
                for checkout in re.finditer(r'^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)', job.body, re.M):
                    with self.subTest(workflow=path, job=name):
                        self.assertRegex(checkout[1], r'(?m)^          persist-credentials: false$')

    def test_pages_builds_only_main(self):
        # The verify step, not this condition, requires the commit's
        # successful check run.
        source = text('.github/workflows/pages.yml')
        self.assertIn('\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\n', source)
        condition = jobs('.github/workflows/pages.yml')['build'].condition
        for event in ('push', 'workflow_dispatch'):
            for branch, expected in [('main', True), ('dev', False)]:
                with self.subTest(event=event, branch=branch):
                    self.assertEqual(selected(condition, {'event_name': event,
                                                         'ref': f'refs/heads/{branch}'}), expected)


if __name__ == '__main__':
    unittest.main()
