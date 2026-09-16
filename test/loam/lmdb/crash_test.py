"""loam-lmdb-crash-test: kill the supplied probe at native commit boundaries.

The build supplies the executable path. Temporary stores are removed on every
outcome; each child has a deadline and is reaped. No environment input or
repository working directory is required. Success is silent, failure is nonzero.
"""

import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile


def run(probe, mode, directory):
    subprocess.run([probe, mode, directory], cwd=directory, check=True, timeout=5)


def interrupt(probe, mode, directory):
    child = subprocess.Popen(
        [probe, mode, directory], cwd=directory,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    try:
        ready, _, _ = select.select([child.stderr], [], [], 5)
        if not ready or os.read(child.stderr.fileno(), 4096) != b"READY\n":
            raise AssertionError(f"{mode}: child did not reach its commit boundary")
        child.kill()
        if child.wait(timeout=5) != -signal.SIGKILL:
            raise AssertionError("child was not killed at the requested boundary")
    finally:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
        child.stderr.close()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("expected one compiled Loam probe path")
    probe = str(Path(sys.argv[1]).resolve(strict=True))
    for boundary, expected in (("before", "old"), ("after", "new")):
        with tempfile.TemporaryDirectory(prefix="glowcap loam ") as directory:
            run(probe, "create", directory)
            interrupt(probe, boundary, directory)
            run(probe, "verify-" + expected, directory)


if __name__ == "__main__":
    main()
