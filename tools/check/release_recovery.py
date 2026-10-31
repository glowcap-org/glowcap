"""release.yml's read-only artifact verifier and publication preparation.

RUN TAG checks the signed tag, original producer jobs, and artifact metadata.
--prepare also downloads digest-checked ZIPs into a fresh artifacts directory,
checks their exact inventory and packaged checksums, and assembles release-assets.
Run from the checkout root with gh, GH_TOKEN and GITHUB_REPOSITORY. Outputs go
to GITHUB_OUTPUT when supplied. --verify-draft checks the staged release against
release-assets before release.yml makes it public. --published TAG is
publish.yml's contract: the signed tag's commit is on checked main and its
GitHub release is public with every archive. No builds or publication.
Errors stop the caller, preserving prepared files for inspection.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import zipfile


HOSTS = {
    'ubuntu-24.04': ('x86_64-linux', 'x86_64-linux-gnu.2.39'),
    'ubuntu-24.04-arm': ('aarch64-linux', 'aarch64-linux-gnu.2.39'),
    'macos-15': ('aarch64-macos', 'aarch64-macos.15.0'),
    'macos-15-intel': ('x86_64-macos', 'x86_64-macos.15.0'),
}
IMAGE_JOBS = {'images (ubuntu-24.04, x86_64, amd64)',
              'images (ubuntu-24.04-arm, aarch64, arm64)'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(repository, endpoint, *, pages=False):
    command = ['gh', 'api', f'repos/{repository}/{endpoint}']
    if pages:
        command.extend(['--paginate', '--slurp'])
    return json.loads(subprocess.check_output(command, timeout=60))


def inventory(tag):
    result = {}
    for runner, (target, _) in HOSTS.items():
        result[f'archives-{runner}'] = {
            f'{directory}/{prefix}-{tag}-{target}.tar.gz': f'{directory}/SHA256SUMS'
            for directory, prefix in [('release', 'glowcap-c'), ('glowcap-release', 'glowcap')]
        }
    for arch in ('amd64', 'arm64'):
        result[f'rooms-image-{arch}'] = {f'glowcap-rooms-{tag}-{arch}.docker.tar': 'SHA256SUMS'}
    return result


def signed_commit(repository, tag):
    ref = api(repository, f'git/ref/tags/{tag}')['object']
    require(ref['type'] == 'tag', 'publication requires an annotated signed tag')
    signed = api(repository, f'git/tags/{ref["sha"]}')
    require(signed['verification']['verified'] is True and signed['object']['type'] == 'commit',
            'tag signature is unverified or tag does not point directly to a commit')
    return signed['object']['sha']


def published_release(repository, tag):
    """The public release at TAG, holding every archive and the checksum file."""
    release = api(repository, f'releases/tags/{tag}')
    require(release['draft'] is False and release['tag_name'] == tag, 'release is a draft')
    names = {Path(name).name for group in inventory(tag).values() for name in group if name.endswith('.tar.gz')}
    assets = [asset for asset in release['assets'] if asset['state'] == 'uploaded']
    require(sorted(asset['name'] for asset in assets) == sorted(names | {'SHA256SUMS'}),
            'public release does not hold exactly the archives and SHA256SUMS')
    return release


def validate_source(repository, run_id, tag, *, current=False):
    commit = signed_commit(repository, tag)
    run = api(repository, f'actions/runs/{run_id}')
    require(run['event'] == 'push' and run['head_branch'] == tag
            and run['head_sha'] == commit and run['path'] == '.github/workflows/release.yml'
            and run['head_repository']['full_name'] == repository,
            'source must be this repository\'s release tag push run at the signed commit')
    active = (current and str(run_id) == os.environ.get('GITHUB_RUN_ID')
              and os.environ.get('GITHUB_EVENT_NAME') == 'push'
              and os.environ.get('GITHUB_REF') == f'refs/tags/{tag}'
              and os.environ.get('GITHUB_SHA') == commit)
    require((run['status'] == 'completed' and run['conclusion'] in ('success', 'failure'))
            or (active and run['status'] == 'in_progress'), 'source run is not ready for publication')
    jobs = [job for page in api(repository,
            f'actions/runs/{run_id}/jobs?filter=latest&per_page=100', pages=True) for job in page['jobs']]
    required = {'contract', *IMAGE_JOBS,
                *(f'archives ({runner}, {target})' for runner, (_, target) in HOSTS.items())}
    for name in required:
        matches = [job for job in jobs if job['name'] == name]
        require(len(matches) == 1 and matches[0]['conclusion'] == 'success'
                and matches[0]['status'] == 'completed', f'producer did not pass: {name}')
    artifacts = [artifact for page in api(repository,
                 f'actions/runs/{run_id}/artifacts?per_page=100', pages=True) for artifact in page['artifacts']]
    require(sorted(item['name'] for item in artifacts) == sorted(inventory(tag)),
            'source run must contain exactly the six release artifacts')
    for artifact in artifacts:
        require(not artifact['expired'] and artifact['workflow_run']['head_sha'] == commit
                and artifact['workflow_run']['id'] == int(run_id)
                and re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest') or '')
                and 0 < artifact['size_in_bytes'] <= 2 * 1024**3,
                f'invalid or expired artifact: {artifact["name"]}')
    return commit, artifacts


def unpack(archive, directory, expected):
    """Extract only the declared regular files, then verify the inner checksums."""
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        require(sorted(entry.filename for entry in entries) == sorted(set(expected) | set(expected.values())),
                'artifact ZIP has unexpected, missing, or duplicate entries')
        for entry in entries:
            mode = entry.external_attr >> 16
            require(not entry.is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG)
                    and 0 < entry.file_size <= 2 * 1024**3, 'artifact ZIP entry is not a bounded regular file')
            target = directory / entry.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as incoming, target.open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)
    for name, checksum in expected.items():
        with (directory / name).open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        require((directory / checksum).read_text().split() == [digest, Path(name).name],
                f'packaged checksum mismatch: {name}')


def provenance(repository, run_id, tag, commit, artifacts):
    return {
        'source': {
            'repository': f'https://github.com/{repository}',
            'tag': tag,
            'commit': commit,
            'run': f'https://github.com/{repository}/actions/runs/{run_id}',
        },
        'artifacts': [{'name': item['name'], 'id': item['id'], 'digest': item['digest']}
                      for item in artifacts],
        'publication': {
            'workflow': os.environ.get('GITHUB_WORKFLOW_REF', ''),
            'commit': os.environ.get('GITHUB_SHA', ''),
            'run': f'https://github.com/{repository}/actions/runs/{os.environ.get("GITHUB_RUN_ID", run_id)}',
        },
    }


def prepare(repository, run_id, tag, commit, artifacts):
    root = Path('artifacts')
    root.mkdir(exist_ok=False)
    release = Path('release-assets')
    release.mkdir(exist_ok=False)
    expected = inventory(tag)
    for artifact in artifacts:
        archive = root / f'{artifact["name"]}.zip'
        with archive.open('xb') as output:
            subprocess.run(['gh', 'api', f'repos/{repository}/actions/artifacts/{artifact["id"]}/zip'],
                           stdout=output, check=True, timeout=600)
        with archive.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        require(f'sha256:{digest}' == artifact['digest'], f'GitHub artifact digest mismatch: {archive}')
        directory = root / artifact['name']
        unpack(archive, directory, expected[artifact['name']])
        archive.unlink()
        for name in expected[artifact['name']]:
            if name.endswith('.tar.gz'):
                shutil.copyfile(directory / name, release / Path(name).name)
    lines = []
    for archive in sorted(release.glob('*.tar.gz')):
        with archive.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        lines.append(f'{digest}  {archive.name}\n')
    (release / 'SHA256SUMS').write_text(''.join(lines))
    (root / 'publication-provenance.json').write_text(json.dumps(
        provenance(repository, run_id, tag, commit, artifacts), indent=2) + '\n')


def release_state(repository, run_id, tag, *, complete=False):
    """Refuse replacement, or resume only this source run's matching draft."""
    # The tag lookup endpoint returns published releases only. Listing also
    # includes drafts for this contents:write caller, including retry state.
    matches = [release for page in api(repository, 'releases?per_page=100', pages=True)
               for release in page if release['tag_name'] == tag]
    require(len(matches) <= 1, 'multiple releases use this tag')
    release = matches[0] if matches else None
    require(not complete or release is not None, 'release draft is missing')
    if release:
        require(release['draft'] is True
                and f'<!-- glowcap-source-run: {run_id} -->' in (release['body'] or ''),
                "existing release is published or is not this source run's draft")
    expected = {}
    for path in Path('release-assets').iterdir():
        require(path.is_file(), 'unexpected release asset directory')
        with path.open('rb') as source:
            expected[path.name] = 'sha256:' + hashlib.file_digest(source, 'sha256').hexdigest()
    names = {Path(name).name for group in inventory(tag).values() for name in group if name.endswith('.tar.gz')}
    require(set(expected) == names | {'SHA256SUMS'}, 'prepared release assets are incomplete')
    assets = release['assets'] if release else []
    require(len({asset['name'] for asset in assets}) == len(assets), 'duplicate release assets')
    for asset in assets:
        require(asset['state'] == 'uploaded' and asset['name'] in expected
                and asset.get('digest') == expected[asset['name']],
                f'existing draft asset differs: {asset["name"]}')
    missing = sorted(set(expected) - {asset['name'] for asset in assets})
    require(not complete or not missing, f'release draft is incomplete: {missing}')
    return {'draft_exists': release is not None, 'missing_assets': missing}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', nargs='?')
    parser.add_argument('tag')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--prepare', action='store_true')
    modes.add_argument('--verify-draft', action='store_true')
    modes.add_argument('--published', action='store_true', help='TAG only: verify the public release')
    parser.add_argument('--current', action='store_true')
    args = parser.parse_args()
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository), 'invalid repository')
    require(re.fullmatch(r'v0\.[0-9]+\.[0-9]+', args.tag), 'invalid prerelease tag')
    if args.published:
        require(args.run is None, '--published takes the tag alone')
        commit = signed_commit(repository, args.tag)
        subprocess.run([sys.executable, 'tools/check/require-main-check.py', commit], check=True, timeout=180)
        published_release(repository, args.tag)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f'version={args.tag[1:]}\ntag={args.tag}\ncommit={commit}\n')
        print(f'Verified the public release {args.tag} at {commit} on checked main')
        return
    require(args.run is not None and re.fullmatch(r'[1-9][0-9]*', args.run), 'invalid source run ID')
    if args.verify_draft:
        release_state(repository, args.run, args.tag, complete=True)
        print('Complete release draft matches every prepared asset')
        return
    commit, artifacts = validate_source(repository, args.run, args.tag, current=args.current)
    subprocess.run([sys.executable, 'tools/check/require-main-check.py', commit], check=True, timeout=180)
    if args.prepare:
        prepare(repository, args.run, args.tag, commit, artifacts)
        state = release_state(repository, args.run, args.tag)
        Path('artifacts/release-state.json').write_text(json.dumps(state) + '\n')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'version={args.tag[1:]}\ntag={args.tag}\nsource_run={args.run}\n')
    print(f'Verified {args.tag} at {commit}: {len(artifacts)} tested artifacts from run {args.run}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        sys.exit(f'release-recovery: {error}')
