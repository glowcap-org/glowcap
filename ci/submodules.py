"""Check out the pinned conformance submodules without leaning on their hosts.

Called by the workflows at the checkout root, after actions/checkout ran
with no submodules. One of them lives on Codeberg, a
donated forge, and every job needs the tree whole, so a job clones only when
the pinned commits changed. The job caches `.git/modules` under `key`, and
`checkout` finds the pinned commits there and touches no network. A miss
clones, and a host that stumbles gets a bounded wait and another attempt.
Git verifies every object it checks out, so a restored cache is held to the
pins by the same code that holds a fresh clone.

    submodules.py key        print the cache key to GITHUB_OUTPUT
    submodules.py checkout   check out every submodule at its pinned commit
"""

import argparse
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# A clone here finishes in seconds or stalls. The waits outlast a gateway
# error's usual minute without holding a job past its own deadline.
ATTEMPT_SECONDS = 180
WAITS = (15, 60)


def git(root, *args, timeout=None):
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=timeout)


def key(root=ROOT):
    """The pins as one name: where each submodule comes from and the commit it is held to."""
    pins = git(root, "ls-files", "--stage", "--", ".gitmodules")
    links = git(root, "ls-files", "--stage")
    if pins.returncode != 0 or links.returncode != 0:
        raise SystemExit(f"submodules: cannot read the index: {(pins.stderr or links.stderr).strip()}")
    gitlinks = [line for line in links.stdout.splitlines() if line.startswith("160000 ")]
    return "submodules-" + hashlib.sha256("\n".join([pins.stdout.strip(), *gitlinks]).encode()).hexdigest()[:32]


def unsettled(root):
    """The submodules whose checkout is not the pinned commit, as `git submodule status` marks them."""
    status = git(root, "submodule", "status", "--recursive")
    if status.returncode != 0:
        return [status.stderr.strip() or "git submodule status failed"]
    return [line for line in status.stdout.splitlines() if line[:1] != " "]


def checkout(root=ROOT, waits=WAITS, sleep=time.sleep):
    for attempt, wait in enumerate((*waits, None), start=1):
        try:
            update = git(root, "submodule", "update", "--init", "--recursive", timeout=ATTEMPT_SECONDS)
            said = update.stderr.strip()
        except subprocess.TimeoutExpired:
            update, said = None, f"no result in {ATTEMPT_SECONDS} s"
        if update is not None and update.returncode == 0:
            break
        print(f"submodules: attempt {attempt} failed: {said}", file=sys.stderr)
        if wait is None:
            raise SystemExit("submodules: the pinned commits could not be fetched")
        sleep(wait)
    left = unsettled(root)
    if left:
        raise SystemExit("submodules: not at the pinned commits:\n" + "\n".join(left))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("key", "checkout"))
    command = parser.parse_args().command
    if command == "key":
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"key={key()}\n")
    else:
        checkout()


if __name__ == "__main__":
    main()
