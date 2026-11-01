"""ci/release_image.py publishes the versioned Rooms image from the release artifacts.

The publisher runs against a fake docker that answers as a registry in each
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

from workflows import ROOT, shell_step, stub

REPOSITORY = "owner/project"
TAG = "v0.1.0"


class ReleaseImage(unittest.TestCase):
    def test_image_publication_reuses_matching_tags_and_refuses_conflicts(self):
        script = shell_step(
            (ROOT / ".github/workflows/release.yml").read_text(), "Publish the versioned multi-platform Rooms image"
        )
        self.assertEqual(script, "python3 ci/release_image.py artifacts")
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
                    [sys.executable, str(ROOT / "ci/release_image.py"), "artifacts"],
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


if __name__ == "__main__":
    unittest.main()
