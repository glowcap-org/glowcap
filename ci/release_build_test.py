"""The release workflow's job graph, attestation scope, and build steps at their boundaries.

Reads release.yml for what each job needs, which events select it, and which job
holds the attestation permissions. A tag push runs every job. A manual dispatch
rehearses the builds and image proofs and publishes nothing. The shell steps that
verify the archive checksums and select the macOS SDK run against stub tools and
fixture archives. This does not reach GitHub runners, registries, or the signing
service. The Zig and Rust packaging checks below it run the real recipes.
"""

import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import struct
import tarfile
import tempfile
import textwrap
import unittest
from unittest import mock

from workflows import ROOT, jobs, selected, shell_step, step


spec = importlib.util.spec_from_file_location('zig_package', ROOT / 'tools/check/zig_package.py')
PACKAGE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PACKAGE)
WORKFLOW = ROOT / '.github/workflows/release.yml'


RELEASE = jobs('.github/workflows/release.yml')


class ReleaseBuild(unittest.TestCase):
    def test_a_tag_push_releases_and_a_dispatch_only_rehearses(self):
        predicate, release = RELEASE['release']
        self.assertEqual(predicate, "github.ref_type == 'tag'")
        self.assertRegex(release, r'(?m)^    needs: \[contract, archives, images\]$')
        self.assertTrue(selected(predicate, {'event_name': 'push', 'ref_type': 'tag'}))
        self.assertFalse(selected(predicate, {'event_name': 'workflow_dispatch', 'ref_type': 'branch'}))
        self.assertFalse(selected(predicate, {'event_name': 'workflow_dispatch', 'ref_type': 'tag'}, success=False))
        for name, needs in (('contract', None), ('archives', 'contract'), ('images', '[contract, archives]')):
            with self.subTest(job=name):
                body = RELEASE[name].body
                self.assertNotRegex(body, r'(?m)^    if:')
                self.assertRegex(body, rf'(?m)^    needs: {re.escape(needs)}$' if needs else r'(?m)^    timeout-minutes')
        self.assertNotIn('needs:', RELEASE['contract'].body)
        self.assertEqual(set(RELEASE), {'contract', 'archives', 'images', 'release'})

    def test_triggers_are_a_version_tag_and_a_bare_dispatch(self):
        source = WORKFLOW.read_text()
        triggers = source.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
        self.assertEqual(triggers, '  push:\n    tags: ["v*"]\n  workflow_dispatch:\n')
        self.assertNotIn('inputs', triggers)
        self.assertNotIn('actions/cache', source)
        self.assertNotIn('release_recovery', source)

    def test_only_a_tag_attests_and_only_the_archives_and_release_may_attest(self):
        archives = RELEASE['archives'].body
        attest = step(archives, "Attest the archives' build provenance")
        condition = re.search(r'(?m)^        if: (.+)$', attest)[1]
        for ref_type, expected in (('tag', True), ('branch', False), ('', False)):
            self.assertEqual(selected(condition, {'ref_type': ref_type}), expected)
        self.assertIn('uses: actions/attest-build-provenance@', attest)
        self.assertRegex(archives, r'(?m)^      attestations: write$')
        self.assertRegex(archives, r'(?m)^      id-token: write$')
        for name in ('contract', 'images'):
            with self.subTest(job=name):
                body = RELEASE[name].body
                self.assertNotIn('attestations', body)
                self.assertNotIn('id-token', body)
                self.assertNotRegex(body, r'(?m)^      (contents|packages|actions): write$')
                self.assertNotIn('attest', body)

    def test_images_take_the_archives_of_their_own_run_and_check_them_before_extracting(self):
        images = RELEASE['images'].body
        extract = step(images, 'Extract the verified Linux product')
        self.assertLess(extract.index('sha256sum --check SHA256SUMS'), extract.index('tar --extract'))
        self.assertIn('name: archives-${{ matrix.runner }}', images)
        self.assertNotIn('run-id', images)
        self.assertNotIn('github-token', images)
        script = shell_step(WORKFLOW.read_text(), 'Extract the verified Linux product')
        good = b'product'
        for label, content, name, accepted in (
                ('intact', good, 'glowcap-v0.1.0-x86_64-linux.tar.gz', True),
                ('wrong digest', b'damaged', 'glowcap-v0.1.0-x86_64-linux.tar.gz', False),
                ('other architecture', good, 'glowcap-v0.1.0-aarch64-linux.tar.gz', False)):
            with self.subTest(label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory = root / 'archive-artifact/glowcap-release'
                directory.mkdir(parents=True)
                with tarfile.open(directory / name, 'w:gz') as archive:
                    member = tarfile.TarInfo('bin/glowcap')
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
                recorded = hashlib.sha256(b'other' if label == 'wrong digest' else (directory / name).read_bytes()).hexdigest()
                (directory / 'SHA256SUMS').write_text(f'{recorded}  {name}\n')
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=root,
                                        env=dict(os.environ, VERSION='0.1.0', ARCHIVE_ARCH='x86_64'),
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual((root / 'image-context/bin/glowcap').exists(), accepted)

    def test_release_publishes_in_order_and_attests_before_it_fills_the_draft(self):
        release = RELEASE['release'].body
        order = ('Assemble the release assets',
                 "Attest the checksum file's build provenance",
                 'Publish the versioned multi-platform Rooms image',
                 "Attest the image's build provenance",
                 "Write the image's software bill of materials",
                 "Attest the image's software bill of materials",
                 'Render the release page and download every provenance bundle',
                 'Fill the draft release, then make it public',
                 'Publish the language packages at the tag')
        positions = [release.index(f'      - name: {name}\n') for name in order]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(len(set(positions)), len(order))
        self.assertIn('python3 ci/github_release.py assemble artifacts "$RELEASE_TAG"', release)
        self.assertIn('subject-path: release-assets/SHA256SUMS', release)

    def test_failed_product_archives_are_preserved_without_qualifying_them(self):
        body = RELEASE['archives'].body
        predicate = re.search(r'^        if: (.*hashFiles.*)$', body, re.M)[1]
        for present in (False, True):
            expression = predicate.replace("hashFiles('zig-out/glowcap-release/*.tar.gz')",
                                           repr('digest' if present else ''))
            for cancelled in (False, True):
                self.assertEqual(selected(expression, success=False, cancelled=cancelled),
                                 present and not cancelled)

    def test_packaging_contracts_run_before_product_compilation(self):
        workflow = WORKFLOW.read_text()
        before = workflow.index('      - name: Check release packaging contracts\n')
        self.assertLess(before, workflow.index('      - name: Install the matching browser compiler\n'))
        self.assertLess(before, workflow.index('      - name: Build the release archives\n'))
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

    def test_archives_fetch_through_the_shared_front(self):
        self.assertEqual(shell_step(WORKFLOW.read_text(), 'Fetch pinned Zig dependencies'), 'python3 ci/gates.py fetch')

    def test_release_version_stays_pre_one(self):
        source = WORKFLOW.read_text()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'bindings').mkdir()
            output = directory / 'output'
            environment = dict(os.environ, GITHUB_OUTPUT=str(output))
            for version, accepted in [('0.1.0', True), ('0.2.3', True),
                                      ('1.0.0', False), ('1.0.0-alpha.1', False),
                                      ('10.0.0', False), ('garbage', False)]:
                with self.subTest(version=version):
                    (directory / 'bindings/c-abi-resolve.json').write_text(json.dumps({'abi_version': version}))
                    output.write_text('')
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                             shell_step(source, 'Read the product version')],
                                            cwd=directory, env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)
                    self.assertEqual(output.read_text(), f'value={version}\n' if accepted else '')

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
        script = shell_step(WORKFLOW.read_text(), 'Build the release archives')
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
                               RUNNER_OS=runner, RELEASE_TARGET=target, SDK_FAIL=str(int(failed)), SDK_PATH=str(sdk),
                               ARGUMENT_LOG=str(log))
                    env.pop('SDKROOT', None)
                    result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                             script],
                                            cwd=directory, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, not failed, result.stderr)
                    if failed:
                        self.assertFalse(log.exists())
                        continue
                    expected = ['build', '-Doptimize=ReleaseSafe', 'release-pack', 'glowcap-pack',
                                '-Dcpu=baseline', '-Dtarget=' + target]
                    self.assertEqual(json.loads(log.read_text()),
                                     [expected, str(sdk) if runner == 'macOS' else None])
