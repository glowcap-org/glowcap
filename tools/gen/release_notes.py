"""release.yml: render the release page a newcomer reads, from verified release facts.

`--facts artifacts/release.json --image-digest sha256:... --output FILE` renders the
notes from the facts github_release.py assembled: what changed (the version's
CHANGELOG.md section), which download fits which machine, how to verify and
install each piece, where the packages appear, and where to report a problem.
Every link pins the tag, and a changelog link relative to the repository is made
absolute. `--changelog VERSION` alone prints the section so the release contract
fails before any build when it is missing or Unreleased still holds entries. No
extraction, builds, or remote effects. ci/test/release_notes_test.py holds the
rendered sections and the refusals.
"""

import argparse
import json
from pathlib import Path
import re
import sys


CHANGELOG = Path(__file__).resolve().parents[2] / 'CHANGELOG.md'
PLATFORMS = {
    'aarch64-macos': 'macOS, Apple Silicon',
    'x86_64-macos': 'macOS, Intel',
    'aarch64-linux': 'Linux, ARM64',
    'x86_64-linux': 'Linux, x86-64',
}
EXAMPLE_TARGET = 'aarch64-macos'


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


def absolute_links(markdown, repository, tag):
    """Repository-relative links in a changelog entry point at the tag's tree."""
    return re.sub(r'\]\((?!https?://|#)([^)\s]+)\)', rf']({repository}/blob/{tag}/\1)', markdown)


def render(facts, image_digest, changelog=CHANGELOG):
    repository, tag, version = facts['repository'], facts['tag'], facts['version']
    if not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid source repository')
    if not re.fullmatch(r'v0\.[0-9]+\.[0-9]+', tag) or tag[1:] != version:
        raise ValueError('invalid release tag')
    if not re.fullmatch(r'[0-9a-f]{40}', facts['commit']):
        raise ValueError('invalid source commit')
    if not re.fullmatch(re.escape(repository) + r'/actions/runs/[1-9][0-9]*', facts['run']):
        raise ValueError('invalid release run')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_digest):
        raise ValueError('invalid image digest')
    archives = {(archive['target'], archive['role']): archive for archive in facts['archives']}
    if set(archives) != {(target, role) for target in PLATFORMS for role in ('product', 'sdk')}:
        raise ValueError('release facts do not name a product and an SDK for every platform')
    slug = repository.removeprefix('https://github.com/')
    tree = f'{repository}/blob/{tag}'
    base = f'{repository}/releases/download/{tag}'
    image = f'ghcr.io/{slug}-rooms'
    example = archives[(EXAMPLE_TARGET, 'product')]['name']
    rows = '\n'.join(
        f'| {title} | [CLI + Rooms]({base}/{archives[(target, "product")]["name"]}) | '
        f'[C SDK]({base}/{archives[(target, "sdk")]["name"]}) | {archives[(target, "product")]["minimum_runtime"]} or newer |'
        for target, title in PLATFORMS.items())
    changes = absolute_links(changelog_section(version, changelog), repository, tag)
    return f'''glowcap is a Zig library for capability-based networking (OCapN and CapTP) and
durable application state, with a CLI, the Rooms chat app, and packages for
Rust, Python, TypeScript, and Racket. This page is the complete release: every
download, how to verify it, and how to install each piece. Read the
[documentation](https://glowcap.org), report a problem in the
[issues]({repository}/issues), and report a vulnerability as
[SECURITY.md]({tree}/SECURITY.md) describes.

# What changed in {version}

{changes}
Every release is listed in the [changelog]({tree}/CHANGELOG.md).

# Choose a download

For the **CLI, Rooms, browser assets, and agent skills**, choose **CLI + Rooms**.
Its filename starts with `glowcap-{tag}-`. The **C SDK** starts with
`glowcap-c-{tag}-` and contains headers and libraries for building applications.
The SDK does not contain the CLI or Rooms.

| Platform | Product | Libraries | Requires |
| --- | --- | --- | --- |
{rows}

The Linux archives need the glibc version shown or newer. `ldd --version` prints
yours. Windows and musl distributions such as Alpine have no prebuilt package.
GitHub's automatic **Source code** downloads contain source for building and are
separate from the compiled downloads above.

# Verify and install the product

One command downloads this release for your machine, verifies it against
`SHA256SUMS`, and runs the product's installer:

```sh
curl -fsSL https://glowcap.org/install.sh | GLOWCAP_VERSION={version} sh
```

To do the same by hand, download your product archive and [SHA256SUMS]({base}/SHA256SUMS).
For example, on an Apple Silicon Mac:

```sh
archive={example}
shasum -a 256 "$archive"
```

On Linux, choose the Linux archive and use `sha256sum "$archive"` instead.
Compare the result with the same filename in `SHA256SUMS`.

Every archive and `SHA256SUMS` carries a signed build provenance attestation
from this repository's release workflow. With the GitHub CLI 2.49 or newer:

```sh
gh attestation verify "$archive" --repo {slug}
```

The same check works offline with the bundle published beside each file:

```sh
gh attestation verify "$archive" --repo {slug} --bundle "$archive.sigstore.json"
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
files together, rather than moving only `bin/glowcap`. To remove an
installation, delete its directory under `~/.local/lib/glowcap/` and the
`~/.local/bin/glowcap` link.

macOS executables are not Developer ID signed or notarized. After verification,
use **Open Anyway** under **System Settings**, **Privacy & Security** if macOS
blocks execution. Keep Gatekeeper enabled.

Inside the product, `bin/glowcap` is the CLI, `libexec/` contains Rooms services,
`share/glowcap/rooms/` holds browser assets, and `share/glowcap/skills/` holds
agent skills. [Installation and Rooms commands]({tree}/apps/rooms/host.md).

# Use the C SDK

Extract the **C SDK** into an empty directory. Use `include/` and `lib/` with
your C compiler, following the [C ABI guide]({tree}/docs/consuming-from-c.md).
It has no CLI to install. Use libraries from the same SDK build.

# Run the Rooms container

The public image supports Linux amd64 and arm64. Docker selects the architecture,
including on macOS with Docker Desktop. This command keeps state in a named volume:

```sh
docker run --rm --name glowcap-rooms \\
  -p 127.0.0.1:8080:8080 \\
  -v glowcap-rooms-state:/state \\
  -e GLOWCAP_ROOMS_STATE=/state \\
  {image}:{tag} --http-bind=0.0.0.0
```

Open http://127.0.0.1:8080. The web port is local to this machine. The directory
uses encrypted iroh discovery and can be reached by peers holding its locator.
For persistent supervised hosting and HTTPS, use the
[deployment guide]({tree}/apps/rooms/web/deploy/README.md).

The image's digest is `{image_digest}`. Its build provenance and its software
bill of materials ([SPDX]({base}/glowcap-rooms-{tag}.spdx.json)) are attested
in the registry:

```sh
gh attestation verify oci://{image}@{image_digest} --repo {slug}
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

The packages are uploaded by the
[publish workflow]({repository}/actions/workflows/publish.yml), which starts
when this page is published and waits for the maintainer's approval at each
registry, so a registry can lag this page by a few hours. The
[bindings guide]({tree}/bindings/README.md) lists every package. Zig users
depend on the [{tag} source]({repository}/tree/{tag}). The browser files in the
product are the Rooms application, not a published package.

# Source and license

Apache-2.0 alpha software. APIs, ABIs, and storage formats may change before 1.0.
Read the [project provenance]({tree}/PROVENANCE.md) and the `LICENSE-APACHE`
and `LICENSE-THIRD-PARTY` files included in each archive.
Source commit: `{facts['commit']}`. [Release run]({facts['run']}).

<!-- glowcap-release-run: {facts['run'].rsplit('/', 1)[1]} -->
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--changelog', metavar='VERSION', help="print this version's changelog section and stop")
    parser.add_argument('--facts', type=Path, help='artifacts/release.json from github_release.py assemble')
    parser.add_argument('--image-digest', help='the published Rooms image index digest')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.changelog:
        if args.facts or args.image_digest or args.output:
            parser.error('--changelog takes the version alone')
        print(changelog_section(args.changelog), end='')
        return
    if not (args.facts and args.image_digest and args.output):
        parser.error('--facts, --image-digest, and --output are required')
    args.output.write_text(render(json.loads(args.facts.read_text()), args.image_digest))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f'release-notes: {error}')
