"""Run loam-io-fault-test's Linux probe for one disk engine.

The build passes the probe and the engine name. Each case gets its own
temporary store and a five-second deadline. A failure names the exact case and
replays the probe's output, and success prints how many cases ran.

The write cases update two records that point at each other, across several
pages. Each fails one write or sync, exits without closing, and checks the
store from a fresh process. This is how a SQLite write that reported ENOSPC
after accepting bytes was caught being reported as a refusal.

The read cases load that graph in a fresh process while one read fails, and
again after the data file is cut short under the open engine. A borrow case
cuts the file after a value was returned, then reads the value. Every case must
return the exact graph or an error, and the process must survive.

Not covered: the OS file cache (only Loam's record cache starts empty),
startup, compaction, arbitrary page damage and power loss.
"""

import errno
from pathlib import Path
import subprocess
import sys
import tempfile


def run(probe, directory, *args):
    result = subprocess.run(
        [probe, args[0], directory, *map(str, args[1:])],
        cwd=directory, capture_output=True, text=True, timeout=5,
    )
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout}{result.stderr}")
    return result.stderr.strip()


def case(probe, kind, target, action, error):
    with tempfile.TemporaryDirectory(prefix="glowcap loam faults ") as directory:
        run(probe, directory, "create")
        line = run(probe, directory, "run", kind, target, action, error)
        outcome, writes, syncs, fired = line.split()
        if int(fired) != int(target != 0):
            raise AssertionError(f"injection not reached: {line}")
        if target == 0 and outcome != "committed":
            raise AssertionError(f"positive control did not commit: {line}")
        run(probe, directory, "verify", outcome)
        return int(writes), int(syncs)


def read_case(probe, *args):
    with tempfile.TemporaryDirectory(prefix="glowcap loam faults ") as directory:
        run(probe, directory, "create")
        result = subprocess.run(
            [probe, args[0], directory, *map(str, args[1:])],
            cwd=directory, capture_output=True, text=True, timeout=5,
        )
        if result.returncode < 0:
            raise AssertionError(f"{args}: killed by signal {-result.returncode}: {result.stderr}")
        if result.returncode:
            raise AssertionError(f"{args}: {result.stdout}{result.stderr}")
        outcome, reads, fired = result.stderr.strip().split()
        if outcome not in ("intact", "refused"):
            raise AssertionError(f"unexpected read outcome: {outcome}")
        # A failed read changes nothing on disk. A shrunk file is damaged.
        if args[0] == "read":
            run(probe, directory, "verify", "unchanged")
        return outcome, int(reads), int(fired)


def reads(probe, engine):
    outcome, count, fired = read_case(probe, "read", 0, 0, 0)
    if outcome != "intact" or fired:
        raise AssertionError(f"positive read control refused: {outcome}")
    if count == 0:
        raise AssertionError(f"{engine} read interception missing")
    cases = 0
    for target in range(1, count + 1):
        for action, error in [(1, errno.EIO), (2, errno.EIO), (3, 0), (4, errno.EIO), (5, errno.EIO)]:
            _, _, fired = read_case(probe, "read", target, action, error)
            if not fired:
                raise AssertionError(f"read {target} action {action}: injection not reached")
            cases += 1
    if read_case(probe, "borrow", 0)[0] != "intact":
        raise AssertionError("borrowed data changed after file truncation")
    cuts = 0
    for length in range(0, 1 << 20, 4096):
        outcome, _, _ = read_case(probe, "shrink", length)
        cuts += 1
        if outcome == "intact":
            break
    else:
        raise AssertionError("file cuts never reached an intact graph")
    return count, cases, cuts


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("lmdb", "sqlite"):
        raise SystemExit("expected one probe executable and engine name (lmdb or sqlite)")
    probe = str(Path(sys.argv[1]).resolve(strict=True))
    writes, syncs = case(probe, 0, 0, 0, 0)
    if not writes or not syncs:
        raise AssertionError(f"syscall interception missing: writes={writes} syncs={syncs}")
    cases = 0
    for kind, count in ((1, writes), (2, syncs)):
        for target in range(1, count + 1):
            # Before/after the syscall, once or persistently through rollback.
            actions = [(action, error) for action in (1, 2, 4, 5) for error in (errno.EIO, errno.ENOSPC)]
            if kind == 1:
                actions.append((3, 0))
            for action, error in actions:
                try:
                    case(probe, kind, target, action, error)
                except Exception as exc:
                    raise AssertionError(f"kind={kind} target={target} action={action} errno={error}: {exc}") from exc
                cases += 1
    read_count, read_cases, cuts = reads(probe, sys.argv[2])
    read_report = f"{read_count} reads, {read_cases} injected read failures"
    print(f"{Path(probe).name}: {writes} writes, {syncs} syncs, {cases} injected failures passed;"
          f" {read_report}; {cuts} file cuts and a borrowed value checked without process loss")


if __name__ == "__main__":
    main()
