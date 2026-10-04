"""loam-lmdb-crash-test: kill the supplied probe at native commit boundaries.

The build supplies the executable path and optional scenarios/extra boundaries.
Temporary stores are removed on every
outcome; each child has a deadline and is reaped. No environment input or
repository working directory is required. Success is silent, failure is nonzero.
"""

import argparse
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile


def run(probe, mode, directory, scenario):
    subprocess.run([probe, mode, directory, *scenario], cwd=directory, check=True, timeout=5)


def interrupt(probe, mode, directory, scenario):
    child = subprocess.Popen(
        [probe, mode, directory, *scenario], cwd=directory,
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("probe", type=lambda value: str(Path(value).resolve(strict=True)))
    parser.add_argument("--scenario", action="append")
    parser.add_argument("--boundary", action="append", choices=("before", "after", "installed", "published"))
    args = parser.parse_args()
    scenarios = [[item] for item in args.scenario] if args.scenario else [[]]
    for scenario in scenarios:
        for boundary in args.boundary or ("before", "after"):
            expected = "old" if boundary == "before" else "new"
            with tempfile.TemporaryDirectory(prefix="glowcap loam ") as directory:
                try:
                    run(args.probe, "create", directory, scenario)
                    interrupt(args.probe, boundary, directory, scenario)
                    run(args.probe, "verify-" + expected, directory, scenario)
                except Exception as error:
                    raise RuntimeError(f"{scenario or ['records']}, {boundary}: {error}") from error


if __name__ == "__main__":
    main()
