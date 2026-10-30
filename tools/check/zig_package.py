"""Build real Zig package consumers for `zig build consumer-check`.

Snapshot current Git-visible files, then let Zig apply the manifest's package
filter through `fetch --save`. Core-only use must not execute optional build
tools. Single-transport builds and an all-module build compile, link, and run.
Requires Git, Python, Zig, Rust llvm-tools, and the optional modules' toolchains. Temporary
consumers and archives are removed on exit; compiler/package caches are retained. Child build
or fetch failures and deadlines fail the check and replay their output.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd, env=None, timeout=1800):
    result = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=timeout)
    if result.returncode:
        raise SystemExit(f'{args!r} failed ({result.returncode}):\n{result.stdout}')
    return result.stdout


def rust_nm():
    # Rust's standard library contains LLVM bitcode. The host's nm may be
    # older than that producer (notably Xcode), even when linking works.
    libdir = Path(run('rustc', '--print', 'target-libdir', cwd=ROOT, timeout=30).strip())
    tool = libdir.parent / 'bin/llvm-nm'
    if not tool.is_file():
        raise SystemExit('consumer-check: install the active Rust toolchain component: rustup component add llvm-tools')
    return str(tool)


def sidecar_exports(consumer, selection, nm):
    expected = set()
    for transport in ('iroh', 'webrtc'):
        if selection in (transport, 'optional'):
            source = ROOT / f'src/net/transport/{transport}/sidecar.zig'
            expected.update(re.findall(r'extern fn (glowcap_\w+)\(', source.read_text()))
    assert expected, 'selected transport has no sidecar declarations'
    symbols = run(nm, '-g', str(consumer / 'zig-out/sidecars.a'), cwd=consumer, timeout=30)
    actual = set()
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[-2].upper() != 'U':
            name = fields[-1].removeprefix('_')
            if re.match(r'glowcap_(iroh|webrtc)_sidecar_', name):
                actual.add(name)
    assert actual == expected, f'sidecar exports differ: missing={expected - actual}, extra={actual - expected}'


def check(zig, work):
    nm = rust_nm()
    # Read working files, not HEAD: local checks must include uncommitted fixes.
    files = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=ROOT, timeout=30).split(b'\0')
    archive = work / 'source.tar'
    with tarfile.open(archive, 'w') as package:
        for name in sorted(set(files) - {b''}):
            path = ROOT / os.fsdecode(name)
            if path.exists() or path.is_symlink():
                package.add(path, arcname='glowcap/' + os.fsdecode(name), recursive=False)

    consumer = work / 'consumer'
    shutil.copytree(ROOT / 'tools/consumer', consumer)
    run(zig, 'fetch', '--save=glowcap', str(archive), cwd=consumer)

    # A core consumer has no need for either Cargo or the relay's shell fetch.
    forbidden = work / 'optional-tools'
    forbidden.mkdir()
    for name in ('cargo', 'bash', 'curl'):
        tool = forbidden / name
        tool.write_text('#!/bin/sh\necho "core consumer invoked optional tool: $0" >&2\nexit 1\n')
        tool.chmod(0o755)
    core_env = dict(os.environ, PATH=str(forbidden) + os.pathsep + os.environ['PATH'])
    run(zig, 'build', cwd=consumer, env=core_env)
    run(str(consumer / 'zig-out/bin/glowcap-consumer'), cwd=consumer, timeout=30)
    for selection in ('iroh', 'webrtc', 'optional'):
        run(zig, 'build', f'-D{selection}=true', cwd=consumer)
        sidecar_exports(consumer, selection, nm)
        run(str(consumer / 'zig-out/bin/glowcap-consumer'), cwd=consumer, timeout=30)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', required=True, help='the build graph Zig executable')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='glowcap zig package ') as directory:
        check(args.zig, Path(directory))
