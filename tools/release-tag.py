#!/usr/bin/env python3
"""tools/release-tag.py <version>: sign and push the release tag of a promoted version.

The maintainer runs it from any worktree of the repository, on the host that
holds the signing key. It fetches main from origin and requires that main's
commit states <version> in bindings/c-abi-resolve.json, carries the version's
CHANGELOG.md section, has no v<version> tag on origin, and passed full
validation (ci/require_main_check.py, through gh). Then it signs v<version> at
that commit, verifies the signature, and pushes the tag. The push is the one
effect, and the release workflow takes over from there.

Arguments: one version such as 0.1.2. Only prerelease versions (0.x.y) are
accepted.
Environment: the caller's, plus the git configuration that names the signing
key and gh authentication. GITHUB_REPOSITORY is set for the validation helper
from `gh repo view`.
Output: two lines on stdout naming the pushed tag, the validating run, and the
release workflow. Every refusal is one `release-tag: ...` line on stderr.
Failure status: 1 on every refusal, always before the push. A tag it signed
stays local for the retry. It writes nothing to the worktree.
Working directory: git runs in the caller's directory, so run it inside a
worktree of the repository. The helper path resolves from this file's own
location, so any worktree and any directory inside it works.
Deadlines: every git network call has 60 seconds, gh and local git 30, signing
60, and the validation helper 180 (it bounds each GitHub request itself). A
stalled call is a refusal naming the call, never a traceback.

tools/release_tag_test.py exercises it against a local origin and a stub gh
under infrastructure-check.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LOCAL_TIMEOUT = 30
NETWORK_TIMEOUT = 60
GH_TIMEOUT = 30
SIGN_TIMEOUT = 60
CHECK_TIMEOUT = 180


class Refusal(Exception):
    """A reason to stop before the push."""


def run(argv, timeout, timed_out, **options):
    """Run one command with a deadline, turning a stall or a missing program into a refusal."""
    try:
        return subprocess.run(argv, timeout=timeout, **options)
    except subprocess.TimeoutExpired:
        raise Refusal(timed_out) from None
    except OSError as error:
        raise Refusal(f"cannot run {argv[0]}: {error}") from None


def git(*args, timeout=LOCAL_TIMEOUT, timed_out=None, **options):
    """Run git in the caller's directory."""
    if timed_out is None:
        timed_out = f"`git {args[0]}` did not finish within {timeout} seconds; rerun when it responds"
    return run(["git", *args], timeout, timed_out, **options)


def git_output(*args, **options):
    """Run git and return the finished process with its stdout as text."""
    return git(*args, stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", **options)


def release(version):
    tag = f"v{version}"
    if git("rev-parse", "--show-toplevel", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise Refusal("not inside a Git worktree")

    if git("fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main",
           timeout=NETWORK_TIMEOUT).returncode:
        raise Refusal("cannot fetch main from origin")
    resolved = git_output("rev-parse", "refs/remotes/origin/main")
    if resolved.returncode:
        raise Refusal("cannot resolve main after fetching it from origin")
    commit = resolved.stdout.strip()

    listed = git_output("ls-remote", "--tags", "origin", f"refs/tags/{tag}", timeout=NETWORK_TIMEOUT)
    if listed.returncode:
        raise Refusal("cannot list the tags on origin")
    if listed.stdout.strip():
        raise Refusal(f"{tag} is already on origin; a published version is never replaced, "
                      "so a defect takes the next patch version")

    shown = git_output("show", f"{commit}:bindings/c-abi-resolve.json")
    try:
        if shown.returncode:
            raise ValueError("git show failed")
        stated = str(json.loads(shown.stdout)["abi_version"])
    except (ValueError, KeyError, TypeError):
        raise Refusal("cannot read the version main states") from None
    if stated != version:
        raise Refusal(f"main ({commit}) states {stated}, not {version}; "
                      f"land `zig build set-version -Dversion={version}` on dev "
                      "and let promotion move main first")
    changelog = git_output("show", f"{commit}:CHANGELOG.md")
    if changelog.returncode or not re.search(rf"^## \[{re.escape(version)}\]", changelog.stdout, re.MULTILINE):
        raise Refusal(f"CHANGELOG.md on main has no [{version}] section")

    named = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], GH_TIMEOUT,
                f"gh did not name the repository within {GH_TIMEOUT} seconds; rerun when GitHub responds",
                stdout=subprocess.PIPE, text=True)
    if named.returncode:
        raise Refusal("gh cannot name the repository; run gh auth login first")
    repository = named.stdout.rstrip("\n")
    refusal = (f"main ({commit}) has no successful full validation, "
               "so the release workflow would refuse the tag")
    validated = run([sys.executable, str(ROOT / "ci/require_main_check.py"), commit], CHECK_TIMEOUT,
                    f"{refusal} (the validation lookup exceeded {CHECK_TIMEOUT} seconds)",
                    env={**os.environ, "GITHUB_REPOSITORY": repository},
                    stdout=subprocess.PIPE, text=True)
    if validated.returncode:
        raise Refusal(refusal)
    run_url = validated.stdout.rstrip("\n")

    existing = git_output("rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}")
    if existing.returncode == 0:
        if existing.stdout.strip() != commit:
            raise Refusal(f"local tag {tag} points at {existing.stdout.strip()}, not main's {commit}; "
                          "inspect and delete it, then retry")
    elif git("tag", "-s", tag, commit, "-m", f"glowcap {version}", timeout=SIGN_TIMEOUT,
             timed_out=f"signing {tag} did not finish within {SIGN_TIMEOUT} seconds; "
                       "make the signing key reachable (forward the agent that holds it) and retry"
             ).returncode:
        raise Refusal("signing failed; make the signing key reachable "
                      "(forward the agent that holds it) and retry")
    if git("verify-tag", tag, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise Refusal(f"the signature on {tag} does not verify; "
                      "name the key in gpg.ssh.allowedSignersFile and retry")
    if git("push", "-q", "origin", f"refs/tags/{tag}", timeout=NETWORK_TIMEOUT,
           timed_out=f"pushing {tag} did not finish within {NETWORK_TIMEOUT} seconds; "
                     "the signed tag is kept locally, check origin and retry").returncode:
        raise Refusal(f"pushing {tag} failed; the signed tag is kept locally, retry")
    print(f"release-tag: pushed {tag} at {commit}, validated by {run_url}")
    print(f"release-tag: the release workflow publishes it: https://github.com/{repository}/actions/workflows/release.yml")


def main(argv):
    try:
        if len(argv) != 1:
            raise Refusal("usage: tools/release-tag.py <version>")
        if not re.fullmatch(r"0\.[0-9]+\.[0-9]+", argv[0]):
            raise Refusal(f"{argv[0]} is not a prerelease version such as 0.1.2")
        release(argv[0])
    except Refusal as refusal:
        print(f"release-tag: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
