"""ci/release_image.py builds, exercises, and publishes the versioned Rooms image.

The build and exercise verbs run against a recording docker, git, and checksum
command, which hold each command to the arguments the release image needs. The
publisher runs against a fake docker that answers as a registry in each
state: nothing published, everything published, one platform published, a
platform or the index holding another image, a platform missing, and the
network refusing. It never reaches a registry.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from workflows import ROOT, jobs, run, stub

REPOSITORY = "owner/project"
TAG = "v0.1.0"


class ReleaseImage(unittest.TestCase):
    def test_image_publication_reuses_matching_tags_and_refuses_conflicts(self):
        release = jobs(".github/workflows/release.yml")["release"]
        script = run(release, "Publish the versioned multi-platform Rooms image")
        self.assertEqual(script, "python3 ci/release_image.py publish artifacts")
        docker = r"""#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open('calls', 'a') as output:
    output.write(json.dumps(args) + '\n')
mode = os.environ['IMAGE_MODE']
def manifest(arch):
    return json.dumps({'config': {'digest': 'sha256:expected'}, 'arch': arch})
def index():
    return json.dumps({'manifests': [
        {'platform': {'os': 'linux', 'architecture': arch},
         'digest': 'sha256:' + hashlib.sha256((manifest(arch) + '\n').encode()).hexdigest()}
        for arch in (('arm64',) if mode == 'missing-platform' else ('amd64', 'arm64'))]})
if args[0] == 'login':
    sys.stdin.read()
elif args[:2] == ['image', 'inspect']:
    print('sha256:expected')
elif args[:2] == ['image', 'push']:
    Path(args[-1].split('-')[-1] + '.pushed').touch()
elif args[:3] == ['buildx', 'imagetools', 'create']:
    Path('index.pushed').touch()
elif args[:3] == ['buildx', 'imagetools', 'inspect']:
    arch = args[-1].split('-')[-1]
    arch = arch if arch in ('amd64', 'arm64') else 'index'
    if mode == 'network':
        sys.exit('connection refused')
    if (mode == 'new' or (mode == 'partial' and arch != 'amd64')) and not Path(arch + '.pushed').exists():
        sys.exit('manifest unknown')
    if mode == 'conflict' and arch == 'arm64':
        print(json.dumps({'config': {'digest': 'sha256:other'}}))
    elif arch == 'index':
        print(index().replace('sha256:', 'sha256:other') if mode == 'index-conflict' else index())
    else:
        print(manifest(arch))
"""
        # The publisher runs on Linux. Supply its checksum command on macOS too.
        checksum = """#!/usr/bin/env python3
import hashlib, sys
from pathlib import Path
if sys.argv[1:]:
    for line in Path(sys.argv[2]).read_text().splitlines():
        digest, name = line.split()
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            sys.exit(1)
else:
    print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
"""
        for mode in ("new", "existing", "partial", "conflict", "index-conflict", "missing-platform", "network"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                stub(directory, "docker", docker)
                stub(directory, "sha256sum", checksum)
                for arch in ("amd64", "arm64"):
                    image = directory / f"artifacts/rooms-image-{arch}"
                    image.mkdir(parents=True)
                    name = f"glowcap-rooms-{TAG}-{arch}.docker.tar"
                    (image / name).write_bytes(b"image")
                    (image / "SHA256SUMS").write_text(f"{hashlib.sha256(b'image').hexdigest()}  {name}\n")
                result = subprocess.run(
                    [sys.executable, str(ROOT / "ci/release_image.py"), "publish", "artifacts"],
                    cwd=directory,
                    env=dict(
                        os.environ,
                        PATH=str(directory) + os.pathsep + os.environ["PATH"],
                        GH_TOKEN="test",
                        IMAGE="ghcr.io/owner/rooms",
                        VERSION="0.1.0",
                        GITHUB_ACTOR="actor",
                        GITHUB_REPOSITORY=REPOSITORY,
                        GITHUB_SHA="a" * 40,
                        IMAGE_MODE=mode,
                        GITHUB_OUTPUT=str(directory / "output"),
                    ),
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(result.returncode == 0, mode in ("new", "existing", "partial"), result.stderr)
                if result.returncode == 0:
                    # The attestation subject is the digest of the index the registry serves.
                    self.assertRegex((directory / "output").read_text(), r"^digest=sha256:[0-9a-f]{64}\n$")
                calls = [json.loads(line) for line in (directory / "calls").read_text().splitlines()]
                effects = [
                    call
                    for call in calls
                    if call[:2] == ["image", "push"] or call[:3] == ["buildx", "imagetools", "create"]
                ]
                self.assertEqual(len(effects), {"new": 3, "partial": 2}.get(mode, 0), calls)


class ImageBuild(unittest.TestCase):
    RECORDER = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:], os.environ.get('SOURCE_DATE_EPOCH')]) + '\\n')
if name == 'git':
    print('1700000000')
elif name == 'sha256sum':
    print('0' * 64 + '  ' + sys.argv[1])
elif sys.argv[1:3] == ['image', 'save']:
    Path(sys.argv[4]).write_bytes(b'image')
sys.exit(int(os.environ.get('FAIL_' + name.upper(), '0')))
"""

    def verb(self, verb, **env):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name in ("docker", "git", "sha256sum"):
                stub(directory, name, self.RECORDER)
            (directory / "tools/check").mkdir(parents=True)
            (directory / "tools/check/glowcap_release_image.py").write_text(self.RECORDER)
            result = subprocess.run(
                [sys.executable, str(ROOT / "ci/release_image.py"), verb],
                cwd=directory,
                env={
                    **{key: value for key, value in os.environ.items() if key != "SOURCE_DATE_EPOCH"},
                    "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                    "CALLS": str(directory / "calls"),
                    "IMAGE": "ghcr.io/owner/rooms",
                    "VERSION": "0.1.0",
                    "IMAGE_ARCH": "arm64",
                    "GITHUB_REPOSITORY": REPOSITORY,
                    "GITHUB_SHA": "a" * 40,
                    **env,
                },
                capture_output=True,
                text=True,
                timeout=20,
            )
            calls = (directory / "calls").read_text().splitlines() if (directory / "calls").exists() else []
            sums = directory / "image-artifact/SHA256SUMS"
            return result, [json.loads(line) for line in calls], sums.read_text() if sums.exists() else None

    def test_the_build_steps_call_the_verbs(self):
        images = jobs(".github/workflows/release.yml")["images"]
        for name, verb in (
            ("Build the exact Docker image artifact", "build"),
            ("Load and exercise the exact image artifact", "exercise"),
        ):
            self.assertEqual(run(images, name), f"python3 ci/release_image.py {verb}")

    def test_build_makes_the_exact_image_at_the_commit_time_and_records_its_checksum(self):
        result, calls, sums = self.verb("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        tag = f"ghcr.io/owner/rooms:{TAG}-arm64"
        self.assertEqual(
            calls,
            [
                ["git", "show", "-s", "--format=%ct", "a" * 40, None],
                [
                    "docker",
                    "buildx",
                    "build",
                    "--platform",
                    "linux/arm64",
                    "--build-arg",
                    "SOURCE_DATE_EPOCH",
                    "--file",
                    "image-context/share/glowcap/deployment/rooms.Dockerfile",
                    "--label",
                    f"org.opencontainers.image.source=https://github.com/{REPOSITORY}",
                    "--label",
                    "org.opencontainers.image.revision=" + "a" * 40,
                    "--label",
                    f"org.opencontainers.image.version={TAG}",
                    "--tag",
                    tag,
                    "--load",
                    "image-context",
                    "1700000000",
                ],
                [
                    "docker",
                    "image",
                    "save",
                    "--output",
                    f"image-artifact/glowcap-rooms-{TAG}-arm64.docker.tar",
                    tag,
                    None,
                ],
                ["sha256sum", f"glowcap-rooms-{TAG}-arm64.docker.tar", None],
            ],
        )
        self.assertEqual(sums, "0" * 64 + f"  glowcap-rooms-{TAG}-arm64.docker.tar\n")

    def test_exercise_loads_the_saved_image_and_checks_it(self):
        result, calls, _ = self.verb("exercise")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls,
            [
                ["docker", "image", "load", "--input", f"image-artifact/glowcap-rooms-{TAG}-arm64.docker.tar", None],
                ["glowcap_release_image.py", f"ghcr.io/owner/rooms:{TAG}-arm64", "arm64", None],
            ],
        )

    def test_a_failed_command_or_missing_environment_is_refused(self):
        result, calls, sums = self.verb("build", FAIL_DOCKER="3")
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("release-image: docker buildx build"), result.stderr)
        self.assertIsNone(sums)
        result, calls, _ = self.verb("build", IMAGE="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing environment: IMAGE", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
