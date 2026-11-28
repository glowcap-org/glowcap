"""Cargo target runner for the session and bot process suites in zig build rooms-peers-test.

Cargo supplies the compiled executable, crate working directory and loader paths.
Each case starts real processes and gets its own 30 seconds from launch.
"""

import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TIMEOUT = "30s"
SUPERVISOR = Path(__file__).resolve().parents[2] / "run-with-timeout.py"


def main(binary: str) -> int:
    timer = [sys.executable, str(SUPERVISOR), "--kill-after", "2s"]
    listing = subprocess.run([*timer, TIMEOUT, binary, "--list", "--format=terse"], stdout=subprocess.PIPE, text=True)
    if listing.returncode:
        return listing.returncode
    cases = [line.removesuffix(": test") for line in listing.stdout.splitlines() if line.endswith(": test")]
    if not cases:
        print(f"{binary} listed no test cases", file=sys.stderr)
        return 1

    print(f"Running {len(cases)} process tests with a {TIMEOUT} deadline per case", flush=True)

    def run(case: str) -> int:
        result = subprocess.run([*timer, "--quiet-success", TIMEOUT, binary, "--exact", case])
        if result.returncode:
            print(f"{case} exited with status {result.returncode}", file=sys.stderr)
        return result.returncode

    cpus = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 1)
    with ThreadPoolExecutor(max_workers=min(4, cpus)) as workers:
        return next((code for code in workers.map(run, cases) if code), 0)


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
