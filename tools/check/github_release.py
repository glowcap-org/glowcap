"""release.yml's GitHub release: assemble its assets, resume its draft, prove publication.

The release job runs these modes in order, each from the checkout root with
gh, GH_TOKEN, GITHUB_REPOSITORY, and GITHUB_RUN_ID in the environment:

  assemble ARTIFACTS TAG  reads the run's archive artifacts, verifies each
                          packaged checksum file, copies the archives into
                          release-assets/ with one combined SHA256SUMS, and
                          writes artifacts/release.json, the facts the notes
                          render: version, tag, commit, run, and each
                          archive's target, role, and minimum runtime.
  bundles TAG             downloads the Sigstore bundles of every asset's
                          build provenance beside it as <asset>.sigstore.json,
                          one JSON line per attestation, so a reader can verify
                          offline and a registry scanner can see the signatures.
                          A re-run of the release job attests the checksum file
                          again, and gh verifies a file of several bundles.
  draft-state TAG         prints {"draft_exists", "missing_assets"} for this
                          run's draft. It refuses a published release, another
                          run's draft, and an uploaded asset whose digest
                          differs from release-assets/, so a re-run of a failed
                          job resumes exactly where it stopped.
  verify-draft TAG        requires the draft to hold every asset before it is
                          made public.
  published TAG           is publish.yml's contract: the signed annotated tag
                          names a commit that passed full validation on main,
                          and its public release holds every asset. Writes
                          version, tag, and commit to GITHUB_OUTPUT.

Every refusal exits 1 with a `github-release:` message and leaves prepared
files for inspection. ci/test/github_release_test.py drives each mode against
a stub gh.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

TARGETS = ('aarch64-macos', 'x86_64-macos', 'aarch64-linux', 'x86_64-linux')
ROLES = {'product': 'glowcap', 'sdk': 'glowcap-c'}
ENTRY_POINTS = {
    'sdk': ('include/glowcap_ocapn.h', 'lib/libglowcap_ocapn.a'),
    'product': ('bin/glowcap', 'libexec/rooms-server', 'libexec/rooms-session',
                'share/glowcap/rooms/page.html', 'share/glowcap/rooms/page.js',
                'share/glowcap/rooms/rooms_browser_bg.wasm',
                'share/glowcap/skills/rooms-peer/SKILL.md', 'share/glowcap/skills/rooms-team/SKILL.md'),
}
COMMON_FILES = ('README.md', 'PROVENANCE.md', 'LICENSE-APACHE', 'LICENSE-THIRD-PARTY')
PROVENANCE = 'https://slsa.dev/provenance/v1'
ASSETS = Path('release-assets')
FACTS = Path('artifacts/release.json')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(repository, endpoint, *, pages=False):
    command = ['gh', 'api', f'repos/{repository}/{endpoint}']
    if pages:
        command.extend(['--paginate', '--slurp'])
    return json.loads(subprocess.check_output(command, timeout=60))


def archive_name(tag, target, role):
    return f'{ROLES[role]}-{tag}-{target}.tar.gz'


def inventory(tag):
    """Every asset a public release holds: the archives, the checksums, and their bundles."""
    signed = [archive_name(tag, target, role) for target in TARGETS for role in ROLES] + ['SHA256SUMS']
    return sorted(signed + [f'{name}.sigstore.json' for name in signed] + [f'glowcap-rooms-{tag}.spdx.json'])


def digest_of(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def run_marker(run_id):
    return f'<!-- glowcap-release-run: {run_id} -->'


def archive_facts(path, tag, commit):
    """The archive's own release metadata, held to its filename and its entry points."""
    match = re.fullmatch(r'(glowcap(?:-c)?)-' + re.escape(tag) + r'-(.+)\.tar\.gz', path.name)
    require(match is not None and match[2] in TARGETS, f'unexpected release archive: {path.name}')
    role = next(role for role, prefix in ROLES.items() if prefix == match[1])
    with tarfile.open(path) as archive:
        metadata = archive.getmember('share/glowcap/release.json')
        require(metadata.isfile() and 0 < metadata.size <= 65536, f'invalid release metadata: {path.name}')
        value = json.load(archive.extractfile(metadata))
        runtime = 'macOS' if match[2].endswith('-macos') else 'glibc'
        require(value['version'] == tag[1:] and value['target'] == match[2] and value['revision'] == commit
                and value['dirty'] is False
                and re.fullmatch(runtime + r' [0-9]+\.[0-9]+\.[0-9]+', value['minimum_runtime']) is not None,
                f'archive metadata disagrees with its release: {path.name}')
        for name in (*COMMON_FILES, *ENTRY_POINTS[role]):
            member = archive.getmember(name)
            require(member.isfile() and member.size > 0, f'missing release entry point: {path.name}: {name}')
    return {'name': path.name, 'target': match[2], 'role': role, 'minimum_runtime': value['minimum_runtime']}


def assemble(repository, artifacts, tag, commit, run_id):
    """release-assets/ and artifacts/release.json from the run's verified archive artifacts."""
    ASSETS.mkdir(exist_ok=False)
    FACTS.parent.mkdir(exist_ok=True)
    facts = []
    for checksums in sorted(artifacts.glob('archives-*/*/SHA256SUMS')):
        for line in checksums.read_text().splitlines():
            digest, name = line.split()
            archive = checksums.with_name(name)
            require(archive.is_file() and digest_of(archive) == digest, f'packaged checksum mismatch: {archive}')
            facts.append(archive_facts(archive, tag, commit))
            shutil.copyfile(archive, ASSETS / name)
    require(sorted(fact['name'] for fact in facts) == sorted(archive_name(tag, target, role)
                                                             for target in TARGETS for role in ROLES),
            'the run did not produce exactly the eight release archives')
    for target in TARGETS:
        minimums = {fact['minimum_runtime'] for fact in facts if fact['target'] == target}
        require(len(minimums) == 1, f'product and SDK disagree on the minimum runtime: {target}')
    (ASSETS / 'SHA256SUMS').write_text(''.join(f'{digest_of(path)}  {path.name}\n' for path in sorted(ASSETS.glob('*.tar.gz'))))
    FACTS.write_text(json.dumps({
        'repository': f'https://github.com/{repository}', 'version': tag[1:], 'tag': tag, 'commit': commit,
        'run': f'https://github.com/{repository}/actions/runs/{run_id}', 'archives': sorted(facts, key=lambda fact: fact['name']),
    }, indent=2) + '\n')


def bundles(repository, tag):
    """One Sigstore bundle per signed asset, downloaded from the attestation store."""
    for asset in sorted(ASSETS.iterdir()):
        if asset.suffix == '.json' or asset.name == f'glowcap-rooms-{tag}.spdx.json':
            continue
        subprocess.run(['gh', 'attestation', 'download', asset.name, '--repo', repository,
                        '--predicate-type', PROVENANCE], check=True, timeout=120, cwd=ASSETS)
        downloaded = ASSETS / f'sha256:{digest_of(asset)}.jsonl'
        require(any(line.strip() for line in downloaded.read_text().splitlines()),
                f'no provenance attestation downloaded for {asset.name}')
        downloaded.rename(ASSETS / f'{asset.name}.sigstore.json')
    require(sorted(path.name for path in ASSETS.iterdir()) == inventory(tag), 'release-assets is not the complete asset set')


def release_for(repository, tag):
    # The tag lookup endpoint returns published releases only. Listing also
    # includes this contents:write caller's drafts.
    matches = [release for page in api(repository, 'releases?per_page=100', pages=True)
               for release in page if release['tag_name'] == tag]
    require(len(matches) <= 1, 'multiple releases use this tag')
    return matches[0] if matches else None


def draft_state(repository, tag, run_id, *, complete=False):
    release = release_for(repository, tag)
    require(not complete or release is not None, 'release draft is missing')
    if release:
        require(release['draft'] is True and run_marker(run_id) in (release['body'] or ''),
                "existing release is published or is another run's draft")
    expected = {path.name: 'sha256:' + digest_of(path) for path in ASSETS.iterdir() if path.is_file()}
    require(sorted(expected) == inventory(tag), 'release-assets is not the complete asset set')
    assets = release['assets'] if release else []
    require(len({asset['name'] for asset in assets}) == len(assets), 'duplicate release assets')
    for asset in assets:
        require(asset['state'] == 'uploaded' and asset['name'] in expected and asset.get('digest') == expected[asset['name']],
                f'existing draft asset differs: {asset["name"]}')
    missing = sorted(set(expected) - {asset['name'] for asset in assets})
    require(not complete or not missing, f'release draft is incomplete: {missing}')
    return {'draft_exists': release is not None, 'missing_assets': missing}


def signed_commit(repository, tag):
    ref = api(repository, f'git/ref/tags/{tag}')['object']
    require(ref['type'] == 'tag', 'publication requires an annotated signed tag')
    signed = api(repository, f'git/tags/{ref["sha"]}')
    require(signed['verification']['verified'] is True and signed['object']['type'] == 'commit',
            'tag signature is unverified or tag does not point directly to a commit')
    return signed['object']['sha']


def published(repository, tag):
    """The signed tag's commit passed full validation on main and its release is public and complete."""
    commit = signed_commit(repository, tag)
    subprocess.run([sys.executable, 'tools/check/require-main-check.py', commit], check=True, timeout=180)
    release = api(repository, f'releases/tags/{tag}')
    require(release['draft'] is False and release['tag_name'] == tag, 'release is a draft')
    uploaded = sorted(asset['name'] for asset in release['assets'] if asset['state'] == 'uploaded')
    require(uploaded == inventory(tag), 'public release does not hold exactly the release assets')
    return commit


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=('assemble', 'bundles', 'draft-state', 'verify-draft', 'published'))
    parser.add_argument('arguments', nargs='+', metavar='ARG')
    args = parser.parse_args()
    repository = os.environ.get('GITHUB_REPOSITORY', '')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) is not None, 'invalid GITHUB_REPOSITORY')
    tag = args.arguments[-1]
    require(re.fullmatch(r'v0\.[0-9]+\.[0-9]+', tag) is not None, f'invalid prerelease tag: {tag}')
    if args.mode == 'published':
        require(len(args.arguments) == 1, 'published takes the tag alone')
        commit = published(repository, tag)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f'version={tag[1:]}\ntag={tag}\ncommit={commit}\n')
        print(f'Verified the public release {tag} at {commit} on checked main')
        return
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    require(re.fullmatch(r'[1-9][0-9]*', run_id) is not None, 'invalid GITHUB_RUN_ID')
    if args.mode == 'assemble':
        require(len(args.arguments) == 2, 'assemble takes the artifacts directory and the tag')
        commit = os.environ.get('GITHUB_SHA', '')
        require(re.fullmatch(r'[0-9a-f]{40}', commit) is not None, 'invalid GITHUB_SHA')
        assemble(repository, Path(args.arguments[0]), tag, commit, run_id)
        print(f'Assembled {len(list(ASSETS.glob("*.tar.gz")))} archives for {tag} at {commit}')
        return
    require(len(args.arguments) == 1, f'{args.mode} takes the tag alone')
    if args.mode == 'bundles':
        bundles(repository, tag)
        print(f'Downloaded the provenance bundle of every signed asset for {tag}')
    elif args.mode == 'draft-state':
        print(json.dumps(draft_state(repository, tag, run_id)))
    else:
        draft_state(repository, tag, run_id, complete=True)
        print('Complete release draft matches every prepared asset')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        sys.exit(f'github-release: {error}')
