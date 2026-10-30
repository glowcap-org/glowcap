"""Exercise release SDK selection at the workflow's actual shell boundary."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import textwrap
import unittest
from unittest import mock

from workflow_test import ROOT, shell_step


spec = importlib.util.spec_from_file_location('zig_package', ROOT / 'tools/check/zig_package.py')
PACKAGE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PACKAGE)


class ReleaseBuild(unittest.TestCase):
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
