"""CI deadline, optional-cache and failure-artifact contracts.

Loaded by publication_workflow_test.py under infrastructure-check. Shell
steps run with disposable stores and stub disk measurements, never host caches.
"""

import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeTest(unittest.TestCase):
    def test_deadline_defaults_and_overrides(self):
        cases = [({}, '60m 20m 40m'),
                 ({'GATE_TIMEOUT': '7m'}, '7m 7m 7m'),
                 ({'BUILD_TIMEOUT': '9m'}, '9m 20m 40m'),
                 ({'LONG_TIMEOUT': '8m'}, '60m 20m 8m'),
                 ({'GATE_TIMEOUT': '7m', 'BUILD_TIMEOUT': '9m', 'LONG_TIMEOUT': '8m'}, '9m 7m 8m')]
        environment = {k: v for k, v in os.environ.items()
                       if k not in ('GATE_TIMEOUT', 'BUILD_TIMEOUT', 'LONG_TIMEOUT')}
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                result = subprocess.run(
                    ['bash', '-c', 'GATES_SOURCE_ONLY=1 source ci/gates.sh; '
                     'printf "%s %s %s" "$BUILD_TIMEOUT" "$GATE_TIMEOUT" "$LONG_TIMEOUT"'],
                    cwd=ROOT, env=dict(environment, **overrides), capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, expected)

    def test_cache_accounting_accepts_missing_stores_and_bounds_present_ones(self):
        workflow = (ROOT / '.github/workflows/check.yml').read_text()
        step = workflow.split('      - name: Bound the restored build state\n', 1)[1].split('\n      - name:', 1)[0]
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        cases = [(0, 40, 12, False), (1, 40, 12, False), (7, 40, 12, False),
                 (7, 40, 2, True), (1, 5, 12, True)]
        for count, free, limit, removed in cases:
            with self.subTest(count=count, free=free, limit=limit), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stores = root / 'stores'
                names = ('tool/zig', 'ci/zig-local', 'ci/cargo-build', 'tool/deno/gen',
                         'tool/deno/check_cache_v2', 'tool/deno/dep_analysis_cache_v2', 'tool/deno/v8_code_cache_v2')
                for name in names[:count]:
                    (stores / name).mkdir(parents=True)
                binary = root / 'bin'
                binary.mkdir()
                (binary / 'du').write_text('#!/usr/bin/env python3\n' + textwrap.dedent('''\
                    import pathlib, sys
                    missing = False
                    for arg in sys.argv[1:]:
                        if arg.startswith('-'): continue
                        if pathlib.Path(arg).exists(): print('1\\t' + arg)
                        else: missing = True
                    sys.exit(1 if missing else 0)
                    '''))
                (binary / 'df').write_text(f'#!/bin/sh\nprintf "Avail\\n{free}\\n"\n')
                for path in binary.iterdir():
                    path.chmod(0o755)
                isolated = command.replace('~/.cache/glowcap/', shlex.quote(str(stores)) + '/')
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', isolated],
                                        env=dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                                                 LIMIT_GB=str(limit), FREE_FLOOR_GB='20'),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in names[:count]:
                    self.assertEqual((stores / name).exists(), not removed)
                self.assertIn('Restored build state:', result.stdout)

    def test_nightly_keeps_the_fuzzer_reproducer_on_failure(self):
        workflow = (ROOT / '.github/workflows/check.yml').read_text()
        nightly = workflow.split('  scheduled-fuzz:\n', 1)[1].split('\n  macos-runtime:', 1)[0]
        step = re.search(r"      - name: Keep a fuzzer finding\n((?: {8}[^\n]*\n|\n)*)", nightly)
        self.assertIsNotNone(step)
        self.assertIn("!cancelled() && hashFiles('zig-out/fuzz-finding.bin') != ''", step[1])
        self.assertIn('path: zig-out/fuzz-finding.bin', step[1])
        self.assertIn('if-no-files-found: error', step[1])
        self.assertIn('github.run_attempt', step[1])
