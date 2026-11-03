"""bench-interface-builds: warm dependencies, then compile one selected client.

The build graph supplies the marks archive and repository cwd. Cargo children
are bounded. Reports contain no absolute archive paths, and source is untouched.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from measure import environment


def build_command(client, probe=None):
    command = [
        "cargo",
        "rustc",
        "--release",
        "--manifest-path",
        "bench/interface/Cargo.toml",
        "--target-dir",
        "zig-out/interface-compile",
        "--no-default-features",
        "--features",
        f"{client}-client",
        "--bin",
        "interface-bench",
    ]
    if probe is not None:
        # Only this crate's rustc command changes. Dependencies keep their
        # warmed fingerprint, while this invocation cannot reuse the binary.
        command += ["--", "--cfg", f'interface_cost_probe="{probe}"']
    return command


def build(client, marks, probe=None):
    start = time.perf_counter_ns()
    result = subprocess.run(
        [sys.executable, "tools/run-with-timeout.py", "--kill-after", "2s", "120s", *build_command(client, probe)],
        env={**os.environ, "GLOWCAP_INTERFACE_MARKS": str(Path(marks).resolve()), "CARGO_TERM_COLOR": "never"},
        text=True,
        capture_output=True,
        timeout=125,
    )
    elapsed = time.perf_counter_ns() - start
    if result.returncode:
        print(result.stdout, end="")
        print(result.stderr, end="")
        result.check_returncode()
    if probe is not None:
        compiled = [
            line.strip().split()[1] for line in result.stderr.splitlines() if line.strip().startswith("Compiling ")
        ]
        assert compiled == ["interface-bench"], f"expected only a fresh top crate, got {compiled}"
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--marks", required=True)
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    assert 1 <= args.pairs <= 10
    for client in ("raw", "generated"):
        build(client, args.marks)
    samples = []
    # A new probe identity forces top-crate compilation across repeated runs,
    # without touching source or flushing warmed dependency caches.
    run = time.time_ns()
    for pair in range(1 if args.smoke else args.pairs):
        clients = ("raw", "generated") if pair % 2 == 0 else ("generated", "raw")
        for client in clients:
            elapsed = build(client, args.marks, f"{run}-{pair}-{client}")
            samples.append(dict(client=client, pair=pair, elapsed_ns=elapsed))
    report = dict(
        environment=environment(),
        scope="fresh top crate and link, warmed dependencies, including Cargo bookkeeping and deadline launcher",
        shared_code="actor, TCP pair, runtime, timers, assertions and profile bridge",
        samples=samples,
        smoke=args.smoke,
        requires_quiet_host=True,
        full_clean_build=False,
    )
    output = Path("zig-out/bench-reports/interface-builds.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
