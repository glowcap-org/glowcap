#!/usr/bin/env python3
"""Run one command under a portable wall-clock deadline.

macOS ships no GNU `timeout`, so the gate sequence and the conformance runner
call this instead. The exit codes a caller can act on match GNU timeout, because
ci/gates.sh reads them: 124 when the deadline fires, 126 when the command cannot
be executed, 127 when it does not exist, and 128+N when a signal kills the
child. One does not match, and it is the one nothing reads: a bad argument list
exits 2, argparse's code, where GNU uses 125. Nothing branches on it. A gate
invoked incorrectly is broken either way, so the difference is named here
rather than translated.

Signalling matches GNU too: the child gets SIGTERM at the deadline and is only
SIGKILLed if `--kill-after` was given and it outlives that grace period.
Escalating by default would hard-kill callers that pass no grace, which is a
harsher contract than the `timeout` they replaced.

Unlike GNU, a fired deadline says so on stderr, after any replayed output. A
build step that runs many of these at once otherwise shows a stopped child as
a bare failure, indistinguishable from one that failed on its own.

`--heartbeat <duration>` reports elapsed time while the child is running.
It does not extend the deadline or imply that the child is making progress.

A deadline failure is final. Retrying a timed-out test cannot distinguish a
scheduling stall from a defect, so a later pass must not qualify the check.

A pass that used more than half its deadline says so on
stderr. The slowest machine that runs a step sets its budget, and a pass with
less than twice its time in hand is a failure waiting for a slower runner.

`--quiet-success` spools the child's combined output to a temporary file. A
failure replays it exactly. A successful check emits nothing.

Requires `python3` on PATH. CI already needs it for `zig build bindings` and
`bindings-fmt-check`. The conformance runner is the only caller that adds this
dependency. A shell-only shim would have to reimplement 128+N signal fidelity,
`--kill-after` escalation, and process-group teardown, so Python keeps the
contract smaller. `zig build timeout-runner-test` checks the wrapper by reading
the codes a shell actually sees. A bare macOS resolves `/usr/bin/python3` to the
Command Line Tools stub, so install CLT before running the gates by hand there.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from typing import IO

# A pass that used more than 1/HEADROOM of its deadline warns.
HEADROOM = 2


def duration(value: str) -> float:
    units = {"s": 1.0, "m": 60.0, "h": 3600.0}
    suffix = value[-1:]
    multiplier = units.get(suffix, 1.0)
    number = value[:-1] if suffix in units else value
    try:
        seconds = float(number) * multiplier
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid duration: {value}") from exc
    if seconds < 0 or not math.isfinite(seconds):
        raise argparse.ArgumentTypeError("duration must be finite and non-negative")
    return seconds


def signal_group(process: subprocess.Popen[bytes], sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def escalate(process: subprocess.Popen[bytes], kill_after: float | None) -> None:
    """Wait for the already-signalled group, escalating to SIGKILL only when a
    grace period was asked for. Without one this waits, exactly as GNU timeout
    does. A caller wanting a bound on the whole group passes `--kill-after`.
    Either way the immediate child is reaped before the caller returns."""
    if kill_after is None:
        process.wait()
        return
    deadline = time.monotonic() + kill_after
    try:
        process.wait(timeout=kill_after)
    except subprocess.TimeoutExpired:
        pass
    # The group leader can exit before descendants that ignored the signal.
    # Its wait status does not prove that the process group has drained.
    while time.monotonic() < deadline:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    signal_group(process, signal.SIGKILL)
    process.wait()


def shell_code(returncode: int) -> int:
    """A child's wait status as a shell reports it: 128+N when a signal killed
    it. Python hands back -N there, and `sys.exit(-N)` would truncate to an
    unrelated code, so ci/gates.sh would stop recognizing 137 (SIGKILL)."""
    return 128 - returncode if returncode < 0 else returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kill-after", type=duration, default=None)
    parser.add_argument(
        "--quiet-success",
        action="store_true",
        help="replay combined child output only when the command fails",
    )
    parser.add_argument("--heartbeat", type=duration, default=0)
    parser.add_argument("timeout", type=duration)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing command")

    # Block the cancellation signals across the spawn. Arriving in that
    # window, they would find no child to relay to and leave one running in the
    # session `start_new_session` just gave it. The child unblocks them for
    # itself before exec.
    relayed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    signal.pthread_sigmask(signal.SIG_BLOCK, relayed)
    process: subprocess.Popen[bytes] | None = None
    capture: IO[bytes] | None = None
    finishing = False

    def finish(code: int) -> int:
        nonlocal finishing
        if capture is None:
            return code
        if finishing:
            return code
        finishing = True
        try:
            if code != 0:
                capture.flush()
                capture.seek(0)
                shutil.copyfileobj(capture, sys.stderr.buffer)
                sys.stderr.buffer.flush()
        finally:
            capture.close()
        return code

    def unblock_in_child() -> None:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)

    # Cancellation from a CI runner or a terminal must reach the child, which
    # is in its own session and would otherwise outlive us. Relay the signal
    # that arrived. A Ctrl-C the child sees as SIGTERM is a different
    # event. Then apply the same escalation a deadline gets, reap, and exit
    # 128+N so the caller sees what killed it. SIGINT is relayed here rather
    # than left to raise `KeyboardInterrupt`, because returning from a handler
    # into `wait()` would let a child that ignores the signal defeat the
    # cancellation entirely.
    def relay(sig: int, _frame: object) -> None:
        if process is not None:
            signal_group(process, sig)
            escalate(process, args.kill_after)
        sys.exit(finish(128 + sig))

    for forwarded in relayed:
        signal.signal(forwarded, relay)

    capture = tempfile.TemporaryFile() if args.quiet_success else None
    try:
        process = subprocess.Popen(
            command,
            start_new_session=True,
            preexec_fn=unblock_in_child,
            stdout=capture,
            stderr=subprocess.STDOUT if capture is not None else None,
        )
    except FileNotFoundError as exc:
        print(f"run-with-timeout: {command[0]}: {exc.strerror}", file=sys.stderr)
        return finish(127)
    except OSError as exc:
        # GNU timeout separates these: 127 is "no such command", 126 is
        # "found it, could not run it".
        print(f"run-with-timeout: {command[0]}: {exc.strerror}", file=sys.stderr)
        return finish(126)
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)

    started = time.monotonic()
    deadline = started + args.timeout
    try:
        while True:
            remaining = max(0, deadline - time.monotonic())
            interval = min(remaining, args.heartbeat) if args.heartbeat else remaining
            try:
                code = shell_code(process.wait(timeout=interval))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise
                print(f"run-with-timeout: {shlex.join(command)} still running "
                      f"({time.monotonic() - started:.0f}s elapsed, "
                      f"{args.timeout:g}s deadline)", file=sys.stderr, flush=True)
    except subprocess.TimeoutExpired:
        signal_group(process, signal.SIGTERM)
        escalate(process, args.kill_after)
        signal.pthread_sigmask(signal.SIG_BLOCK, relayed)
        process = None
        code = finish(124)
        print(f"run-with-timeout: {command[0]} reached its {args.timeout:g}s deadline "
              "and was stopped", file=sys.stderr, flush=True)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)
        return code
    elapsed = time.monotonic() - started
    signal.pthread_sigmask(signal.SIG_BLOCK, relayed)
    process = None
    signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)
    code = finish(code)
    if code == 0:
        report_headroom(command, elapsed, args.timeout)
    return code


def report_headroom(command: list[str], elapsed: float, timeout: float) -> None:
    """A pass is not quiet about a deadline it nearly missed. The slowest machine
    that runs a step sets its budget, and CI runners are slower than a
    workstation, so a pass that used most of its deadline is a failure on the
    way."""
    said = shlex.join(command)
    if timeout > 0 and elapsed * HEADROOM > timeout:
        print(f"run-with-timeout: {said} passed in {elapsed:.0f}s of its {timeout:g}s deadline; "
              f"a runner {HEADROOM}x slower would stop it", file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
