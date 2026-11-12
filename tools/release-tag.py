#!/usr/bin/env python3
"""tools/release-tag.py <version>: sign and push the release tag of a promoted version.

The maintainer runs it from any directory inside any worktree of the
repository, on the host that holds the signing key, with gh authenticated.
It fetches main from origin and requires that main's commit states <version>
in bindings/c-abi-resolve.json, carries the version's CHANGELOG.md section,
has no v<version> tag on origin, and passed full validation
(ci/require_main_check.py, through gh). Then it signs v<version> at that
commit, verifies the signature, and pushes the tag. The push is the one
effect, and the release workflow takes over from there.

Only prerelease versions (0.x.y) are accepted. Two lines on stdout name the
pushed tag, the validating run, and the release workflow. Every refusal is
one `release-tag: ...` line on stderr and exits 1, always before the push; a
tag it signed stays local for the retry, and the worktree is never written.
Every command runs under a deadline, and a stalled one is a refusal naming
the call. tools/release_tag_test.py exercises it against a local origin and
a stub gh under infrastructure-check.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))
import release_version  # noqa: E402

LOCAL_TIMEOUT = 30
NETWORK_TIMEOUT = 60
GH_TIMEOUT = 30
SIGN_TIMEOUT = 60
CHECK_TIMEOUT = 180


class Refusal(Exception):
    """A reason to stop before the push."""


def command(argv, *, refusal, timeout, stalled, **options):
    """Run one command under a deadline and return its stdout.

    A failure raises `refusal`, or returns None when the caller passes none
    because the failure is an answer. A stall raises `stalled`.
    """
    try:
        done = subprocess.run(argv, timeout=timeout, stdout=subprocess.PIPE, text=True, errors="replace", **options)
    except subprocess.TimeoutExpired:
        raise Refusal(stalled) from None
    except OSError as error:
        raise Refusal(f"cannot run {argv[0]}: {error}") from None
    if done.returncode == 0:
        return done.stdout
    if refusal is None:
        return None
    raise Refusal(refusal)


def git(*args, refusal, timeout=LOCAL_TIMEOUT, stalled=None, **options):
    """Run git in the caller's directory."""
    stalled = stalled or f"`git {args[0]}` did not finish within {timeout} seconds; rerun when it responds"
    return command(["git", *args], refusal=refusal, timeout=timeout, stalled=stalled, **options)


def release(version):
    tag = f"v{version}"
    git("rev-parse", "--show-toplevel", refusal="not inside a Git worktree", stderr=subprocess.DEVNULL)
    git(
        "fetch",
        "-q",
        "origin",
        "+refs/heads/main:refs/remotes/origin/main",
        refusal="cannot fetch main from origin",
        timeout=NETWORK_TIMEOUT,
    )
    commit = git("rev-parse", "refs/remotes/origin/main", refusal="cannot resolve main after fetching it").strip()
    listed = git(
        "ls-remote",
        "--tags",
        "origin",
        f"refs/tags/{tag}",
        refusal="cannot list the tags on origin",
        timeout=NETWORK_TIMEOUT,
    )
    if listed.strip():
        raise Refusal(
            f"{tag} is already on origin; a published version is never replaced, "
            "so a defect takes the next patch version"
        )

    unreadable = "cannot read the version main states"
    try:
        stated = str(
            json.loads(git("show", f"{commit}:bindings/c-abi-resolve.json", refusal=unreadable))["abi_version"]
        )
    except (ValueError, KeyError, TypeError):
        raise Refusal(unreadable) from None
    if stated != version:
        raise Refusal(
            f"main ({commit}) states {stated}, not {version}; "
            f"land `zig build set-version -Dversion={version}` on dev "
            "and let promotion move main first"
        )
    missing = f"CHANGELOG.md on main has no [{version}] section"
    if not re.search(rf"^## \[{re.escape(version)}\]", git("show", f"{commit}:CHANGELOG.md", refusal=missing), re.M):
        raise Refusal(missing)

    repository = command(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        refusal="gh cannot name the repository; run gh auth login first",
        timeout=GH_TIMEOUT,
        stalled=f"gh did not name the repository within {GH_TIMEOUT} seconds; rerun when GitHub responds",
    ).rstrip("\n")
    unvalidated = f"main ({commit}) has no successful full validation, so the release workflow would refuse the tag"
    run_url = command(
        [sys.executable, str(ROOT / "ci/require_main_check.py"), commit],
        refusal=unvalidated,
        timeout=CHECK_TIMEOUT,
        stalled=f"{unvalidated} (the validation lookup exceeded {CHECK_TIMEOUT} seconds)",
        env={**os.environ, "GITHUB_REPOSITORY": repository},
    ).rstrip("\n")

    existing = git("rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}", refusal=None)
    if existing is not None:
        if existing.strip() != commit:
            raise Refusal(
                f"local tag {tag} points at {existing.strip()}, not main's {commit}; inspect and delete it, then retry"
            )
    else:
        unreachable = "make the signing key reachable (forward the agent that holds it) and retry"
        git(
            "tag",
            "-s",
            tag,
            commit,
            "-m",
            f"glowcap {version}",
            refusal=f"signing failed; {unreachable}",
            timeout=SIGN_TIMEOUT,
            stalled=f"signing {tag} did not finish within {SIGN_TIMEOUT} seconds; {unreachable}",
        )
    git(
        "verify-tag",
        tag,
        refusal=f"the signature on {tag} does not verify; name the key in gpg.ssh.allowedSignersFile and retry",
        stderr=subprocess.DEVNULL,
    )
    git(
        "push",
        "-q",
        "origin",
        f"refs/tags/{tag}",
        refusal=f"pushing {tag} failed; the signed tag is kept locally, retry",
        timeout=NETWORK_TIMEOUT,
        stalled=f"pushing {tag} did not finish within {NETWORK_TIMEOUT} seconds; "
        "the signed tag is kept locally, check origin and retry",
    )
    print(f"release-tag: pushed {tag} at {commit}, validated by {run_url}")
    print(
        f"release-tag: the release workflow publishes it: https://github.com/{repository}/actions/workflows/release.yml"
    )


def main(argv):
    try:
        if len(argv) != 1:
            raise Refusal("usage: tools/release-tag.py <version>")
        if not release_version.accepted(argv[0]):
            raise Refusal(f"{argv[0]} is not a prerelease version such as 0.1.2")
        release(argv[0])
    except Refusal as refusal:
        print(f"release-tag: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
