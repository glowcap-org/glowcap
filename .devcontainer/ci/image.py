"""Prepare one CI toolchain image, or start a consumer without a toolchain build.

Called by the CI workflows at the checkout root. Requires
Docker and the pinned Dev Containers CLI. Registry writes require --publish;
read-only misses use a run-scoped Docker archive in RUNNER_TEMP. Outputs go to
GITHUB_OUTPUT. Subprocess failures stop the job; workflow timeouts bound builds.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def fingerprint():
    # Conservative input set: includes new tracked installers and configuration,
    # excludes generated host state. Content, names, modes and architecture count.
    paths = run('git', 'ls-files', '-s', '-z', '--', '.devcontainer',
                '.dockerignore', 'apps/rooms/rust/Cargo.lock', capture=True)
    digest = hashlib.sha256(b'glowcap-ci-image-v1\0linux/amd64\0')
    for entry in paths.split('\0'):
        if not entry:
            continue
        metadata, name = entry.split('\t', 1)
        digest.update(metadata.split()[0].encode() + b'\0' + name.encode() + b'\0')
        digest.update((ROOT / name).read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for name, value in values.items():
            stream.write(f'{name}={value}\n')


def reference():
    repository = os.environ['GITHUB_REPOSITORY'].lower()
    if not re.fullmatch(r'[a-z0-9_.-]+/[a-z0-9_.-]+', repository):
        raise ValueError('invalid GITHUB_REPOSITORY')
    return f'ghcr.io/{repository}/devcontainer'


def resolve(tag, *, readonly):
    result = subprocess.run(['docker', 'buildx', 'imagetools', 'inspect', tag,
                             '--format', '{{.Manifest.Digest}}'], cwd=ROOT,
                            capture_output=True, text=True, timeout=120)
    if result.returncode:
        detail = result.stderr.lower()
        missing = 'not found' in detail or 'manifest unknown' in detail
        inaccessible = readonly and ('unauthorized' in detail or 'denied' in detail or '403' in detail)
        if not (missing or inaccessible):
            raise RuntimeError(f'image lookup failed: {result.stderr}')
        print('No accessible matching image. Preparing it once for this run.', flush=True)
        return None
    digest = result.stdout.strip()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError(f'invalid image digest: {digest!r}')
    return tag.split(':')[0] + '@' + digest


def prepare(publish):
    if publish and (os.environ.get('GITHUB_EVENT_NAME') == 'pull_request' or
                    os.environ.get('GITHUB_REF') not in ('refs/heads/main', 'refs/heads/dev')):
        raise ValueError('only trusted main/dev runs may publish images')
    tag = reference() + ':inputs-' + fingerprint()
    image = resolve(tag, readonly=not publish)
    if image:
        print(f'Reusing {image}', flush=True)
        output(image=image, archive='false')
        return
    run('bash', '.devcontainer/bin/configure.sh')
    run('devcontainer', 'build', '--workspace-folder', '.', '--frozen-lockfile', '--image-name', tag,
        '--cache-from', reference() + ':ci')
    if publish:
        # The keyed tag commits successful preparation. Publish the shared
        # cache alias first so a failed alias push cannot be hidden by a warm
        # retry. Cold builds use that alias as their layer cache.
        run('docker', 'tag', tag, reference() + ':ci')
        run('docker', 'push', reference() + ':ci')
        run('docker', 'push', tag)
        image = resolve(tag, readonly=False)
        if image is None:
            raise RuntimeError('published image is unavailable')
        output(image=image, archive='false')
    else:
        image = run('docker', 'image', 'inspect', tag, '--format', '{{.Id}}', capture=True).strip()
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
            raise ValueError('invalid local image ID')
        run('docker', 'save', '-o', str(Path(os.environ['RUNNER_TEMP']) / 'devcontainer.tar'), tag)
        output(image=image, archive='true')


def consumer_config(config, compose, image, compose_path):
    config = dict(config)
    config.pop('features', None)  # Already installed in the prepared image.
    # The prebuild stores this hook in image metadata. Repeating it in the
    # consumer config makes the CLI execute both copies.
    config.pop('postCreateCommand', None)
    config.pop('configFilePath', None)
    config['dockerComposeFile'] = str(compose_path)
    for service in compose['services'].values():
        service.pop('build', None)
    service = compose['services'][config['service']]
    service['image'] = image
    # Keep Compose's declared environment intact. The checkout verifier rejects
    # per-command overrides, so mount each runner-cached store at its declared
    # path: the package downloads, Zig's compile objects, and Cargo's
    # intermediate build state.
    work = service['environment']['ZIG_LOCAL_CACHE_DIR'].rsplit('/', 1)[0]
    for name, target in ci_stores(work, service['environment']).items():
        service.setdefault('volumes', []).append({
            'type': 'bind', 'source': str(CI_CACHE / name), 'target': target,
        })
    return config, compose


# Runner-side stores the checks workflow restores between runs.
CI_CACHE = Path.home() / '.cache/glowcap/ci'


def ci_stores(work, environment):
    return {
        'zig-pkg': environment['ZIG_LOCAL_PKG_DIR'],
        'zig-local': environment['ZIG_LOCAL_CACHE_DIR'],
        'cargo-build': work + '/cargo',
    }


def start(image):
    if not re.fullmatch(r'(ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+/devcontainer@)?sha256:[0-9a-f]{64}', image):
        raise ValueError('consumer requires an immutable image reference')
    if image.startswith('ghcr.io/'):
        run('docker', 'pull', image)
    else:
        archive = Path(os.environ['RUNNER_TEMP']) / 'devcontainer.tar'
        run('docker', 'load', '-i', str(archive))
        archive.unlink()
        run('docker', 'image', 'inspect', image)
        # Dockerfile FROM needs a name, even for the CLI's small UID adjustment.
        # Bind that local name to the verified archive ID before creating it.
        local_name = 'glowcap-ci:' + image.removeprefix('sha256:')
        run('docker', 'tag', image, local_name)
        image = local_name
    run('bash', '.devcontainer/hooks/initialize.sh')
    config = json.loads(run('devcontainer', 'read-configuration', '--workspace-folder', '.', capture=True))['configuration']
    compose = json.loads(run('docker', 'compose', '-f', '.devcontainer/docker-compose.yml',
                             'config', '--format', 'json', capture=True))
    for name in ('zig-pkg', 'zig-local', 'cargo-build'):
        (CI_CACHE / name).mkdir(parents=True, exist_ok=True)
    directory = ROOT / '.devcontainer/.ci'
    directory.mkdir(exist_ok=True)
    config, compose = consumer_config(config, compose, image, directory / 'compose.json')
    (directory / 'compose.json').write_text(json.dumps(compose))
    (directory / 'devcontainer.json').write_text(json.dumps(config))
    run('devcontainer', 'up', '--workspace-folder', '.', '--config', '.devcontainer/.ci/devcontainer.json')
    run('devcontainer', 'exec', '--workspace-folder', '.', '--config', '.devcontainer/.ci/devcontainer.json',
        'bash', '-c', "git config --local user.name 'github-actions[bot]'; "
        "git config --local user.email '41898282+github-actions[bot]@users.noreply.github.com'")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare').add_argument('--publish', action='store_true')
    commands.add_parser('start').add_argument('image')
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.publish)
    else:
        start(args.image)


if __name__ == '__main__':
    main()
