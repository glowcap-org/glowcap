"""Exercise the aggregate's real command, dependency results and API failures."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PASS = {name: {'result': 'success'} for name in ('plan', 'image', 'linux', 'macos-runtime')}
PASS['plan']['outputs'] = {'full': 'true'}


def report_run(needs, *, jobs=(), api_status=0, command='python3 ci/report.py'):
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        gh = directory / 'gh'
        gh.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                      'open(os.environ["API_CALL"], "w").write(json.dumps(sys.argv[1:]))\n'
                      'print(os.environ["API_RESPONSE"])\nsys.exit(int(os.environ["API_STATUS"]))\n')
        gh.chmod(0o755)
        summary = directory / 'summary'
        call = directory / 'call'
        env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                   VALIDATION_NEEDS=json.dumps(needs), GITHUB_STEP_SUMMARY=str(summary),
                   GITHUB_SHA='a' * 40,
                   GITHUB_REPOSITORY='owner/project', GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='2',
                   API_RESPONSE=json.dumps([{'jobs': list(jobs)}]), API_STATUS=str(api_status),
                   API_CALL=str(call))
        result = subprocess.run(['bash', '-ec', command], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=10)
        return result, summary.read_text() if summary.exists() else '', json.loads(call.read_text())


class ReportTest(unittest.TestCase):
    def test_every_dependency_is_required(self):
        result, summary, _ = report_run(PASS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Full validation passed', summary)
        for name in PASS:
            for status in ('failure', 'cancelled', 'skipped', ''):
                with self.subTest(name=name, status=status):
                    result, summary, _ = report_run({**PASS, name: {'result': status}})
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(f'Validation dependency {name}', result.stderr)
                    self.assertIn('failed', summary)
            result, _, _ = report_run({key: value for key, value in PASS.items() if key != name})
            self.assertEqual(result.returncode, 1, name)

    def test_selected_coverage_is_not_full_qualification(self):
        needs = {**PASS, 'plan': {'result': 'success', 'outputs': {'full': 'false'}}}
        result, summary, _ = report_run(needs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Selected checks passed', summary)
        self.assertNotIn('Full validation', summary)

    def test_job_details_cannot_change_the_qualification_result(self):
        for status, expected in (('success', 0), ('failure', 1)):
            with self.subTest(status=status):
                result, summary, _ = report_run({**PASS, 'linux': {'result': status}}, api_status=37)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn('Job details unavailable', summary)
                self.assertIn(f'| linux | {status} |', summary)

    def test_malformed_optional_details_cannot_invalidate_a_pass(self):
        for job in ({'conclusion': 'failure'},
                    {'started_at': 'invalid date', 'completed_at': 'invalid date'}):
            with self.subTest(job=job):
                result, summary, _ = report_run(PASS, jobs=[job])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Full validation passed', summary)
                self.assertIn('Job details unavailable', summary)

    def test_links_failures_and_times_only_the_current_attempt(self):
        jobs = [{
            'name': 'linux (runtime) / test (runtime)', 'conclusion': 'failure',
            'html_url': 'https://github.com/owner/project/actions/runs/123/job/456',
            'started_at': '2026-10-30T12:00:00Z', 'completed_at': '2026-10-30T12:02:00Z',
        }, {'name': 'gates', 'conclusion': None, 'started_at': None, 'completed_at': None}]
        result, summary, call = report_run({**PASS, 'linux': {'result': 'failure'}}, jobs=jobs)
        self.assertEqual(result.returncode, 1)
        self.assertIn('[linux (runtime) / test (runtime)](' + jobs[0]['html_url'] + '): failure', summary)
        self.assertIn(' | 120 |', summary)
        self.assertEqual(call, ['api', '--paginate', '--slurp',
                               'repos/owner/project/actions/runs/123/attempts/2/jobs?per_page=100'])
