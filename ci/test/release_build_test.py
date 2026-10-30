"""Exercise release rechecks and toolchain selection at their shell boundary."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import struct
import tempfile
import textwrap
import unittest
from unittest import mock

from workflow_test import ROOT, jobs, shell_step
from workflow_expression import selected


spec = importlib.util.spec_from_file_location('zig_package', ROOT / 'tools/check/zig_package.py')
PACKAGE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PACKAGE)


class ReleaseBuild(unittest.TestCase):
    def test_product_recheck_is_separate_from_build_and_publication(self):
        declared = jobs('.github/workflows/release.yml')
        for event, run, builds, rechecks in (
            ('push', '', True, False), ('push', '123', True, False),
            ('workflow_dispatch', '', True, False), ('workflow_dispatch', '123', False, True),
        ):
            with self.subTest(event=event, run=run):
                context = {'inputs': {'recheck_run': run}}
                self.assertEqual(selected(declared['archives'][0], {'event_name': event}, context=context), builds)
                self.assertEqual(selected(declared['recheck'][0], {'event_name': event}, context=context), rechecks)
        body = declared['recheck'][1]
        self.assertIn('run-id: ${{ inputs.recheck_run }}', body)
        self.assertIn('name: archives-${{ matrix.runner }}', body)
        self.assertNotIn('zig build', body)
        self.assertNotIn(': write', body)

    def test_images_require_verified_archives_or_a_successful_product_recheck(self):
        predicate, body = jobs('.github/workflows/release.yml')['images']
        for archives, recheck, allowed in (('success', 'skipped', True),
                                           ('skipped', 'success', True),
                                           ('failure', 'skipped', False),
                                           ('skipped', 'failure', False),
                                           ('skipped', 'skipped', False)):
            for contract in ('success', 'failure'):
                for cancelled in (False, True):
                    context = {'needs': {'contract': {'result': contract},
                                        'archives': {'result': archives},
                                        'recheck': {'result': recheck}}}
                    self.assertEqual(selected(predicate, context=context, success=False, cancelled=cancelled),
                                     allowed and contract == 'success' and not cancelled)
        self.assertIn('run-id: ${{ inputs.recheck_run || github.run_id }}', body)
        self.assertIn('github-token: ${{ github.token }}', body)
        self.assertNotIn(': write', body)

    def test_failed_product_archives_are_preserved_without_qualifying_them(self):
        body = jobs('.github/workflows/release.yml')['archives'][1]
        predicate = re.search(r'^        if: (.*hashFiles.*)$', body, re.M)[1]
        for present in (False, True):
            expression = predicate.replace("hashFiles('zig-out/glowcap-release/*.tar.gz')",
                                           repr('digest' if present else ''))
            for cancelled in (False, True):
                self.assertEqual(selected(expression, success=False, cancelled=cancelled),
                                 present and not cancelled)

    def test_recheck_verifies_one_archive_and_preserves_proof_failure(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        script = shell_step(workflow, 'Recheck the installed product')
        for count, damaged, status in ((1, False, 0), (1, False, 37), (1, True, 0),
                                       (0, False, 0), (2, False, 0)):
            with self.subTest(count=count, damaged=damaged, status=status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory = root / 'archive-artifact/glowcap-release'
                directory.mkdir(parents=True)
                for index in range(count):
                    (directory / f'glowcap-v0.1.{index}-host.tar.gz').write_bytes(b'product')
                product = directory / 'glowcap-v0.1.0-host.tar.gz'
                digest = hashlib.sha256(b'damaged' if damaged else b'product').hexdigest()
                (directory / 'SHA256SUMS').write_text(f'{digest}  {product.name}\n')
                proof = root / 'tools/check/glowcap_release.py'
                proof.parent.mkdir(parents=True)
                proof.write_text('import json,os,sys\nfrom pathlib import Path\n'
                                 'Path("proof-call").write_text(json.dumps(sys.argv[1:]))\n'
                                 'raise SystemExit(int(os.environ["PROOF_STATUS"]))\n')
                result = subprocess.run(['bash', '-ec', script], cwd=root,
                                        env=dict(os.environ, PROOF_STATUS=str(status)),
                                        capture_output=True, text=True, timeout=5)
                called = count == 1 and not damaged
                self.assertEqual((root / 'proof-call').exists(), called, result.stderr)
                self.assertEqual(result.returncode, status if called else 1, result.stderr)
                if called:
                    self.assertEqual(json.loads((root / 'proof-call').read_text()),
                                     ['archive-artifact/glowcap-release/' + product.name])

    def test_packaging_contracts_run_before_product_compilation(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        before = workflow.index('      - name: Check release packaging contracts\n')
        self.assertLess(before, workflow.index('      - name: Install the matching browser compiler\n'))
        self.assertLess(before, workflow.index('      - name: Build the release tarball\n'))
        block = workflow[before:].split('\n      - ', 1)[0]
        self.assertIn('run: zig build glowcap-package-test --summary all', block)
        self.assertNotIn('continue-on-error', block)

    def test_sidecar_inspection_uses_the_producing_rust_toolchain(self):
        for path in ('.devcontainer/image/rust.sh', '.github/workflows/release.yml'):
            self.assertRegex((ROOT / path).read_text(), r'rustup component add [^\n]*\bllvm-tools\b')
        with tempfile.TemporaryDirectory(prefix='Rust toolchain ') as temporary:
            host = Path(temporary) / 'lib/rustlib/host'
            tool = host / 'bin/llvm-nm'
            tool.parent.mkdir(parents=True)
            tool.touch()
            with mock.patch.object(PACKAGE, 'run', return_value=str(host / 'lib') + '\n') as run:
                self.assertEqual(PACKAGE.rust_nm(), str(tool))
                run.assert_called_once_with('rustc', '--print', 'target-libdir', cwd=ROOT, timeout=30)
                tool.unlink()
                with self.assertRaisesRegex(SystemExit, 'rustup component add llvm-tools'):
                    PACKAGE.rust_nm()

    def test_sidecar_export_inspection_remains_exact(self):
        consumer = Path('/consumer with spaces')
        nm = '/Rust toolchain/bin/llvm-nm'
        expected = {'glowcap_iroh_sidecar_new', 'glowcap_iroh_sidecar_drop'}
        declarations = '\n'.join(f'extern fn {name}(' for name in expected)
        good = ('0000 T _glowcap_iroh_sidecar_new\n0000 T _glowcap_iroh_sidecar_drop\n'
                '         U _glowcap_iroh_sidecar_undefined\n0000 T _unrelated\n')
        for symbols, passes in ((good, True), (good.replace('T _glowcap_iroh_sidecar_drop', 'U _glowcap_iroh_sidecar_drop'), False),
                                 (good + '0000 T _glowcap_iroh_sidecar_extra\n', False)):
            with self.subTest(symbols=symbols), mock.patch.object(Path, 'read_text', return_value=declarations), \
                    mock.patch.object(PACKAGE, 'run', return_value=symbols) as run:
                if passes:
                    PACKAGE.sidecar_exports(consumer, 'iroh', nm)
                else:
                    with self.assertRaisesRegex(AssertionError, 'sidecar exports differ'):
                        PACKAGE.sidecar_exports(consumer, 'iroh', nm)
                run.assert_called_once_with(nm, '-g', str(consumer / 'zig-out/sidecars.a'), cwd=consumer, timeout=30)

    def test_archive_acquisition_delegates_and_propagates_failure(self):
        script = shell_step((ROOT / '.github/workflows/release.yml').read_text(),
                            'Fetch pinned Zig dependencies')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'ci').mkdir()
            (directory / 'ci/fetch-zig.sh').write_text(
                '#!/bin/bash\nprintf "%s" "$*" > "$FETCH_LOG"\nexit "$FETCH_STATUS"\n')
            log = directory / 'fetch-arguments'
            for status in (0, 37, 143):
                with self.subTest(status=status):
                    log.unlink(missing_ok=True)
                    result = subprocess.run(['bash', '-ec', script], cwd=directory,
                                            env=dict(os.environ, FETCH_LOG=str(log), FETCH_STATUS=str(status)),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(log.read_text(), '')

    def test_macos_shared_archive_records_its_abi_major(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ('common.zig', 'execution.zig', 'shard.zig'):
                (directory / name).write_bytes((ROOT / 'tools/build' / name).read_bytes())
            (directory / 'library.zig').write_text('export fn answer() u32 { return 42; }\n')
            (directory / 'build.zig').write_text(textwrap.dedent('''\
                const std = @import("std");
                const common = @import("common.zig");
                pub fn build(b: *std.Build) void {
                    const library = b.addLibrary(.{
                        .name = "probe", .linkage = .dynamic,
                        .version = .{ .major = 3, .minor = 2, .patch = 1 },
                        .root_module = b.createModule(.{
                            .root_source_file = b.path("library.zig"),
                            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }),
                            .optimize = .Debug,
                        }),
                    });
                    common.configureSharedArchive(library);
                    b.installArtifact(library);
                }
                '''))
            result = subprocess.run(['zig', 'build', '--cache-dir', str(directory / 'cache')],
                                    cwd=directory, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            binary = (directory / 'zig-out/lib/libprobe.3.2.1.dylib').read_bytes()
            self.assertEqual(struct.unpack_from('<I', binary)[0], 0xfeedfacf)
            offset = 32
            for _ in range(struct.unpack_from('<I', binary, 16)[0]):
                command, size = struct.unpack_from('<II', binary, offset)
                if command == 0xd:  # LC_ID_DYLIB
                    start = offset + struct.unpack_from('<I', binary, offset + 8)[0]
                    self.assertEqual(binary[start:binary.index(b'\0', start)], b'@rpath/libprobe.3.dylib')
                    break
                offset += size
            else:
                self.fail('shared archive has no LC_ID_DYLIB')

    def test_transport_linker_searches_the_selected_sdk(self):
        # An empty SDK makes the linker report where it searched. Exercise the
        # real shared recipe: shell argument checks cannot prove SDK discovery.
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            sdk = directory / 'SDK with spaces'
            (sdk / 'usr/lib').mkdir(parents=True)
            (sdk / 'System/Library/Frameworks').mkdir(parents=True)
            for name in ('common.zig', 'execution.zig', 'shard.zig'):
                (directory / name).write_bytes((ROOT / 'tools/build' / name).read_bytes())
            (directory / 'sidecar.a').write_bytes(b'!<arch>\n')
            (directory / 'main.zig').write_text('pub fn main() void {}\n')
            (directory / 'build.zig').write_text(textwrap.dedent('''\
                const std = @import("std");
                const common = @import("common.zig");
                pub fn build(b: *std.Build) void {
                    const target = b.resolveTargetQuery(.{
                        .cpu_arch = .aarch64, .os_tag = .macos,
                        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
                    });
                    const module = b.createModule(.{
                        .root_source_file = b.path("main.zig"),
                        .target = target, .optimize = .Debug,
                    });
                    common.linkRustSidecar(b, module, target, b.path("sidecar.a"));
                    b.installArtifact(b.addExecutable(.{ .name = "probe", .root_module = module }));
                }
                '''))
            result = subprocess.run(['zig', 'build', '--cache-dir', str(directory / 'cache')], cwd=directory,
                                    env=dict(os.environ, SDKROOT=str(sdk)),
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0, 'the empty SDK must refuse linking')
            self.assertIn(str(sdk / 'usr/lib/libobjc'), result.stderr)
            self.assertIn(str(sdk / 'System/Library/Frameworks/Foundation.framework'), result.stderr)
            self.assertNotIn('searched paths: none', result.stderr)

    def test_archive_build_selects_the_sdk_only_on_macos(self):
        script = shell_step((ROOT / '.github/workflows/release.yml').read_text(),
                            'Build the release tarball')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / 'arguments.json'
            sdk = directory / 'SDK with spaces'
            for name, source in {
                'zig': '#!/usr/bin/env python3\nimport json,os,sys\n'
                       'open(os.environ["ARGUMENT_LOG"], "w").write(json.dumps('
                       '[sys.argv[1:], os.environ.get("SDKROOT")]))\n',
                'xcrun': '#!/bin/bash\n[[ "$*" == "--sdk macosx --show-sdk-path" ]] || exit 2\n'
                         '[[ "$SDK_FAIL" == 0 ]] || exit 1\nprintf "%s\\n" "$SDK_PATH"\n',
            }.items():
                path = directory / name
                path.write_text(source)
                path.chmod(0o755)
            for runner, failed in [('Linux', False), ('macOS', False), ('macOS', True)]:
                with self.subTest(runner=runner, sdk_failed=failed):
                    log.unlink(missing_ok=True)
                    target = 'aarch64-macos.15.0' if runner == 'macOS' else 'aarch64-linux-gnu.2.39'
                    env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                               RUNNER_OS=runner, SDK_FAIL=str(int(failed)), SDK_PATH=str(sdk),
                               ARGUMENT_LOG=str(log))
                    env.pop('SDKROOT', None)
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                             script.replace('${{ matrix.target }}', target)],
                                            cwd=directory, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, not failed, result.stderr)
                    if failed:
                        self.assertFalse(log.exists())
                        continue
                    expected = ['build', '-Doptimize=ReleaseSafe', 'release-pack', 'glowcap-pack',
                                '-Dcpu=baseline', '-Dtarget=' + target]
                    self.assertEqual(json.loads(log.read_text()),
                                     [expected, str(sdk) if runner == 'macOS' else None])
