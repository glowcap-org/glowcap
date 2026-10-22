#!/usr/bin/env python3
"""Write the evidence record for one run of the CI gate sequence.

Caller: `ci/gates.sh`, from its exit trap, after it has entered the
repository root. The record says what ran, on what, and how it ended.

    --gates <tsv>      one row per gate: exit, seconds, command, tab-separated
    --started <iso>    when the sequence began, UTC
    --outcome <word>   passed or failed
    --out <dir>        where the record lands (default zig-out/evidence)
    --note             also attach the record to HEAD under refs/notes/evidence
                       when the checkout is clean

The record is `<out>/<commit>.json`, or `<commit>-dirty.json` when the
working tree the gates ran on differs from the commit's tree, and its path is
printed. `tree` is the hash of that working tree (tracked and unignored
files), so a record names what was checked, never only what was committed. A malformed row or a missing
input exits 2 and writes nothing. A git or filesystem refusal before the
record is written exits 1. A note refusal after it exits 3, naming the
record that was written.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn

NAME = "glowcap-evidence"
FORMAT = 1
NOTES_REF = "refs/notes/evidence"
PIN_FILES = (".devcontainer/pins.sh", ".devcontainer/checksums.sh")
SUBMODULE_STATES = {"": "checked-out", "-": "missing", "+": "moved", "U": "conflicted"}


def fail(message: str, status: int) -> NoReturn:
    print(f"{NAME}: {message}", file=sys.stderr)
    raise SystemExit(status)


def git(*args: str, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        fail(f"git {' '.join(args)}: {result.stderr.strip()}", 1)
    return result.stdout.strip()


def attach_note(path: Path, commit: str) -> None:
    result = subprocess.run(
        ["git", "notes", f"--ref={NOTES_REF}", "add", "-f", "-F", str(path), commit],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail(f"record written at {path}; note not attached: {result.stderr.strip()}", 3)


def parse_gates(path: Path) -> list[dict[str, Any]]:
    try:
        text = path.read_text()
    except OSError as error:
        fail(f"cannot read the gate rows: {error}", 2)
    gates: list[dict[str, Any]] = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            fail(f"gate row {number} does not have three fields", 2)
        exit_text, seconds_text, command = parts
        try:
            gates.append({"command": command, "exit": int(exit_text), "seconds": int(seconds_text)})
        except ValueError:
            fail(f"gate row {number} has a non-integer exit or duration", 2)
    return gates


def parse_started(raw: str) -> str:
    try:
        dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        fail(f"--started must be an ISO 8601 instant, not {raw!r}", 2)
    return raw


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        # A checkout without the devcontainer pins has no toolchain pin to name.
        return None


def zig_version() -> str | None:
    zig = shutil.which("zig")
    if zig is None:
        return None
    result = subprocess.run([zig, "version"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def submodules() -> list[dict[str, str]]:
    rows = []
    for line in git("submodule", "status").splitlines():
        line = line.strip()
        if not line:
            continue
        mark = ""
        if line[0] in SUBMODULE_STATES:
            mark, line = line[0], line[1:]
        commit, path = line.split()[:2]
        rows.append({"path": path, "commit": commit, "state": SUBMODULE_STATES[mark]})
    return rows


def working_tree() -> str:
    """Hash the working tree as git would commit it, without touching the index."""
    index = git("rev-parse", "--git-path", "index")
    with tempfile.NamedTemporaryFile(prefix="evidence-index-") as scratch:
        # Git uses the index timestamp to detect same-size edits whose stat
        # data still matches (racy-clean entries). A newer copy timestamp
        # would suppress that content check on coarse-timestamp filesystems.
        shutil.copy2(index, scratch.name)
        env = dict(os.environ, GIT_INDEX_FILE=scratch.name)
        git("add", "-A", "--", ".", env=env)
        return git("write-tree", env=env)


def record(gates: list[dict[str, Any]], started: str, outcome: str) -> dict[str, Any]:
    commit = git("rev-parse", "HEAD")
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    tree = working_tree()
    return {
        "format": FORMAT,
        "outcome": outcome,
        "started": started,
        "finished": utc_now(),
        "commit": commit,
        "tree": tree,
        "branch": None if branch == "HEAD" else branch,
        "dirty": tree != git("rev-parse", "HEAD^{tree}"),
        "submodules": submodules(),
        "toolchain": {
            "zig": zig_version(),
            "pins": {name: digest(Path(name)) for name in PIN_FILES},
        },
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            # Gate durations mean little without the machine size they ran on.
            "cpus": len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count(),
            "memory_bytes": os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"),
        },
        "gates": gates,
    }


def write(out: Path, body: dict[str, Any]) -> Path:
    suffix = "-dirty" if body["dirty"] else ""
    # Absolute, so the printed path means the same thing to any caller.
    path = out.resolve() / f"{body['commit']}{suffix}.json"
    try:
        out.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(body, indent=2) + "\n")
    except OSError as error:
        fail(f"cannot write {path}: {error}", 1)
    return path


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog=NAME, description=__doc__.splitlines()[0])
    parser.add_argument("--gates", required=True, type=Path)
    parser.add_argument("--started", required=True, type=parse_started)
    parser.add_argument("--outcome", required=True, choices=("passed", "failed"))
    parser.add_argument("--out", type=Path, default=Path("zig-out/evidence"))
    parser.add_argument("--note", action="store_true")
    args = parser.parse_args(argv)

    gates = parse_gates(args.gates)
    body = record(gates, args.started, args.outcome)
    path = write(args.out, body)
    if args.note and not body["dirty"]:
        attach_note(path, body["commit"])
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
