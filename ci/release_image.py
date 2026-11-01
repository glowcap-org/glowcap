#!/usr/bin/env python3
"""Publish the versioned Rooms image for both platforms and its index.

Caller: release.yml's release job, from the checkout root, after the run's
artifacts are downloaded. Takes the artifacts directory. Reads GH_TOKEN,
GITHUB_ACTOR, IMAGE, VERSION, GITHUB_REPOSITORY, and GITHUB_SHA, and appends
`digest=sha256:...`, the attestation subject, to GITHUB_OUTPUT.

Each platform's exact image artifact is checked against its SHA256SUMS,
loaded, and pushed as IMAGE:vVERSION-ARCH, then the index IMAGE:vVERSION is
created over the two pushed digests. A re-run finds the tags it pushed before
and requires the same images, so a conflicting tag fails and nothing is
replaced. Any other registry error fails. ci/github_release_test.py
drives this against a stub docker.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

PLATFORMS = ('amd64', 'arm64')
ABSENT = ('manifest unknown', ': not found')


def fail(message):
    print(f'release-image: {message}', file=sys.stderr)
    sys.exit(1)


def docker(*arguments, stdin=None):
    return subprocess.run(['docker', *arguments], input=stdin, capture_output=True, check=True).stdout


def remote(reference):
    """The raw manifest the registry serves for a reference, or None when it has none."""
    lookup = subprocess.run(['docker', 'buildx', 'imagetools', 'inspect', '--raw', reference], capture_output=True)
    if lookup.returncode == 0:
        return lookup.stdout
    error = lookup.stderr.decode(errors='replace')
    if not any(marker in error for marker in ABSENT):
        fail(f'{reference}: {error.strip()}')
    return None


def verified_archive(artifacts, version, arch):
    name = f'glowcap-rooms-v{version}-{arch}.docker.tar'
    found = sorted((artifacts / f'rooms-image-{arch}').rglob(name))
    if not found:
        fail(f'missing Rooms image artifact for {arch}')
    archive = found[0]
    sums = dict(line.split()[::-1] for line in (archive.parent / 'SHA256SUMS').read_text().splitlines() if line.strip())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sums.get(name):
        fail(f'{archive} does not match its SHA256SUMS')
    return archive


def publish(artifacts, env):
    image, version = env['IMAGE'], env['VERSION']
    docker('login', 'ghcr.io', '--username', env['GITHUB_ACTOR'], '--password-stdin', stdin=env['GH_TOKEN'].encode())
    sources = []
    for arch in PLATFORMS:
        tag = f'{image}:v{version}-{arch}'
        docker('image', 'load', '--input', str(verified_archive(artifacts, version, arch)))
        expected = docker('image', 'inspect', '--format', '{{.Id}}', tag).decode().strip()
        manifest = remote(tag)
        if manifest is None:
            docker('image', 'push', tag)
        elif json.loads(manifest)['config']['digest'] != expected:
            fail(f'{tag} is already published from a different image')
        sources.append(f'{image}@sha256:{hashlib.sha256(remote(tag)).hexdigest()}')
    index = remote(f'{image}:v{version}')
    if index is None:
        annotations = {
            'title': 'glowcap Rooms',
            'description': 'The glowcap Rooms chat directory and web app',
            'source': f'https://github.com/{env["GITHUB_REPOSITORY"]}',
            'revision': env['GITHUB_SHA'],
            'version': f'v{version}',
            'licenses': 'Apache-2.0',
        }
        flags = [f'--annotation=index:org.opencontainers.image.{key}={value}' for key, value in annotations.items()]
        docker('buildx', 'imagetools', 'create', '--tag', f'{image}:v{version}', *flags, *sources)
        index = remote(f'{image}:v{version}')
    manifests = [entry for entry in json.loads(index)['manifests'] if entry['platform']['architecture'] != 'unknown']
    if sorted(entry['digest'] for entry in manifests) != sorted(source.split('@')[1] for source in sources):
        fail(f'{image}:v{version} is already published over different images')
    platforms = sorted(f'{entry["platform"]["os"]}/{entry["platform"]["architecture"]}' for entry in manifests)
    if platforms != [f'linux/{arch}' for arch in PLATFORMS]:
        fail(f'{image}:v{version} serves {platforms}')
    with open(env['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'digest=sha256:{hashlib.sha256(index).hexdigest()}\n')


def main():
    if len(sys.argv) != 2:
        print('usage: release-image.py ARTIFACTS', file=sys.stderr)
        return 2
    env = {name: os.environ.get(name, '') for name in
           ('GH_TOKEN', 'GITHUB_ACTOR', 'IMAGE', 'VERSION', 'GITHUB_REPOSITORY', 'GITHUB_SHA', 'GITHUB_OUTPUT')}
    missing = [name for name, value in env.items() if not value]
    if missing:
        fail(f'missing environment: {", ".join(missing)}')
    try:
        publish(Path(sys.argv[1]), env)
    except subprocess.CalledProcessError as error:
        fail(f'{" ".join(error.cmd)} exited {error.returncode}: {error.stderr.decode(errors="replace").strip()}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
