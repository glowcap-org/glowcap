"""Finish check.yml with one qualification result and linked job diagnostics.

Actions' needs results decide success. Job details only enrich the summary:
an unavailable read API cannot hide a failed dependency or invalidate a pass.
The workflow supplies VALIDATION_NEEDS, the Actions run identity and its
read-only token. No repository or registry state is changed.
"""

from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


REQUIRED = ('plan', 'image', 'linux', 'macos-runtime')


def qualification(needs):
    return all(needs.get(name, {}).get('result') == 'success' for name in REQUIRED)


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def render(needs, jobs, warning=None):
    passed = qualification(needs)
    scope = 'Full validation' if needs.get('plan', {}).get('outputs', {}).get('full') == 'true' else 'Selected checks'
    lines = [f'## {scope} {"passed" if passed else "failed"}', '',
             '| Dependency | Result |', '| --- | --- |']
    for name in REQUIRED:
        lines.append(f"| {name} | {cell(needs.get(name, {}).get('result', 'missing'))} |")
    failed = [job for job in jobs if job.get('conclusion') in ('failure', 'cancelled', 'timed_out')]
    if failed:
        lines.extend(['', '### Jobs requiring attention', ''])
        for job in failed:
            name = cell(job['name'])
            lines.append(f"- [{name}]({job['html_url']}): {job['conclusion']}")
    durations = []
    for job in jobs:
        if job.get('started_at') and job.get('completed_at'):
            start = datetime.fromisoformat(job['started_at'].replace('Z', '+00:00'))
            end = datetime.fromisoformat(job['completed_at'].replace('Z', '+00:00'))
            durations.append((int((end - start).total_seconds()), job))
    if durations:
        lines.extend(['', '### Longest completed jobs', '',
                      '| Job | Seconds |', '| --- | ---: |'])
        for seconds, job in sorted(durations, key=lambda item: item[0], reverse=True)[:5]:
            lines.append(f"| [{cell(job['name'])}]({job['html_url']}) | {seconds} |")
    if warning:
        lines.extend(['', f'Job details unavailable: {cell(warning)}. Dependency results above remain authoritative.'])
    lines.extend(['', 'Release archives and container images require the separate release rehearsal.', ''])
    return '\n'.join(lines)


def main():
    needs = json.loads(os.environ['VALIDATION_NEEDS'])
    try:
        repository = os.environ['GITHUB_REPOSITORY']
        run = os.environ['GITHUB_RUN_ID']
        attempt = os.environ['GITHUB_RUN_ATTEMPT']
        response = subprocess.run([
            'gh', 'api', '--paginate', '--slurp',
            f'repos/{repository}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100',
        ], capture_output=True, text=True, check=True, timeout=20)
        jobs = [job for page in json.loads(response.stdout) for job in page['jobs']]
        details = render(needs, jobs)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        details = render(needs, [], type(error).__name__)
    summary = f"Commit: `{os.environ['GITHUB_SHA']}`\n\n" + details
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as output:
        output.write(summary)
    print(summary)
    if not qualification(needs):
        for name in REQUIRED:
            result = needs.get(name, {}).get('result', 'missing')
            if result != 'success':
                print(f'::error::Validation dependency {name} ended as {result}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
