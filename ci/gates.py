"""Run CI gates: one phase, every phase, or one build shard's compile.

Called from the repository root, inside the devcontainer in CI and under
`glowcap-dev` locally. ci/groups.py says what runs.

    ci/gates.py run [PHASE]        run one phase, or every phase in order
    ci/gates.py compile K/N PHASE...  compile shard K of N of what the phases run
    ci/gates.py fetch              fetch the pinned Zig dependency graph
    ci/gates.py summary            append the evidence records to the step summary

Each gate runs under tools/run-with-timeout.py with the deadline its class
sets: GATE_TIMEOUT (20m), LONG_TIMEOUT (40m), BUILD_TIMEOUT (60m), each an
environment override, and GATE_TIMEOUT alone overrides all three. A failed
gate is reported and the phase goes on, so one run names every failure, and
the first failure's status is the exit status. A build that runs out of time
stops the phase, because every later gate needs it. Exit 124 or 137 from a
gate means the deadline killed it (`wedged`).

A run writes an evidence record (ci/evidence.py): under
zig-out/evidence/<phase> for one phase, or attached to HEAD as a git note for
a full run on a clean checkout. A green run whose record fails exits 70. A
compile writes no record. Exit 2 names a malformed call.

`fetch` makes three bounded attempts, pausing ZIG_FETCH_RETRY_DELAY seconds
(default 5) between them, and stops at once on an interrupt or termination.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ci"))
import evidence  # noqa: E402
import groups  # noqa: E402

NAME = "ci/gates.py"
TIMEOUT_DEFAULTS = {"gate": "20m", "long": "40m", "build": "60m"}
FETCH_ATTEMPTS = 3
INTERRUPTED = (129, 130, 143)


def say(message):
    print(f"{NAME}: {message}", file=sys.stderr, flush=True)


def wedged(status):
    """True when the deadline wrapper killed the gate."""
    return status in (124, 137)


def deadline(kind):
    """The deadline for a gate class, from the environment or the default."""
    general = os.environ.get("GATE_TIMEOUT")
    if kind == "gate":
        return general or TIMEOUT_DEFAULTS[kind]
    return os.environ.get(f"{kind.upper()}_TIMEOUT") or general or TIMEOUT_DEFAULTS[kind]


def with_defaults(argv):
    """A `zig build` command with the per-test deadline and summary CI expects."""
    if argv[:2] != ["zig", "build"]:
        return argv
    options = argv[2:]
    given = set(options[: options.index("--")] if "--" in options else options)
    extra = []
    if "--test-timeout" not in given:
        extra += ["--test-timeout", "30s"]
    if "--summary" not in given:
        extra += ["--summary", "new"]
    return ["zig", "build", *extra, *options]


def execute(argv, timeout):
    """Run one command under the deadline wrapper and return its status."""
    wrapper = ["python3", "tools/run-with-timeout.py", "--kill-after", "30s", "--heartbeat", "60s", timeout]
    return subprocess.run(wrapper + argv, cwd=ROOT).returncode


class Run:
    """The gates of one invocation, in order, with their outcomes."""

    def __init__(self):
        self.rows = []
        self.first_failure = 0

    def gate(self, kind, argv, timeout):
        """Run one gate. Returns the status that stops the phase, or None."""
        command = " ".join(argv)
        say(f"starting: {command}")
        began = time.monotonic()
        status = execute(argv, timeout)
        seconds = round(time.monotonic() - began)
        self.rows.append({"command": command, "exit": status, "seconds": seconds})
        if status == 0:
            say(f"passed ({seconds}s): {command}")
            return None
        say(f"gate failed (exit {status}): {command}")
        if wedged(status):
            say(
                f"  It exceeded {timeout} and was killed. Inspect the gate's last output"
                " and any process still holding its port before retrying."
            )
            if kind == "build":
                say("  Every later gate in this phase needs this build, so the phase stops here.")
                return status
        elif status in (126, 127):
            say("  The command could not be run at all (not found, or not executable).")
        else:
            say("  This is the gate's own failure, not the deadline's. Run it alone to see its output.")
        self.first_failure = self.first_failure or status
        return None

    def phase(self, name):
        """Run a phase's gates. Returns the status that stopped it, or None."""
        for kind, command in groups.PHASES[name]:
            stop = self.gate(kind, with_defaults(shlex.split(command)), deadline(kind))
            if stop is not None:
                return stop
        return None

    def compile(self, shard, phases):
        """Compile each distinct `zig build` gate once, without running tests."""
        seen = set()
        for name in phases:
            for kind, command in groups.PHASES[name]:
                argv = shlex.split(command)
                if argv[:2] != ["zig", "build"]:
                    continue
                argv = ["zig", "build", "-Dcompile-only", f"-Dcompile-shard={shard}", "--summary", "new", *argv[2:]]
                if tuple(argv) in seen:
                    continue
                seen.add(tuple(argv))
                stop = self.gate(kind, argv, deadline("build"))
                if stop is not None:
                    return stop
        return self.first_failure


def finish(run, started, status, phase):
    """Write the run's evidence record. Returns the status the run exits with."""
    try:
        body = evidence.record(run.rows, started, "passed" if status == 0 else "failed")
        if phase is None:
            path = evidence.write(ROOT / "zig-out/evidence", body)
            if not body["dirty"]:
                evidence.attach_note(path, body["commit"])
        else:
            path = evidence.write(ROOT / "zig-out/evidence" / phase, body)
    except SystemExit as refusal:
        say(f"the evidence record failed (exit {refusal.code}), see above")
        return status or 70
    print(path)
    return status


def summary():
    """Append every evidence record's gates to the GitHub step summary."""
    lines = ["| Gate | Result | Seconds |", "| --- | --- | ---: |"]
    for path in sorted((ROOT / "zig-out/evidence").glob("**/*.json")):
        for gate in json.loads(path.read_text())["gates"]:
            result = "passed" if gate["exit"] == 0 else f"failed ({gate['exit']})"
            lines.append(f"| `{gate['command']}` | {result} | {gate['seconds']} |")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
        output.write("\n".join(lines) + "\n")


def fetch():
    delay = os.environ.get("ZIG_FETCH_RETRY_DELAY", "5")
    if not delay.isdigit():
        say("ZIG_FETCH_RETRY_DELAY must be whole seconds")
        return 2
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        say(f"dependency acquisition attempt {attempt}/{FETCH_ATTEMPTS}")
        status = subprocess.run(
            [
                "python3",
                "tools/run-with-timeout.py",
                "--kill-after",
                "5s",
                "--heartbeat",
                "30s",
                "3m",
                "zig",
                "build",
                "--fetch=all",
            ],
            cwd=ROOT,
        ).returncode
        if status == 0 or status in INTERRUPTED or attempt == FETCH_ATTEMPTS:
            return status
        time.sleep(int(delay))


def usage(message):
    say(message)
    say("usage: run [PHASE] | compile K/N PHASE... | fetch | summary")
    return 2


def main(argv):
    verb, args = (argv[0], argv[1:]) if argv else ("", [])
    if verb == "fetch" and not args:
        return fetch()
    if verb == "summary" and not args:
        summary()
        return 0
    if verb == "run" and len(args) <= 1:
        phase = args[0] if args else None
        if phase is not None and phase not in groups.PHASES:
            return usage(f"unknown phase: {phase}")
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        run = Run()
        status = None
        for name in [phase] if phase else groups.PHASES:
            status = run.phase(name)
            if status is not None:
                break
        return finish(run, started, run.first_failure if status is None else status, phase)
    if verb == "compile" and len(args) >= 2:
        shard = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", args[0])
        if shard is None or int(shard[1]) > int(shard[2]):
            return usage("compile needs a K/N shard with 1 <= K <= N")
        unknown = [name for name in args[1:] if name not in groups.PHASES]
        if unknown:
            return usage(f"unknown phase: {unknown[0]}")
        return Run().compile(args[0], args[1:])
    return usage("expected one verb")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
