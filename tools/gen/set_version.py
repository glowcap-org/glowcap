"""`zig build set-version -Dversion=X.Y.Z`: move every stated glowcap version.

`abi_version` in build.zig is the authority, and the checks hold each mirror to
it: the C ABI version constants, build.zig.zon, the archive-resolution
contract and its package copies, every tracked Cargo.toml, deno.json, the
Python and Racket manifests, the workspace entries in every tracked lock file,
and the pages that state the release version. This rewrites all of them from
the current version to the requested one, and the build step then regenerates
the header and binding constants that embed it, so a release bump is one
command and one diff. It edits the checkout in place from the repository root,
lists files with git, and exits 1 without writing when the request is
malformed, is the current version, lacks its CHANGELOG.md section, or a mirror
does not state the current version exactly once. ci/test/set_version_test.py
exercises it on a copy of the tree under infrastructure-check.
"""

import json
from pathlib import Path
import re
import subprocess
import sys


DOC_HOMES = ('README.md', 'SECURITY.md', 'docs', 'site/content')


def tracked(root, *patterns):
    listing = subprocess.run(['git', 'ls-files', '-z', '--', *patterns], cwd=root, check=True, capture_output=True).stdout
    return [path for path in listing.decode().split('\0') if path]


def stated_pages(root, old):
    """Every page under the doc homes with a `<version> alpha` token, the form source-check holds.

    Yields (path, token) for each form the page uses, plain or in a code span.
    """
    for home in DOC_HOMES:
        path = root / home
        files = [path] if path.is_file() else sorted(p for p in path.rglob('*') if p.suffix in ('.md', '.smd'))
        for page in files:
            text = page.read_text()
            for token in (f'{old} alpha', f'`{old}` alpha'):
                if token in text:
                    yield str(page.relative_to(root)), token


def edits(root, old, new):
    """Every (path, old_text, new_text, once) the bump writes.

    A mirror marked once states the version exactly one time. Pages and lock
    files may state it several times, and every occurrence moves.
    """
    o, n = old.split('.'), new.split('.')
    yield ('build.zig', f'const abi_version = std.SemanticVersion{{ .major = {o[0]}, .minor = {o[1]}, .patch = {o[2]} }};',
           f'const abi_version = std.SemanticVersion{{ .major = {n[0]}, .minor = {n[1]}, .patch = {n[2]} }};', True)
    for name, index in (('MAJOR', 0), ('MINOR', 1), ('PATCH', 2)):
        if o[index] != n[index]:
            yield ('src/c_abi/ocapn/mod.zig', f'pub const GLOWCAP_VERSION_{name}: u32 = {o[index]};',
                   f'pub const GLOWCAP_VERSION_{name}: u32 = {n[index]};', True)
    yield ('build.zig.zon', f'.version = "{old}",', f'.version = "{new}",', True)
    contract = json.loads((root / 'bindings/c-abi-resolve.json').read_text())
    for path in ['bindings/c-abi-resolve.json', *contract['package_copies']]:
        yield (path, f'"abi_version": "{old}",', f'"abi_version": "{new}",', True)
        yield (path, f'"user_agent": "glowcap-c-abi-fetch/{old}"', f'"user_agent": "glowcap-c-abi-fetch/{new}"', True)
    crates, packages = [], []
    for path in tracked(root, '*Cargo.toml'):
        text = (root / path).read_text()
        if (name := re.search(r'^name = "([^"]+)"', text, re.M)):
            crates.append(name[1])
        if f'\nversion = "{old}"\n' in text:
            yield (path, f'\nversion = "{old}"\n', f'\nversion = "{new}"\n', True)
        # A dependency on a workspace crate names its path and pins the exact version.
        for line in sorted({line for line in text.splitlines() if 'path = ' in line and f'version = "={old}"' in line}):
            yield (path, line, line.replace(f'version = "={old}"', f'version = "={new}"'), False)
    for path in tracked(root, '*deno.json'):
        text = (root / path).read_text()
        if (name := re.search(r'^\s*"name": "([^"]+)"', text, re.M)):
            packages.append(name[1])
        if f'"version": "{old}"' in text:
            yield (path, f'"version": "{old}"', f'"version": "{new}"', True)
    yield ('bindings/python/pyproject.toml', f'\nversion = "{old}"\n', f'\nversion = "{new}"\n', True)
    yield ('bindings/racket/info.rkt', f'(define version "{old}")', f'(define version "{new}")', True)
    # A lock records each workspace package by name and version. Dependencies
    # from registries keep theirs, whatever version they happen to share.
    for path in tracked(root, '*Cargo.lock'):
        text = (root / path).read_text()
        for crate in crates:
            block = f'[[package]]\nname = "{crate}"\nversion = "{old}"\n'
            if block in text:
                yield (path, block, f'[[package]]\nname = "{crate}"\nversion = "{new}"\n', False)
    for path in tracked(root, '*deno.lock'):
        text = (root / path).read_text()
        for package in packages:
            if f'jsr:{package}@{old}' in text:
                yield (path, f'jsr:{package}@{old}', f'jsr:{package}@{new}', False)
    for page, token in stated_pages(root, old):
        yield (page, token, token.replace(old, new), False)


def main():
    root = Path.cwd()
    if len(sys.argv) != 2 or not re.fullmatch(r'0\.[0-9]+\.[0-9]+', sys.argv[1]):
        sys.exit('set-version: pass one prerelease version, such as 0.1.2')
    new = sys.argv[1]
    old = json.loads((root / 'bindings/c-abi-resolve.json').read_text())['abi_version']
    if old == new:
        sys.exit(f'set-version: {new} is the current version')
    planned = []
    for path, old_text, new_text, once in edits(root, old, new):
        count = (root / path).read_text().count(old_text)
        if once and count != 1:
            sys.exit(f'set-version: {path} states {old_text!r} {count} times, expected once; nothing written')
        planned.append((path, old_text, new_text))
    if f'## [{new}]' not in (root / 'CHANGELOG.md').read_text():
        sys.exit(f'set-version: CHANGELOG.md has no "## [{new}]" section; add the entry first, nothing written')
    for path, old_text, new_text in planned:
        target = root / path
        target.write_text(target.read_text().replace(old_text, new_text))
    print(f'set-version: {old} -> {new} across {len({path for path, _, _ in planned})} files')


if __name__ == '__main__':
    main()
