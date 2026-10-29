"""CI deadline, optional-cache and failure-artifact contracts.

Run by infrastructure-check. Shell
steps run with disposable stores and stub disk measurements, never host caches.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeTest(unittest.TestCase):
    def test_ocapnviz_checks_test_types_before_timed_execution(self):
        cases = [
            ('export const main = 1;\n',
             'const value: number = "invalid";\nDeno.test("runs", () => { console.log(value); });\n', False, True),
            ('export const main: number = "invalid";\n',
             'Deno.test("runs", () => { console.log("execution sentinel"); });\n', False, True),
            ('export const main = 1;\n',
             'Deno.test("fails", () => { throw new Error("execution sentinel"); });\n', True, False),
        ]
        for main, source, build_ok, run_ok in cases:
            with self.subTest(main=main, source=source), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / 'checkout with spaces'
                scripts = root / 'tools/check'
                scripts.mkdir(parents=True)
                app = root / 'apps/ocapnviz'
                (app / 'dist').mkdir(parents=True)
                (app / 'dist/glowcap_host.wasm').write_bytes(b'fixture')
                (app / 'main.ts').write_text(main)
                (app / 'phase_test.ts').write_text(source)
                (app / 'deno.json').write_text(json.dumps({'tasks': {
                    'typecheck': 'deno check main.ts', 'fmt:check': 'true', 'build': 'true',
                }}))
                for name in ('ocapnviz-build-check.sh', 'ocapnviz-test.sh'):
                    shutil.copy2(ROOT / 'tools/check' / name, scripts / name)
                for name, expected in (('ocapnviz-build-check.sh', build_ok), ('ocapnviz-test.sh', run_ok)):
                    result = subprocess.run(['bash', str(scripts / name)], cwd=temporary,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
                    if name == 'ocapnviz-build-check.sh' and not expected:
                        self.assertIn('TS2322', result.stderr)
                    if name == 'ocapnviz-test.sh' and not expected:
                        self.assertIn('execution sentinel', result.stdout + result.stderr)

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
        workflow = (ROOT / '.github/workflows/check-group.yml').read_text()
        step = workflow.split('      - name: Bound the restored build state\n', 1)[1].split('\n      - name:', 1)[0]
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        cases = [(0, 40, 12, False), (1, 40, 12, False), (7, 40, 12, False),
                 (7, 40, 2, True), (1, 5, 12, True)]
        for count, free, limit, removed in cases:
            with self.subTest(count=count, free=free, limit=limit), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                home = dict(os.environ, HOME=str(root))
                names = subprocess.run(['bash', 'ci/state.sh', 'stores'], cwd=ROOT, env=home,
                                       capture_output=True, text=True, check=True).stdout.splitlines()
                self.assertEqual(len(names), 7)
                inodes = {}
                for name in names[:count]:
                    Path(name, 'o').mkdir(parents=True)
                    Path(name, 'o/object').write_text('state\n')
                    inodes[name] = Path(name).stat().st_ino
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
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command], cwd=ROOT,
                                        env=dict(home, PATH=f"{binary}:{os.environ['PATH']}",
                                                 LIMIT_GB=str(limit), FREE_FLOOR_GB='20'),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                # A drop keeps each directory, because the container mounts it.
                for name in names[:count]:
                    self.assertEqual(Path(name).stat().st_ino, inodes[name])
                    self.assertEqual(any(Path(name).iterdir()), not removed)
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

    def test_compiled_state_round_trips_with_its_times(self):
        # A build job packs its stores and zig-out, and a test job unpacks them
        # at the same absolute paths with the times Cargo recorded. Both stamp
        # the checkout to the commit time first. zstd is the runner's; a
        # passthrough stands in for it here.
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, home, binary = base / 'checkout', base / 'home', base / 'bin'
            (root / 'ci').mkdir(parents=True)
            shutil.copy2(ROOT / 'ci/state.sh', root / 'ci/state.sh')
            (root / 'tracked.zig').write_text('source\n')
            binary.mkdir()
            (binary / 'zstd').write_text('#!/bin/sh\nexec cat\n')
            (binary / 'zstd').chmod(0o755)
            environment = dict(os.environ, HOME=str(home), PATH=f"{binary}:{os.environ['PATH']}",
                               GIT_AUTHOR_DATE='@1700000000 +0000', GIT_COMMITTER_DATE='@1700000000 +0000')

            def state(*args):
                return subprocess.run(['bash', str(root / 'ci/state.sh'), *args], cwd=base,
                                      env=environment, capture_output=True, text=True)

            for args in ((), ('stores', 'extra'), ('pack',), ('unpack',), ('unknown',)):
                self.assertEqual(state(*args).returncode, 2, args)
            self.assertEqual(state('pack', str(base / 'empty.tar.zst')).returncode, 1)

            git = ['git', '-c', 'commit.gpgsign=false', '-c', 'user.name=CI fixture',
                   '-c', 'user.email=ci@example.invalid', '-C', str(root)]
            subprocess.run([*git, 'init', '-q'], check=True)
            subprocess.run([*git, 'add', '.'], check=True)
            subprocess.run([*git, 'commit', '-qm', 'fixture'], env=environment, check=True)
            self.assertEqual(state('stamp').returncode, 0)
            for tracked in ('tracked.zig', 'ci/state.sh'):
                self.assertEqual((root / tracked).stat().st_mtime, 1700000000)

            stores = state('stores').stdout.splitlines()
            self.assertTrue(all(store.startswith(str(home) + '/') for store in stores))
            outputs = [Path(stores[1]) / 'o/object', root / 'zig-out/lib/libglowcap.a']
            for index, output in enumerate(outputs):
                output.parent.mkdir(parents=True)
                output.write_text(f'output {index}\n')
                os.utime(output, (1700000100 + index, 1700000100 + index))
            archive = base / 'state.tar.zst'
            packed = state('pack', str(archive))
            self.assertEqual(packed.returncode, 0, packed.stderr)
            shutil.rmtree(home)
            shutil.rmtree(root / 'zig-out')
            unpacked = state('unpack', str(archive))
            self.assertEqual(unpacked.returncode, 0, unpacked.stderr)
            for index, output in enumerate(outputs):
                self.assertEqual(output.read_text(), f'output {index}\n')
                self.assertEqual(output.stat().st_mtime, 1700000100 + index)
            # The passthrough compressor leaves format validation to tar.
            # Give it a full invalid header, rather than an empty short read.
            archive.write_bytes(b'\xff' * 1024)
            self.assertNotEqual(state('unpack', str(archive)).returncode, 0)

    def test_test_jobs_find_every_shard_state_or_fail(self):
        # download-artifact extracts a lone match into `path` and gives each of
        # several matches its own directory, so only merged, uniquely named
        # archives sit at one path for every shard count.
        workflow = (ROOT / '.github/workflows/check-group.yml').read_text()
        self.assertIn('ci/state.sh pack "$RUNNER_TEMP/state-${{ matrix.shard }}.tar.zst"', workflow)
        self.assertIn('path: ${{ runner.temp }}/state-${{ matrix.shard }}.tar.zst', workflow)
        receive = workflow.split("      - name: Receive the group's compiled state\n", 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('path: ${{ runner.temp }}/state\n', receive)
        self.assertIn('merge-multiple: true', receive)
        step = workflow.split("      - name: Restore the group's compiled state\n", 1)[1].split('\n      - name:', 1)[0]
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        cases = [('success', (1, 2), 0, [2, 1]), ('success', (2,), 1, []), ('success', (1,), 1, []),
                 ('failure', (2,), 0, [2]), ('failure', (), 0, [])]
        for build, present, status, unpacked in cases:
            with self.subTest(build=build, present=present), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                (base / 'ci').mkdir()
                (base / 'ci/state.sh').write_text('#!/bin/sh\necho "$2" >> unpacked\n')
                (base / 'ci/state.sh').chmod(0o755)
                (base / 'state').mkdir()
                for shard in present:
                    (base / f'state/state-{shard}.tar.zst').write_text('')
                # toJSON renders the shard list over several lines.
                result = subprocess.run(['bash', '-e', '-c', command], cwd=base,
                                        env=dict(os.environ, RUNNER_TEMP=str(base), BUILD=build,
                                                 SHARDS='[\n  1,\n  2\n]'),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                order = (base / 'unpacked').read_text().split() if (base / 'unpacked').exists() else []
                self.assertEqual(order, [str(base / f'state/state-{shard}.tar.zst') for shard in unpacked])
                for shard in {1, 2} - set(present):
                    kind = 'error' if build == 'success' else 'warning'
                    self.assertIn(f'::{kind}::Shard {shard}', result.stdout)
