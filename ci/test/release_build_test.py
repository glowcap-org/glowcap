"""Exercise release SDK selection at the workflow's actual shell boundary."""

import json
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import textwrap
import unittest

from workflow_test import ROOT, shell_step


class ReleaseBuild(unittest.TestCase):
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
