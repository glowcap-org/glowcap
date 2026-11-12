#!/usr/bin/env python3
"""Build, exercise, and publish the versioned Rooms image.

Callers: release.yml, from the checkout root, one verb per step.

  context              images job: finds this platform's Linux product archive
                       under archive-artifact/, checks it against its
                       SHA256SUMS, and extracts it into image-context/.
                       Reads VERSION and ARCHIVE_ARCH.
  build                images job: builds the exact single-platform image from
                       image-context/ with the commit time as
                       SOURCE_DATE_EPOCH, saves it under image-artifact/, and
                       writes its SHA256SUMS. Reads VERSION, IMAGE, IMAGE_ARCH,
                       GITHUB_REPOSITORY, and GITHUB_SHA.
  exercise             images job: loads the saved image and runs
                       tools/check/glowcap_release_image.py against it. Reads
                       VERSION, IMAGE, and IMAGE_ARCH.
  publish ARTIFACTS    release job, after the run's artifacts are downloaded.
                       Reads GH_TOKEN, GITHUB_ACTOR, IMAGE, VERSION,
                       GITHUB_REPOSITORY, and GITHUB_SHA, and appends
                       `digest=sha256:...`, the attestation subject, to
                       GITHUB_OUTPUT.

Publication checks each platform's exact image artifact against its
SHA256SUMS, loads it, and pushes it as IMAGE:vVERSION-ARCH, then creates the
index IMAGE:vVERSION over the two pushed digests. A re-run finds the tags it
pushed before and requires the same images, so a conflicting tag fails and
nothing is replaced. Any other registry error fails, and every refusal exits 1
with a `release-image:` message. ci/release_image_test.py drives each verb
against a stub docker.
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

PLATFORMS = ("amd64", "arm64")
ABSENT = ("manifest unknown", ": not found")


def fail(message):
    print(f"release-image: {message}", file=sys.stderr)
    sys.exit(1)


def docker(*arguments, stdin=None):
    return subprocess.run(["docker", *arguments], input=stdin, capture_output=True, check=True, timeout=600).stdout


def shown(*command, timeout, **options):
    """Run a command whose output belongs in the job log."""
    subprocess.run(command, check=True, timeout=timeout, **options)


def remote(reference):
    """The raw manifest the registry serves for a reference, or None when it has none."""
    lookup = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--raw", reference], capture_output=True, timeout=120
    )
    if lookup.returncode == 0:
        return lookup.stdout
    error = lookup.stderr.decode(errors="replace")
    if not any(marker in error for marker in ABSENT):
        fail(f"{reference}: {error.strip()}")
    return None


def verified_archive(artifacts, version, arch):
    name = f"glowcap-rooms-v{version}-{arch}.docker.tar"
    found = sorted((artifacts / f"rooms-image-{arch}").rglob(name))
    if not found:
        fail(f"missing Rooms image artifact for {arch}")
    archive = found[0]
    sums = dict(line.split()[::-1] for line in (archive.parent / "SHA256SUMS").read_text().splitlines() if line.strip())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sums.get(name):
        fail(f"{archive} does not match its SHA256SUMS")
    return archive


def publish(artifacts, env):
    image, version = env["IMAGE"], env["VERSION"]
    docker("login", "ghcr.io", "--username", env["GITHUB_ACTOR"], "--password-stdin", stdin=env["GH_TOKEN"].encode())
    sources = []
    for arch in PLATFORMS:
        tag = f"{image}:v{version}-{arch}"
        docker("image", "load", "--input", str(verified_archive(artifacts, version, arch)))
        expected = docker("image", "inspect", "--format", "{{.Id}}", tag).decode().strip()
        manifest = remote(tag)
        if manifest is None:
            docker("image", "push", tag)
        elif json.loads(manifest)["config"]["digest"] != expected:
            fail(f"{tag} is already published from a different image")
        sources.append(f"{image}@sha256:{hashlib.sha256(remote(tag)).hexdigest()}")
    index = remote(f"{image}:v{version}")
    if index is None:
        annotations = {
            "title": "glowcap Rooms",
            "description": "The glowcap Rooms chat directory and web app",
            "source": f"https://github.com/{env['GITHUB_REPOSITORY']}",
            "revision": env["GITHUB_SHA"],
            "version": f"v{version}",
            "licenses": "Apache-2.0",
        }
        flags = [f"--annotation=index:org.opencontainers.image.{key}={value}" for key, value in annotations.items()]
        docker("buildx", "imagetools", "create", "--tag", f"{image}:v{version}", *flags, *sources)
        index = remote(f"{image}:v{version}")
    manifests = [entry for entry in json.loads(index)["manifests"] if entry["platform"]["architecture"] != "unknown"]
    if sorted(entry["digest"] for entry in manifests) != sorted(source.split("@")[1] for source in sources):
        fail(f"{image}:v{version} is already published over different images")
    platforms = sorted(f"{entry['platform']['os']}/{entry['platform']['architecture']}" for entry in manifests)
    if platforms != [f"linux/{arch}" for arch in PLATFORMS]:
        fail(f"{image}:v{version} serves {platforms}")
    with open(env["GITHUB_OUTPUT"], "a") as output:
        output.write(f"digest=sha256:{hashlib.sha256(index).hexdigest()}\n")


def context(env):
    """This platform's verified Linux product, extracted as the image's build context."""
    name = f"glowcap-v{env['VERSION']}-{env['ARCHIVE_ARCH']}-linux.tar.gz"
    found = sorted(path for path in Path("archive-artifact").rglob(name) if path.is_file())
    if not found:
        fail(f"missing Linux product archive for {env['ARCHIVE_ARCH']}")
    archive = found[0]
    shown("sha256sum", "--check", "SHA256SUMS", cwd=archive.parent, timeout=120)
    Path("image-context").mkdir()
    shown(
        "tar",
        "--extract",
        "--gzip",
        "--file",
        str(archive),
        "--directory",
        "image-context",
        "--no-same-owner",
        timeout=300,
    )


def build(env):
    """The exact single-platform image, saved with its checksum for the release job."""
    version, arch, tag = env["VERSION"], env["IMAGE_ARCH"], f"{env['IMAGE']}:v{env['VERSION']}-{env['IMAGE_ARCH']}"
    Path("image-artifact").mkdir()
    epoch = subprocess.run(
        ["git", "show", "-s", "--format=%ct", env["GITHUB_SHA"]], capture_output=True, check=True, text=True, timeout=30
    ).stdout.strip()
    shown(
        "docker",
        "buildx",
        "build",
        "--platform",
        f"linux/{arch}",
        "--build-arg",
        "SOURCE_DATE_EPOCH",
        "--file",
        "image-context/share/glowcap/deployment/rooms.Dockerfile",
        "--label",
        f"org.opencontainers.image.source=https://github.com/{env['GITHUB_REPOSITORY']}",
        "--label",
        f"org.opencontainers.image.revision={env['GITHUB_SHA']}",
        "--label",
        f"org.opencontainers.image.version=v{version}",
        "--tag",
        tag,
        "--load",
        "image-context",
        env=dict(os.environ, SOURCE_DATE_EPOCH=epoch),
        timeout=1500,
    )
    # The runner's Docker driver loads images directly. Save that image
    # instead of requiring a separate builder's file-export support.
    shown(
        "docker",
        "image",
        "save",
        "--output",
        f"image-artifact/glowcap-rooms-v{version}-{arch}.docker.tar",
        tag,
        timeout=300,
    )
    saved = sorted(path.name for path in Path("image-artifact").glob("*.docker.tar"))
    with open("image-artifact/SHA256SUMS", "w") as sums:
        shown("sha256sum", *saved, cwd="image-artifact", stdout=sums, timeout=120)


def exercise(env):
    """Load the saved image and run the product's image check against it."""
    version, arch = env["VERSION"], env["IMAGE_ARCH"]
    shown(
        "docker", "image", "load", "--input", f"image-artifact/glowcap-rooms-v{version}-{arch}.docker.tar", timeout=300
    )
    shown(
        sys.executable, "tools/check/glowcap_release_image.py", f"{env['IMAGE']}:v{version}-{arch}", arch, timeout=600
    )


ENVIRONMENT = {
    "context": ("VERSION", "ARCHIVE_ARCH"),
    "build": ("VERSION", "IMAGE", "IMAGE_ARCH", "GITHUB_REPOSITORY", "GITHUB_SHA"),
    "exercise": ("VERSION", "IMAGE", "IMAGE_ARCH"),
    "publish": ("GH_TOKEN", "GITHUB_ACTOR", "IMAGE", "VERSION", "GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_OUTPUT"),
}
STEPS = {"context": context, "build": build, "exercise": exercise}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    verbs = parser.add_subparsers(dest="verb", required=True)
    for verb in ENVIRONMENT:
        parsed = verbs.add_parser(verb)
        if verb == "publish":
            parsed.add_argument("artifacts", type=Path)
    args = parser.parse_args(argv)
    env = {name: os.environ.get(name, "") for name in ENVIRONMENT[args.verb]}
    missing = [name for name, value in env.items() if not value]
    if missing:
        fail(f"missing environment: {', '.join(missing)}")
    try:
        if args.verb == "publish":
            publish(args.artifacts, env)
        else:
            STEPS[args.verb](env)
    except subprocess.CalledProcessError as error:
        said = error.stderr.decode(errors="replace").strip() if isinstance(error.stderr, bytes) else ""
        fail(f"{' '.join(map(str, error.cmd))} exited {error.returncode}: {said}")
    except subprocess.TimeoutExpired as error:
        fail(f"{' '.join(map(str, error.cmd))} did not finish within {error.timeout} s")
    except OSError as error:
        fail(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
