"""Build-step helper for interface smoke, profiles, and generator process costs.

The build graph supplies executable paths and owns the repository cwd. Every
child has a deadline. Reports stay under zig-out, and no source is rewritten.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10).strip()


def cpu_details(text):
    result = {}
    for field in (
        "model name",
        "CPU implementer",
        "CPU architecture",
        "CPU variant",
        "CPU part",
        "CPU revision",
        "Hardware",
    ):
        match = re.search(rf"(?m)^{re.escape(field)}\s*:\s*(.*)", text)
        if match:
            result[field] = match[1]
    return result


def storage_details(worktree=Path("."), sysfs=Path("/sys/dev/block")):
    device = worktree.stat().st_dev
    node = sysfs / f"{os.major(device)}:{os.minor(device)}"
    result = dict(status="unavailable", model=None, rotational=None)
    if not node.exists():
        return result
    # Follow only this filesystem's device and its parents. Do not borrow a
    # model from another disk or publish the device number or sysfs path.
    for parent in (node.resolve(), *node.resolve().parents):
        model = parent / "device/model"
        rotational = parent / "queue/rotational"
        if result["model"] is None and model.is_file():
            try:
                result["model"] = model.read_text().strip()
            except OSError:
                pass  # Optional environment metadata can be hidden by a container.
        if result["rotational"] is None and rotational.is_file():
            try:
                flag = rotational.read_text().strip()
            except OSError:
                flag = ""
            if flag in {"0", "1"}:
                result["rotational"] = flag == "1"
        if result["model"] is not None and result["rotational"] is not None:
            break
    if result["model"] or result["rotational"] is not None:
        result["status"] = "observed"
    return result


def environment():
    cpu = {}
    memory = "unavailable"
    if Path("/proc/cpuinfo").exists():
        cpu = cpu_details(Path("/proc/cpuinfo").read_text())
        memory = re.search(r"MemTotal:\s*(.*)", Path("/proc/meminfo").read_text())[1]
    return dict(
        revision=command("git", "rev-parse", "HEAD"),
        dirty=bool(command("git", "status", "--porcelain")),
        architecture=platform.machine(),
        zig=command("zig", "version"),
        rust=command("rustc", "--version"),
        kernel=platform.release(),
        cpu=cpu,
        worktree_filesystem=command("stat", "-f", "-c", "%T", ".") if sys.platform == "linux" else "unrecorded",
        storage=storage_details(),
        consumer_manifest_sha256=hashlib.sha256(Path("bench/interface/Cargo.toml").read_bytes()).hexdigest(),
        consumer_lock_sha256=hashlib.sha256(Path("bench/interface/Cargo.lock").read_bytes()).hexdigest()
        if Path("bench/interface/Cargo.lock").exists()
        else None,
        memory=memory,
        affinity=sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        zig_optimize=os.environ.get("GLOWCAP_BENCH_ZIG_OPTIMIZE", "unspecified"),
        container_pins_sha256=hashlib.sha256(Path(".devcontainer/pins.sh").read_bytes()).hexdigest(),
    )


def without_literals(source):
    """Keep code braces and line positions while masking Zig strings/comments."""
    return re.sub(
        r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda match: " " * len(match[0]), source
    )


def inventory():
    rows = []
    for path in sorted(Path("tools/interface").rglob("*")):
        if not path.is_file() or path.suffix == ".md":
            continue
        source = path.read_text()
        masked = without_literals(source)
        test_lines = set()
        # Embedded tests are reported separately. Helpers outside these blocks
        # remain in source overhead, so the implementation count is conservative.
        for match in re.finditer(r"(?m)^test\s*\{", masked):
            end, depth = match.end(), 1
            while depth:
                depth += (masked[end] == "{") - (masked[end] == "}")
                end += 1
            test_lines.update(range(source.count("\n", 0, match.start()), source.count("\n", 0, end) + 1))
        nonblank = {index for index, line in enumerate(source.splitlines()) if line.strip()}
        rows.append(
            dict(
                path=str(path),
                implementation_nonblank=len(nonblank - test_lines),
                embedded_test_nonblank=len(nonblank & test_lines),
            )
        )
    generated, qualification, benchmark = [], [], []
    paths = command("git", "ls-files", "--cached", "--others", "--exclude-standard").splitlines()
    for name in paths:
        path = Path(name)
        if path.suffix not in {".rs", ".ts", ".py", ".zig", ".rkt", ".in"}:
            continue
        text = path.read_text()
        row = dict(path=name, nonblank=sum(bool(line.strip()) for line in text.splitlines()))
        if text.splitlines() and any(
            banner in text.splitlines()[0]
            for banner in (
                "Generated by `zig build gen-interface-fixtures`",
                "Generated from checked interface descriptions.",
            )
        ):
            generated.append(row)
        elif (
            name.startswith("test/interface/")
            or name.startswith("interop/goblins_interop/interface_")
            or (name.startswith("conformance/goblins-peer/") and path.name.startswith("interface-"))
        ):
            qualification.append(row)
        elif name.startswith("bench/interface/") or name == "tools/build/interface_bench.zig":
            benchmark.append(row)
    return dict(
        compiler=rows,
        handwritten_qualification=qualification,
        generated_output=generated,
        benchmark_infrastructure=benchmark,
        generated_output_offsets_compiler=False,
    )


def copy_sources():
    sources = [
        "bench/interface/src/workflow.rs",
        "tools/interface/templates/creation.rs",
        "tools/interface/templates/receipt.rs",
        "tools/interface/templates/references.rs",
        "tools/interface/templates/support.rs",
        "tools/interface/callbacks.zig",
        "apps/tasks/rust/interface.rs",
        "test/interface/generated/callbacks.rs",
        "bindings/rust/src/value.rs",
    ]
    return dict(
        kind="not_instrumented",
        total_copied_bytes=None,
        total_unmeasured_reason="Allocation demand and wire bytes do not count copies. Inlining also prevents a complete memcpy-call census.",
        source_sha256={name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in sources},
    )


def records(stdout):
    result = []
    for line in stdout.splitlines():
        if not line.startswith("interface_"):
            continue
        fields = dict(field.split("=", 1) for field in line.split()[1:])
        result.append(
            dict(
                kind=line.split()[0],
                **{key: int(value) if re.fullmatch(r"-?\d+", value) else value for key, value in fields.items()},
            )
        )
    return result


def run_generator(executable, timeout=10):
    """wait4 includes inherited pre-exec RSS, so this is an upper bound."""
    start = time.perf_counter_ns()
    pid = os.posix_spawn(str(Path(executable).resolve()), [executable], os.environ)
    deadline = time.monotonic() + timeout
    while True:
        ended, status, usage = os.wait4(pid, os.WNOHANG)
        if ended:
            if os.waitstatus_to_exitcode(status):
                raise RuntimeError("interface generator failed")
            rss = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
            return dict(elapsed_ns=time.perf_counter_ns() - start, peak_rss_upper_bound_bytes=rss)
        if time.monotonic() > deadline:
            os.kill(pid, signal.SIGKILL)
            os.wait4(pid, 0)
            raise TimeoutError("interface generator exceeded its deadline")
        time.sleep(0.001)


def smoke(binary):
    result = subprocess.run([binary, "--smoke"], text=True, capture_output=True, timeout=25)
    if result.returncode:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"interface benchmark exited {result.returncode}")
    rows = records(result.stdout)
    for client in ("raw", "generated"):
        for row in ("ordinary", "preparation", "submission", "replay"):
            matches = [
                record
                for record in rows
                if record.get("client") == client
                and record.get("row") == row
                and ("rust_allocations" in record or "outbound_frames" in record)
            ]
            assert len(matches) == 2, (client, row, matches)
            alloc = next(record for record in matches if "rust_allocations" in record)
            wire = next(record for record in matches if "outbound_frames" in record)
            assert int(alloc["native_allocations"]) > 0
            assert int(wire["outbound_frames"]) > 0 and int(wire["logical_calls"]) == 1
            assert int(wire["committed_effects"]) == int(row == "submission")
    print(result.stdout, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--smoke")
    group.add_argument("--profile")
    group.add_argument("--generator")
    group.add_argument("--diagnostics")
    group.add_argument("--latency")
    parser.add_argument("--output")
    parser.add_argument("--generation-samples", type=int, default=7)
    args, extra = parser.parse_known_args()
    if extra and not args.latency:
        parser.error("extra arguments belong only to the latency client")
    if args.smoke:
        smoke(args.smoke)
    elif args.profile:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "valgrind",
                "--tool=callgrind",
                "--instr-atstart=no",
                "--collect-atstart=no",
                f"--callgrind-out-file={output}",
                "--aspace-minaddr=0x100000000",
                args.profile,
                "--mode=profile",
                "--samples=1",
                "--pairs=1",
                "--warmup=1",
            ],
            timeout=1800,
            check=True,
        )
    elif args.generator:
        assert 1 <= args.generation_samples <= 100
        run_generator(args.generator)
        recorded_environment = environment()
        report = dict(
            environment=recorded_environment,
            provisional=recorded_environment["storage"]["status"] != "observed",
            inventory=inventory(),
            generation=[run_generator(args.generator) for _ in range(args.generation_samples)],
            rss_scope="wait4 includes inherited pre-exec RSS, so this bounds rather than isolates the generator peak",
            scope="warm generation and fixture verification, excluding compilation",
            latency_claim=False,
        )
        output = Path(args.output or "zig-out/bench-reports/interface-generation.json")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report))
    else:
        binary = args.diagnostics or args.latency
        result = subprocess.run([binary, *extra], text=True, capture_output=True, timeout=30)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        result.check_returncode()
        recorded_environment = environment()
        report = dict(
            environment=recorded_environment,
            provisional=recorded_environment["storage"]["status"] != "observed",
            records=records(result.stdout),
            copy_sources=copy_sources(),
            latency_claim=bool(args.latency),
            requires_quiet_host=bool(args.latency),
        )
        name = "interface-latency.json" if args.latency else "interface-diagnostics.json"
        output = Path(args.output or f"zig-out/bench-reports/{name}")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
