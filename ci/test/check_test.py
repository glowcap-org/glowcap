"""check.yml and the group workflow it calls, for infrastructure-check.

Read from the workflow text: which events run what, that pull requests run
on read-only tokens, that every transfer is bounded and each required one
retried, when compile state is reused, and which artifacts a run keeps. The
gate runner (gates_test) and the state script (state_test) have their own
tests, and workflow_audit_test holds every workflow to the static audit.
"""

import re
import subprocess
import tempfile
import unittest

from report_test import PASS, report_run
from workflows import ROOT, WORKFLOWS, jobs, on_path, selected, shell_step, step, steps, stub, text

CHECK = '.github/workflows/check.yml'
GROUP = '.github/workflows/check-group.yml'
IMAGE = '.github/workflows/devcontainer-image.yml'
SUITE_JOBS = ('plan', 'gates', 'macos-runtime', 'scheduled-fuzz')
TRANSFER = re.compile(r'actions/(upload-artifact|download-artifact|cache(/restore|/save)?)@')
COMPOSITES = ('.devcontainer/ci/action.yml', '.devcontainer/ci/start/action.yml', '.devcontainer/ci/pins/action.yml')


def read_only_job(body):
    """True when a job's permissions block grants nothing beyond reading."""
    permissions = re.search(r'^    permissions:([^\n]*)\n((?: {6}[^\n]*\n)*)', body, re.M)
    if permissions is None:
        return True  # The workflow's contents: read applies.
    return not permissions[1].strip() and all(
        re.fullmatch(r'      [\w-]+: (read|none)', line)
        for line in permissions[2].splitlines())


def condition(body, name):
    return re.search(r'^        if: (.+)$', step(body, name), re.M)[1]


class EventsTest(unittest.TestCase):
    def test_events_select_full_validation_or_the_fuzz_search(self):
        found = jobs(CHECK)
        for event, base, expected in [
            ('push', '', (True, True, True, False)),
            ('pull_request', 'dev', (True, True, True, False)),
            ('pull_request', 'main', (True, True, True, False)),
            ('schedule', '', (True, True, True, True)),
            ('workflow_dispatch', '', (True, True, True, False)),
        ]:
            context = {'event_name': event, 'base_ref': base, 'event': {'inputs': {'suite': 'check'}}}
            with self.subTest(event=event, base=base):
                self.assertEqual(tuple(selected(found[name].condition, context) for name in SUITE_JOBS), expected)
        fuzz = {'event_name': 'workflow_dispatch', 'event': {'inputs': {'suite': 'fuzz'}}}
        self.assertEqual(tuple(selected(found[name].condition, fuzz) for name in SUITE_JOBS),
                         (False, False, False, True))
        group = re.search(r'(?m)^  group: (.+)$', text(CHECK))[1]
        self.assertIn("${{ github.event.inputs.suite || 'check' }}", group, 'a fuzz run cancels no check run')
        self.assertEqual(found['linux'].condition, None, 'needs: [plan, image] gates the groups')
        self.assertEqual(found['gates'].condition.removeprefix('always() && (').removesuffix(')').strip(),
                         found['plan'].condition)

    def test_main_is_never_revalidated(self):
        for path in (CHECK, '.github/workflows/agent-tools.yml'):
            with self.subTest(workflow=path):
                self.assertRegex(text(path), r'(?m)^  push:\n    branches: \[dev\]$')

    def test_the_aggregate_requires_every_job(self):
        found = jobs(CHECK)
        aggregate = found['gates'].body
        self.assertIn('    needs: [plan, image, linux, macos-runtime, workflows]\n', aggregate)
        self.assertIn('always()', found['gates'].condition)
        self.assertIn('VALIDATION_NEEDS: ${{ toJSON(needs) }}', aggregate)
        command = re.search(r'^        run: (.+)$', aggregate, re.M)[1]
        ran, _, _ = report_run(PASS, command=command)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        for name in PASS:
            ran, _, _ = report_run({**PASS, name: {'result': 'failure'}}, command=command)
            self.assertNotEqual(ran.returncode, 0, name)
        self.assertIn("name: ${{ needs.plan.outputs.full == 'true' && 'gates' || 'dev-gates' }}", aggregate)
        linux = found['linux'].body
        self.assertIn('fail-fast: false', linux)
        self.assertIn('group: ${{ fromJSON(needs.plan.outputs.groups) }}', linux)


class PrivilegeTest(unittest.TestCase):
    def test_pull_requests_run_on_read_only_tokens(self):
        source = text(CHECK)
        self.assertIn('\n  pull_request:\n', source)
        self.assertNotIn('pull_request_target:', source)
        self.assertIn('\npermissions:\n  contents: read\n', source)
        self.assertNotIn('secrets.', source)
        group = text(GROUP)
        self.assertIn('\npermissions:\n  contents: read\n  packages: read\n', group)
        self.assertNotIn('secrets', group)
        linux = jobs(CHECK)['linux'].body
        self.assertIn('    uses: ./.github/workflows/check-group.yml\n', linux)
        self.assertNotIn('secrets', linux)
        bodies = [(name, job.body) for name, job in jobs(CHECK).items() if name in ('plan', 'gates', 'macos-runtime')]
        bodies += [(f'group {name}', job.body) for name, job in jobs(GROUP).items()]
        self.assertEqual(len(bodies), 5)
        for name, body in bodies:
            with self.subTest(job=name):
                self.assertTrue(read_only_job(body), name)
                self.assertNotIn('self-hosted', body)
                self.assertNotRegex(body, r'(?m)^\s+ref:')
                checkout = re.search(r'^      - uses: actions/checkout@[^\n]+\n((?: {8}[^\n]*\n|\n)*)', body, re.M)
                self.assertIsNotNone(checkout)
                self.assertRegex(checkout[1], r'(?m)^          persist-credentials: false$')
        for value, allowed in (
            ('\n      actions: read\n      contents: read', True),
            ('\n      actions: write\n      contents: read', False),
            ('\n      contents: write', False),
            (' write-all', False),
            (' ${{ inputs.permissions }}', False),
        ):
            with self.subTest(value=value):
                self.assertEqual(read_only_job(f'    permissions:{value}\n    steps:\n'), allowed)

    def test_only_a_trusted_push_publishes_the_image(self):
        workflow = text(IMAGE)
        self.assertIn('  workflow_call:', workflow)
        self.assertNotIn('  push:', workflow)
        found = jobs(IMAGE)
        for event, ref, trusted in [('push', 'refs/heads/dev', True),
                                    ('push', 'refs/heads/main', True),
                                    ('pull_request', 'refs/heads/dev', False),
                                    ('pull_request', 'refs/pull/7/merge', False),
                                    ('workflow_dispatch', 'refs/heads/topic', False)]:
            context = {'event_name': event, 'ref': ref}
            self.assertEqual(selected(found['trusted'].condition, context), trusted)
            self.assertEqual(selected(found['readonly'].condition, context), not trusted)
        self.assertIn('packages: write', found['trusted'].body)
        self.assertIn('          publish: true\n', found['trusted'].body)
        self.assertIn('packages: read', found['readonly'].body)
        self.assertNotIn('packages: write', found['readonly'].body)
        self.assertNotIn('publish:', found['readonly'].body)
        consumer = jobs(CHECK)['linux'].body
        self.assertIn('needs: [plan, image]', consumer)
        self.assertNotIn('devcontainers/ci@', consumer)
        self.assertIn('needs.image.outputs.image', consumer)
        self.assertIn('needs.image.outputs.archive', consumer)
        # The composite publishes only on the literal input, never on a ref.
        script = shell_step(text('.devcontainer/ci/action.yml').replace('\n    ', '\n      '),
                            'Resolve or build the toolchain image once')
        with tempfile.TemporaryDirectory() as directory:
            stub(directory, 'python3', '#!/bin/sh\nprintf "%s\\n" "$@" > "$CALL"\n')
            for publish, expected in (('true', 'prepare\n--publish\n'), ('false', 'prepare\n'), ('', 'prepare\n')):
                with self.subTest(publish=publish):
                    result = subprocess.run(['bash', '-e', '-c', script], cwd=ROOT, capture_output=True, text=True,
                                            env=on_path(directory, PUBLISH=publish, CALL=f'{directory}/call'))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(open(f'{directory}/call').read(), f'.devcontainer/ci/image.py\n{expected}')

    def test_other_consumers_start_the_prepared_image_read_only(self):
        for name in ('pages', 'agent-tools'):
            workflow = text(f'.github/workflows/{name}.yml')
            with self.subTest(workflow=name):
                self.assertNotIn('devcontainers/ci@', workflow)
                self.assertIn('packages: read', workflow)
                self.assertNotIn('packages: write', workflow)
                self.assertIn('      - uses: ./.devcontainer/ci\n        id: image\n', workflow)
                self.assertNotIn('publish:', workflow)
                self.assertIn('      - uses: ./.devcontainer/ci/start\n        with:\n'
                              '          image: ${{ steps.image.outputs.image }}\n', workflow)
                self.assertIn('--config .devcontainer/.ci/devcontainer.json', workflow)

    def test_agent_downloads_have_their_own_result(self):
        workflow = text('.github/workflows/agent-tools.yml')
        command = re.search(r'(?m)^        run: devcontainer exec --workspace-folder \. --config \.devcontainer/\.ci/devcontainer\.json (python3 .+)$', workflow)
        self.assertIsNotNone(command)
        self.assertIn('tools/run-with-timeout.py', command[1])
        self.assertIn('bash .devcontainer/test/tool-install.sh', command[1])
        self.assertIn('\npermissions:\n  contents: read\n', workflow)
        self.assertNotIn('secrets.', workflow)
        self.assertNotIn('pull_request_target:', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertNotIn('needs:', workflow)


class TransferTest(unittest.TestCase):
    def test_group_jobs_reclaim_disk_and_stage_the_image_before_starting_it(self):
        declared = list(steps(text(GROUP)))
        start = 0
        consumers = 0
        for index, item in enumerate(declared):
            if item.get('uses', '').startswith('actions/checkout@'):
                start = index
            if item.get('uses') != './.devcontainer/ci/start':
                continue
            consumers += 1
            preceding = declared[start:index]
            reclaim = [i for i, other in enumerate(preceding)
                       if other.get('run') == 'python3 .devcontainer/ci/image.py reclaim']
            images = [i for i, other in enumerate(preceding) if 'name: devcontainer-image\n' in other.get('with', '')]
            self.assertEqual(len(reclaim), 1)
            self.assertEqual(len(images), 2, 'stage the image, with one bounded retry, before startup')
            self.assertLess(reclaim[0], images[0])
            for archive, successful in (('true', True), ('false', True), ('true', False)):
                self.assertEqual(selected(preceding[images[0]]['if'],
                                          context={'inputs': {'archive': archive}}, success=successful),
                                 archive == 'true' and successful)
        self.assertEqual(consumers, 2)

    def test_transfers_have_step_deadlines(self):
        paths = [(str(path.relative_to(ROOT)), 6) for path in sorted(WORKFLOWS.glob('*.yml'))]
        paths += [(path, 4) for path in COMPOSITES]
        found = []
        for path, indent in paths:
            for item in steps(text(path), indent):
                if TRANSFER.match(item.get('uses', '')):
                    found.append(item)
                    with self.subTest(path=path, name=item.get('name', item['uses'])):
                        self.assertEqual(indent, 6, 'transfer deadlines belong to workflow steps, not composites')
                        # Downloads are bounded by what they carry at the slowest
                        # runner rate measured: the 1.62 GB image took 255 s, the
                        # largest group's 4.7 GB compiled state took over five
                        # minutes, and the release collects every artifact of its
                        # run. Every other transfer finishes in seconds.
                        with_ = item.get('with', '')
                        collects_everything = 'name:' not in with_ and 'pattern:' not in with_
                        if 'name: devcontainer-image\n' in with_ or collects_everything:
                            ceiling = 10
                        elif 'pattern: state-' in with_:
                            ceiling = 12
                        else:
                            ceiling = 5
                        budget = item.get('timeout-minutes', '')
                        self.assertRegex(budget, r'^[1-9][0-9]*$')
                        self.assertLessEqual(int(budget), ceiling)
        self.assertTrue(found, 'no transfer declarations were read')

    def test_required_handoffs_retry_identical_inputs_without_hiding_failure(self):
        pairs = []
        for path in sorted(WORKFLOWS.glob('*.yml')):
            declared = list(steps(path.read_text()))
            for index, first in enumerate(declared):
                if first.get('continue-on-error') != 'true' or '-artifact@' not in first.get('uses', ''):
                    continue
                retry = declared[index + 1]
                pairs.append(first)
                with self.subTest(workflow=path.name, transfer=first.get('name')):
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
        self.assertTrue(any('name: devcontainer-image\n' in item['with'] for item in pairs),
                        'the unpublished image needs a bounded handoff too')


class GroupTest(unittest.TestCase):
    def test_every_job_fetches_dependencies_through_the_runner(self):
        for path, skipped in ((CHECK, ('gates', 'plan', 'image', 'linux', 'workflows', 'dependencies')), (GROUP, ())):
            for name, job in jobs(path).items():
                if name not in skipped:
                    self.assertIn('python3 ci/gates.py fetch', job.body, f'{path}: {name}')

    def test_a_group_compiles_in_shards_then_runs_each_phase(self):
        found = jobs(GROUP)
        build, test = found['build'], found['test']
        for shards, expected in (('[]', False), ('[1]', True), ('[1, 2]', True)):
            self.assertEqual(selected(build.condition, context={'inputs': {'shards': shards}}), expected)
        self.assertIn('        shard: ${{ fromJSON(inputs.shards) }}\n', build.body)
        self.assertIn('          SHARD: ${{ matrix.shard }}/${{ strategy.job-total }}\n'
                      "          PHASES: ${{ join(fromJSON(inputs.phases), ' ') }}\n"
                      '        run: $EXEC python3 ci/gates.py compile "$SHARD" $PHASES\n', build.body)
        self.assertIn('          SHARD: ${{ matrix.shard }}\n'
                      '        run: python3 ci/state.py pack "$RUNNER_TEMP/state-$SHARD.tar.zst"\n', build.body)
        self.assertIn('path: ${{ runner.temp }}/state-${{ matrix.shard }}.tar.zst', build.body)
        # download-artifact extracts a lone match into `path` and gives each of
        # several matches its own directory, so only merged, uniquely named
        # archives sit at one path for every shard count.
        receive = step(test.body, "Receive the group's compiled state")
        self.assertIn('path: ${{ runner.temp }}/state\n', receive)
        self.assertIn('merge-multiple: true', receive)
        self.assertIn('          SHARDS: ${{ inputs.shards }}\n          BUILD: ${{ needs.build.result }}\n'
                      '        run: python3 ci/state.py restore "$RUNNER_TEMP/state" "$SHARDS" "$BUILD"\n', test.body)
        self.assertIn('        phase: ${{ fromJSON(inputs.phases) }}\n', test.body)
        self.assertIn('          PHASE: ${{ matrix.phase }}\n        run: $EXEC python3 ci/gates.py run "$PHASE"\n', test.body)
        self.assertIn('run: python3 ci/gates.py summary', test.body)
        # Every shard and phase reports, and the phases run after a failed
        # compile, so one run names every failure in a group.
        for job in (build, test):
            self.assertIn('fail-fast: false', job.body)
        for result, expected in (('success', True), ('failure', True), ('skipped', True), ('cancelled', False)):
            self.assertEqual(selected(test.condition, context={'needs': {'build': {'result': result}}}), expected)
        self.assertFalse(selected(test.condition, context={'needs': {'build': {'result': 'success'}}}, cancelled=True))
        self.assertIn('evidence-${{ github.sha }}-${{ matrix.phase }}', test.body)

    def test_pull_requests_reuse_compile_state_and_everything_else_builds_cold(self):
        build = jobs(GROUP)['build'].body
        for name, expected in (
            ('Restore build state', {'pull_request'}),
            ('Bound the restored build state', {'pull_request'}),
            ('Save build state', {'push', 'schedule', 'workflow_dispatch'}),
        ):
            for event in ('pull_request', 'push', 'schedule', 'workflow_dispatch'):
                with self.subTest(step=name, event=event):
                    allowed = selected(condition(build, name), {'event_name': event},
                                       context={'steps': {'fetch': {'outcome': 'success'}}})
                    self.assertEqual(allowed, event in expected)
            self.assertFalse(selected(condition(build, name), {'event_name': 'pull_request'}, cancelled=True))
        self.assertIn('run: python3 ci/state.py bound 12 20\n', step(build, 'Bound the restored build state'))
        # The state key names the run, so a restore falls back to the shard's
        # newest state and an unrelated manifest edit keeps it.
        family = 'build-${{ runner.os }}-${{ runner.arch }}-${{ inputs.group }}-${{ matrix.shard }}of${{ strategy.job-total }}-'
        keys = []
        for name in ('Restore build state', 'Save build state'):
            block = step(build, name)
            key = re.search(r'^          key: (.+)$', block, re.M)[1]
            self.assertTrue(key.startswith(family))
            self.assertNotIn('hashFiles', key)
            self.assertTrue(key.endswith('${{ github.run_id }}-${{ github.run_attempt }}'))
            keys.append(key)
            if name == 'Restore build state':
                self.assertEqual(re.search(r'^          restore-keys: (.+)$', block, re.M)[1], family)
        self.assertEqual(keys[0], keys[1])
        # Downloads follow the dependency manifests.
        downloads = step(build, 'Restore dependency downloads')
        self.assertIn("hashFiles('build.zig.zon'", downloads)
        self.assertIn("'**/Cargo.lock'", downloads)

    def test_runs_keep_fuzzer_findings(self):
        for path, job in ((CHECK, 'scheduled-fuzz'), (GROUP, 'test')):
            with self.subTest(workflow=path):
                block = step(jobs(path)[job].body, 'Keep a fuzzer finding')
                self.assertIn("!cancelled() && hashFiles('zig-out/fuzz-finding.bin') != ''", block)
                self.assertIn('path: zig-out/fuzz-finding.bin', block)
                self.assertIn('if-no-files-found: error', block)
        self.assertIn('github.run_attempt', step(jobs(CHECK)['scheduled-fuzz'].body, 'Keep a fuzzer finding'))
        self.assertIn('zig build fuzz -Dfuzz-runs=250K', jobs(CHECK)['scheduled-fuzz'].body)


if __name__ == '__main__':
    unittest.main()
