"""Publish the glowcap crate at VERSION unless crates.io already holds it.

Caller: publish.yml's crates-io job, from the checkout root at the release
commit. Reads VERSION and GITHUB_REPOSITORY, and leaves CARGO_REGISTRY_TOKEN
and the binding's download settings to cargo. VERSION must be a prerelease
version and the one bindings/rust/Cargo.toml states, because cargo publishes
the manifest's version whatever the release asked for. Asks crates.io for it:
200 means it is already published and nothing runs, 404 runs
`cargo publish --manifest-path bindings/rust/Cargo.toml`, and any other answer,
a failed lookup, or a failed publish exits 1 with a `crate-publish:` message.
ci/crate_publish_test.py drives it against a stub curl and cargo.
"""

import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

import release_version

MANIFEST = Path("bindings/rust/Cargo.toml")


def fail(message):
    print(f"crate-publish: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    version = os.environ.get("VERSION", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not release_version.accepted(version):
        fail(f"invalid VERSION: {version!r}")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        fail(f"invalid GITHUB_REPOSITORY: {repository!r}")
    try:
        stated = tomllib.loads(MANIFEST.read_text()).get("package", {}).get("version")
    except (OSError, ValueError) as error:
        fail(f"{MANIFEST}: {error}")
    try:
        if stated != version:
            fail(
                f"{MANIFEST} states {stated!r}, not the release's {version}, so nothing was published. "
                f"Land `zig build set-version -Dversion={version}` before releasing."
            )
        status = subprocess.run(
            [
                "curl",
                "-sS",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "-A",
                f"glowcap-publish ({repository})",
                f"https://crates.io/api/v1/crates/glowcap/{version}",
            ],
            capture_output=True,
            check=True,
            text=True,
            timeout=60,
        ).stdout
        if status == "200":
            print(f"crates.io already holds glowcap {version}")
        elif status == "404":
            subprocess.run(["cargo", "publish", "--manifest-path", str(MANIFEST)], check=True, timeout=1200)
        else:
            fail(
                f"crates.io lookup for glowcap {version} answered {status}, so nothing was published. "
                "Rerun this job once https://status.crates.io reports the registry healthy. "
                "A rerun publishes at most once."
            )
    except subprocess.CalledProcessError as error:
        said = error.stderr.strip() if isinstance(error.stderr, str) else ""
        fail(f"{' '.join(error.cmd)} exited {error.returncode}{': ' + said if said else ''}")
    except subprocess.TimeoutExpired as error:
        fail(f"{' '.join(error.cmd)} did not finish within {error.timeout} s")
    except OSError as error:
        fail(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
