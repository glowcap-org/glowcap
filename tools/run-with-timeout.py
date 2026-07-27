#!/usr/bin/env python3
"""Run one command under a portable wall-clock deadline.

macOS ships no GNU `timeout`, so the gate sequence and the conformance runner
call this instead. The exit codes a caller can act on match GNU timeout, because
ci/gates.sh reads them: 124 when the deadline fires, 126 when the command cannot
be executed, 127 when it does not exist, and 128+N when a signal kills the
child. One does not match, and it is the one nothing reads: a bad argument list
exits 2, argparse's code, where GNU uses 125. Nothing branches on it — a gate
invoked wrongly is a broken gate script either way — so it is named here rather
than translated.

Signalling matches GNU too: the child gets SIGTERM at the deadline and is only
SIGKILLed if `--kill-after` was given and it outlives that grace period.
Escalating by default would hard-kill callers that pass no grace, which is a
harsher contract than the `timeout` they replaced.

Requires `python3` on PATH. In ci/gates.sh that costs nothing — `zig build
bindings` and `bindings-fmt-check` already need it — so the only caller paying
a new dependency is the conformance runner. A shell-only shim was rejected: it
would have to re-derive 128+N signal fidelity, --kill-after escalation, and
process-group teardown, which is more shell than it saves. What it promises is
held by `zig build timeout-runner-test`, which runs the wrapper and reads the
codes a shell actually sees rather than grepping this file for them. A bare macOS
resolves `/usr/bin/python3` to the Command Line Tools stub, so install CLT
before running the gates by hand there.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys


def duration(value: str) -> float:
    units = {"s": 1.0, "m": 60.0, "h": 3600.0}
    suffix = value[-1:]
    multiplier = units.get(suffix, 1.0)
    number = value[:-1] if suffix in units else value
    try:
        seconds = float(number) * multiplier
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid duration: {value}") from exc
    if seconds < 0:
        raise argparse.ArgumentTypeError("duration must be non-negative")
    return seconds


def signal_group(process: subprocess.Popen[bytes], sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def escalate(process: subprocess.Popen[bytes], kill_after: float | None) -> None:
    """Wait for the already-signalled group, escalating to SIGKILL only when a
    grace period was asked for. Without one this waits, exactly as GNU timeout
    does — a caller wanting a bound passes `--kill-after`. Either way the child
    is reaped before the caller returns, so nothing is left running."""
    if kill_after is None:
        process.wait()
        return
    try:
        process.wait(timeout=kill_after)
    except subprocess.TimeoutExpired:
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
    parser.add_argument("timeout", type=duration)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing command")

    # Block the cancellation signals across spawn and handler installation.
    # Arriving in that window, they would kill this wrapper under the default
    # disposition and leave the child running in the session `start_new_session`
    # just gave it. The child unblocks them for itself before exec.
    relayed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    signal.pthread_sigmask(signal.SIG_BLOCK, relayed)

    def unblock_in_child() -> None:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)

    try:
        process = subprocess.Popen(
            command, start_new_session=True, preexec_fn=unblock_in_child
        )
    except FileNotFoundError as exc:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)
        print(f"run-with-timeout: {command[0]}: {exc.strerror}", file=sys.stderr)
        return 127
    except OSError as exc:
        # GNU timeout separates these: 127 is "no such command", 126 is
        # "found it, could not run it".
        signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)
        print(f"run-with-timeout: {command[0]}: {exc.strerror}", file=sys.stderr)
        return 126

    # Cancellation from a CI runner or a terminal must reach the child, which
    # is in its own session and would otherwise outlive us. Relay the signal
    # that actually arrived — a Ctrl-C the child sees as SIGTERM is a different
    # event — then apply the same escalation a deadline gets, reap, and exit
    # 128+N so the caller sees what killed it. SIGINT is relayed here rather
    # than left to raise `KeyboardInterrupt`, because returning from a handler
    # into `wait()` would let a child that ignores the signal defeat the
    # cancellation entirely.
    def relay(sig: int, _frame: object) -> None:
        signal_group(process, sig)
        escalate(process, args.kill_after)
        sys.exit(128 + sig)

    for forwarded in relayed:
        signal.signal(forwarded, relay)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, relayed)

    try:
        return shell_code(process.wait(timeout=args.timeout))
    except subprocess.TimeoutExpired:
        signal_group(process, signal.SIGTERM)
        escalate(process, args.kill_after)
        return 124


if __name__ == "__main__":
    sys.exit(main())
