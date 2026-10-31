"""release.yml: render newcomer instructions from verified release archives.

Read --assets and --provenance produced by release_recovery.py, validate the
archive labels and required entry points, and write --output before publishing.
The notes open with the version's CHANGELOG.md section, and --changelog VERSION
alone prints that section so the release contract fails before any build when
it is missing or the Unreleased section still holds entries. No extraction,
builds, or remote effects. Python and the checkout cwd are owned by the release
workflow. infrastructure-check exercises fixtures and refusals.
"""

import argparse
import json
from pathlib import Path
import re
import sys
import tarfile


PREDICATE = 'https://glowcap.org/attestations/release-publication/v1'
CHANGELOG = Path(__file__).resolve().parents[2] / 'CHANGELOG.md'
PLATFORMS = {
    'aarch64-macos': 'macOS, Apple Silicon (M1 and later)',
    'x86_64-macos': 'macOS, Intel',
    'aarch64-linux': 'Linux, ARM64',
    'x86_64-linux': 'Linux, x86-64',
}


def changelog_section(version, path=CHANGELOG):
    """The version's changelog body, with the Unreleased section already emptied."""
    sections = {}
    heading = None
    for line in path.read_text().splitlines():
        if line.startswith('## '):
            match = re.fullmatch(r'## \[([^\]]+)\](?: - [0-9]{4}-[0-9]{2}-[0-9]{2})?', line)
            if match is None:
                raise ValueError(f'changelog heading is not a Keep a Changelog version: {line}')
            heading = match[1]
            sections[heading] = []
        elif heading is not None and not re.fullmatch(r'\[[^\]]+\]: \S+', line):
            sections[heading].append(line)
    if any(line.strip() for line in sections.get('Unreleased', [])):
        raise ValueError('CHANGELOG.md still lists Unreleased changes; move them under the version')
    body = '\n'.join(sections.get(version, [])).strip()
    if not body:
        raise ValueError(f'CHANGELOG.md has no entry for {version}')
    return body + '\n'


def catalog(directory, source):
    tag, commit = source['tag'], source['commit']
    if not re.fullmatch(r'v0\.[0-9]+\.[0-9]+', tag) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('invalid tagged source')
    result = {target: {} for target in PLATFORMS}
    common = ('README.md', 'PROVENANCE.md', 'LICENSE-APACHE', 'LICENSE-THIRD-PARTY')
    for path in sorted(directory.glob('*.tar.gz')):
        match = re.fullmatch(r'glowcap(-c)?-' + re.escape(tag) + r'-(.+)\.tar\.gz', path.name)
        if not match or match[2] not in result:
            raise ValueError(f'unexpected release archive: {path.name}')
        target, role = match[2], 'sdk' if match[1] else 'product'
        if role in result[target]:
            raise ValueError(f'duplicate archive for {target}/{role}')
        with tarfile.open(path) as archive:
            metadata = archive.getmember('share/glowcap/release.json')
            if not metadata.isfile() or not 0 < metadata.size <= 65536:
                raise ValueError(f'invalid release metadata: {path.name}')
            value = json.load(archive.extractfile(metadata))
            runtime = 'macOS' if target.endswith('-macos') else 'glibc'
            if (value['version'] != tag[1:] or value['target'] != target
                    or value['revision'] != commit or value['dirty'] is not False
                    or not re.fullmatch(runtime + r' [0-9]+\.[0-9]+\.[0-9]+', value['minimum_runtime'])):
                raise ValueError(f'archive metadata disagrees with its release: {path.name}')
            entries = ('include/glowcap_ocapn.h', 'lib/libglowcap_ocapn.a') if role == 'sdk' else (
                'bin/glowcap', 'libexec/rooms-server', 'libexec/rooms-session',
                'share/glowcap/rooms/page.html', 'share/glowcap/rooms/page.js',
                'share/glowcap/rooms/rooms_browser_bg.wasm',
                'share/glowcap/skills/rooms-peer/SKILL.md', 'share/glowcap/skills/rooms-team/SKILL.md')
            for name in (*common, *entries):
                member = archive.getmember(name)
                if not member.isfile() or not member.size:
                    raise ValueError(f'missing release entry point: {path.name}: {name}')
        result[target][role] = {'name': path.name, 'minimum': value['minimum_runtime']}
    for target, roles in result.items():
        if set(roles) != {'product', 'sdk'} or roles['product']['minimum'] != roles['sdk']['minimum']:
            raise ValueError(f'missing or inconsistent product/SDK pair: {target}')
    return result


def render(directory, provenance, changelog=CHANGELOG):
    source = provenance['source']
    repository = source['repository']
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid source repository')
    slug = repository.removeprefix('https://github.com/')
    if not re.fullmatch(re.escape(repository) + r'/actions/runs/[1-9][0-9]*', source['run']):
        raise ValueError('invalid source run')
    tag = source['tag']
    version = tag[1:]
    packages = catalog(directory, source)
    base = f'{repository}/releases/download/{tag}'
    rows = []
    for target, title in PLATFORMS.items():
        product, sdk = packages[target]['product'], packages[target]['sdk']
        rows.append(f'| {title} | [CLI + Rooms]({base}/{product["name"]}) | '
                    f'[C SDK]({base}/{sdk["name"]}) | {product["minimum"]} or newer |')
    table = '\n'.join(rows)
    changes = changelog_section(version, changelog)
    return f'''# What changed in {version}

{changes}
Every release is listed in the [changelog]({repository}/blob/{tag}/CHANGELOG.md).

# Choose a download

For the **CLI, Rooms, browser assets, and agent skills**, choose **CLI + Rooms**.
Its filename starts with `glowcap-{tag}-`. The **C SDK** starts with
`glowcap-c-{tag}-` and contains headers and libraries for building applications.
The SDK does not contain the CLI or Rooms.

| Platform | Product | Libraries | Requires |
| --- | --- | --- | --- |
{table}

Windows and Linux musl distributions, including Alpine, have no prebuilt package.
GitHub's automatic **Source code** downloads contain source for building.
They are separate from the compiled downloads above.

# Verify and install the product

One command downloads this release for your machine, verifies it against
`SHA256SUMS`, and runs the product's installer:

```sh
curl -fsSL https://glowcap.org/install.sh | GLOWCAP_VERSION={version} sh
```

To do the same by hand, download your product archive and [SHA256SUMS]({base}/SHA256SUMS).
For example, on an Apple Silicon Mac:

```sh
archive=glowcap-{tag}-aarch64-macos.tar.gz
shasum -a 256 "$archive"
```

On Linux, choose the Linux archive and use `sha256sum "$archive"` instead.
Compare the result with the same filename in `SHA256SUMS`.
With the GitHub CLI installed, also verify the signed publication attestation:

```sh
gh attestation verify "$archive" \\
  --repo {slug} \\
  --signer-workflow {slug}/.github/workflows/release.yml \\
  --predicate-type {PREDICATE}
```

Then extract into a new directory and install the complete product:

```sh
mkdir glowcap-unpacked
tar -xzf "$archive" -C glowcap-unpacked
./glowcap-unpacked/bin/glowcap install
export PATH="$HOME/.local/bin:$PATH"
glowcap help
glowcap apps rooms serve
```

Open the browser URL printed by `serve`. Ctrl-C stops the service.
Add the PATH entry to your shell configuration. Keep the installed product's
files together, rather than moving only `bin/glowcap`.

macOS executables are not Developer ID signed or notarized. After verification,
use **Open Anyway** under **System Settings**, **Privacy & Security** if macOS
blocks execution. Keep Gatekeeper enabled.

Inside the product, `bin/glowcap` is the CLI, `libexec/` contains Rooms services,
`share/glowcap/rooms/` holds browser assets, and `share/glowcap/skills/` holds
agent skills. [Installation and Rooms commands]({repository}/blob/main/apps/rooms/host.md).

# Use the C SDK

Extract the **C SDK** into an empty directory. Use `include/` and `lib/` with
your C compiler, following the [C ABI guide]({repository}/blob/main/docs/consuming-from-c.md).
It has no CLI to install. Use libraries from the same SDK build.

# Run the Rooms container

The public image supports Linux amd64 and arm64. Docker selects the architecture,
including on macOS with Docker Desktop. This command keeps state in a named volume:

```sh
docker run --rm --name glowcap-rooms \\
  -p 127.0.0.1:8080:8080 \\
  -v glowcap-rooms-state:/state \\
  -e GLOWCAP_ROOMS_STATE=/state \\
  ghcr.io/{slug}-rooms:{tag} --http-bind=0.0.0.0
```

Open http://127.0.0.1:8080. The web port is local to this machine. The directory
uses encrypted iroh discovery and can be reached by peers holding its locator.
For persistent supervised hosting and HTTPS, use the
[deployment guide]({repository}/blob/main/apps/rooms/web/deploy/README.md).

The image carries the same signed publication attestation as the archives:

```sh
gh attestation verify oci://ghcr.io/{slug}-rooms:{tag} \\
  --repo {slug} \\
  --signer-workflow {slug}/.github/workflows/release.yml \\
  --predicate-type {PREDICATE}
```

# Install a language package

Each package is version {version} and downloads this release's C SDK for its
platform on first use, verified against `SHA256SUMS`. Set `GLOWCAP_LIB_DIR` to
an extracted SDK's `lib/` to use a local copy instead.

```sh
cargo add glowcap@={version}
pip install glowcap=={version}
deno add jsr:@glowcap/runtime@{version} jsr:@glowcap/tcp@{version}
raco pkg install glowcap
```

The [bindings guide]({repository}/blob/{tag}/bindings/README.md) lists every
package. Zig users depend on the [{tag} source]({repository}/tree/{tag}). The
browser files in the product are the Rooms application, not a published package.

# Source and license

Apache-2.0 alpha software. APIs, ABIs, and storage formats may change before 1.0.
Read the [project provenance]({repository}/blob/{tag}/PROVENANCE.md) and the
`LICENSE-APACHE` and `LICENSE-THIRD-PARTY` files included in each archive.
Source commit: `{source['commit']}`. [Original artifact run]({source['run']}).

<!-- glowcap-source-run: {source['run'].rsplit('/', 1)[1]} -->
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--changelog', metavar='VERSION', help='print this version\'s changelog section and stop')
    parser.add_argument('--assets', type=Path)
    parser.add_argument('--provenance', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.changelog:
        if args.assets or args.provenance or args.output:
            parser.error('--changelog takes the version alone')
        print(changelog_section(args.changelog), end='')
        return
    if not (args.assets and args.provenance and args.output):
        parser.error('--assets, --provenance, and --output are required')
    args.output.write_text(render(args.assets, json.loads(args.provenance.read_text())))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        sys.exit(f'release-notes: {error}')
