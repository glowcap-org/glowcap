"""ci/gates.sh phase contracts, loaded by publication_workflow_test.py.

A recorder stands in for python3, so each gate the script would run is logged
instead, and the evidence record is captured rather than written.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

from ci_plan_test import PLAN

ROOT = Path(__file__).resolve().parents[2]

RECORDER = textwrap.dedent("""\
    import json, os, sys
    if sys.argv[1] == 'tools/evidence/record.py':
        from pathlib import Path
        rows = Path(sys.argv[sys.argv.index('--gates') + 1]).read_text()
        Path(os.environ['GATE_RECORD']).write_text(json.dumps({'args': sys.argv[2:], 'rows': rows}))
        sys.exit(int(os.environ.get('RECORD_FAILURE', '0')))
    command = sys.argv[7:] if '--heartbeat' in sys.argv else sys.argv[5:]
    with open(os.environ['GATE_CALLS'], 'a') as output:
        output.write(json.dumps(command) + '\\n')
    sys.exit(37 if '.devcontainer/test/tool-install.sh' in command or os.environ.get('GATE_FAIL') in command else 0)
    """)


class GateRecorder:
    """Runs ci/gates.sh with every gate recorded under `directory`. A gate
    naming GATE_FAIL exits 37, and the evidence recorder exits RECORD_FAILURE."""

    def __init__(self, directory):
        self.calls = directory / 'calls.jsonl'
        self.record = directory / 'record.json'
        program = directory / 'python3'
        program.write_text(f'#!{sys.executable}\n' + RECORDER)
        program.chmod(0o755)
        self.environment = dict(os.environ, PATH=f'{directory}{os.pathsep}{os.environ["PATH"]}',
                                GATE_CALLS=str(self.calls), GATE_RECORD=str(self.record))
        self.environment.pop('GATES_SOURCE_ONLY', None)

    def gates(self, *arguments, **overrides):
        """Run ci/gates.sh with `arguments` after clearing earlier output, and
        return its result and the gates it invoked."""
        self.calls.unlink(missing_ok=True)
        self.record.unlink(missing_ok=True)
        result = subprocess.run(['bash', 'ci/gates.sh', *arguments], cwd=ROOT,
                                env=dict(self.environment, **overrides), capture_output=True, text=True)
        invoked = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, invoked


class PhaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.recorder = GateRecorder(Path(temporary.name))

    def test_ci_phases_cover_the_full_local_sequence_once(self):
        result, invoked = self.recorder.gates()
        self.assertEqual(result.returncode, 0, result.stderr)
        group = (ROOT / '.github/workflows/check-group.yml').read_text()
        self.assertIn('run: $EXEC bash ci/gates.sh ${{ matrix.phase }}\n', group)
        names, full = PLAN.select('workflow_dispatch', 'refs/heads/dev', {}, [])
        self.assertTrue(full)
        self.assertEqual(names, list(PLAN.GROUP_NAMES))
        phases = [phase for _, group_phases, _ in PLAN.GROUPS for phase in group_phases]
        self.assertEqual(len(phases), len(set(phases)))
        combined = []
        for phase in phases:
            result, commands = self.recorder.gates(phase)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(commands, phase)
            combined.extend(commands)
            record = json.loads(self.recorder.record.read_text())
            self.assertIn('zig-out/evidence/' + phase, record['args'])
            self.assertNotIn('--note', record['args'])
            self.assertEqual(len(record['rows'].splitlines()), len(commands))
        self.assertEqual(combined, invoked, 'CI phases must cover the full local sequence exactly once')
        reduced, full = PLAN.select('pull_request', 'refs/pull/7/merge',
                                     {'pull_request': {'base': {'ref': 'dev'}}}, ['README.md'])
        self.assertFalse(full)
        reduced_phases = [phase for name, group_phases, _ in PLAN.GROUPS if name in reduced
                          for phase in group_phases]
        self.assertEqual(reduced_phases, ['infrastructure', 'core', 'memcheck', 'runtime', 'shipped', 'smoke'])

    def test_a_build_job_compiles_its_shard_and_runs_nothing(self):
        # Only `zig build` lines, each rewired to its compile half, and no
        # evidence record.
        group = (ROOT / '.github/workflows/check-group.yml').read_text()
        self.assertIn('run: $EXEC bash ci/gates.sh --compile-only "$SHARD" $PHASES\n', group)
        result, compiled = self.recorder.gates('--compile-only', '2/3', 'core', 'memcheck')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[6:] for call in compiled],
                         [['check-build'], ['check'], ['test-memcheck-build'], ['test-memcheck']])
        for call in compiled:
            self.assertEqual(call[:6], ['zig', 'build', '-Dcompile-only', '-Dcompile-shard=2/3', '--summary', 'new'])
        self.assertFalse(self.recorder.record.exists())
        # Phases that open with the same shared build compile it once.
        result, compiled = self.recorder.gates('--compile-only', '1/1', 'browser-proofs-1', 'browser-proofs-2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[6:] for call in compiled],
                         [['loam-browser-build', 'rooms-web-build'],
                          ['rooms-archive-build', 'rooms-session-build', 'iroh-abi'],
                          ['rooms-web-proofs', '-Drooms-web-proof-shard=1/4'],
                          ['rooms-web-proofs', '-Drooms-web-proof-shard=2/4']])

    def test_malformed_calls_run_and_record_nothing(self):
        for arguments in (['unknown'], ['core', 'browser'], ['--compile-only', 'core'],
                          ['--compile-only', '4/3', 'core'], ['--compile-only', '1/2', 'unknown']):
            with self.subTest(arguments=arguments):
                result, invoked = self.recorder.gates(*arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(invoked, [])
                self.assertFalse(self.recorder.record.exists())

    def test_a_failed_gate_does_not_stop_its_phase(self):
        # Every gate runs and records, and the phase exits with the first
        # failure. Recorder failure must not hide a failed gate, or turn a
        # successful phase green.
        for gate_failure, record_failure, expected in [('check', '0', 37), ('check', '9', 37), ('', '9', 70)]:
            result, _ = self.recorder.gates('core', GATE_FAIL=gate_failure, RECORD_FAILURE=record_failure)
            self.assertEqual(result.returncode, expected, result.stderr)
            rows = json.loads(self.recorder.record.read_text())['rows'].splitlines()
            if gate_failure:
                self.assertGreater(len(rows), 1)
                failed = [row for row in rows if row.endswith(' ' + gate_failure)]
                self.assertEqual(len(failed), 1, rows)
                self.assertTrue(failed[0].startswith('37\t'))
                self.assertTrue(all(row.startswith('0\t') for row in rows if row is not failed[0]))

    def test_shipped_mode_partitions_cover_every_layer_once(self):
        source = (ROOT / 'test/all_test.zig').read_text()
        declared = re.search(r'const Layer = enum \{([^}]+)\}', source)[1]
        layers = [name.strip() for name in declared.split(',') if name.strip()]
        gates = (ROOT / 'ci/gates.sh').read_text()
        shipped = re.search(r'^phase shipped\n(.*?)(?=^phase |\Z)', gates, re.M | re.S)[1]
        commands = re.findall(r'^(?:gate|build) zig build test -Doptimize=ReleaseSafe(.*)$', shipped, re.M)
        selected_layers = []
        for command in commands:
            selection = re.fullmatch(r' -Dtest-layer=([a-z_,]+)', command)
            self.assertIsNotNone(selection, 'ship-mode tests must bound compiler memory by layer')
            selected_layers.extend(selection[1].split(','))
        self.assertCountEqual(selected_layers, layers)
