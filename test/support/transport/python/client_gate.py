"""The gate protocol a Python live client speaks: reach the bindings, fail a
named gate, and parse or ignore the port argument."""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path
from typing import NoReturn

# How long a partner has to print its readiness line: under the step's 30 s process deadline, so the gate names the miss before the build stops it.
READY_SECONDS = 20.0


def insert_bindings_path() -> None:
    # parents: python -> transport -> support -> test -> repository root.
    root = Path(__file__).resolve().parents[4]
    sys.path.insert(0, str(root / "bindings" / "python"))


def fail(gate: str, msg: str) -> NoReturn:
    print(f"{gate} FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


def ignore_port_args(gate: str, *, argv: list[str] | None = None) -> None:
    """Reject unknown args; accept ``--port=`` for build parity without using it."""
    for arg in argv if argv is not None else sys.argv[1:]:
        if not arg.startswith("--port="):
            fail(gate, f"unknown argument '{arg}'")


def parse_port(gate: str, default: int, *, max_port: int = 65535, argv: list[str] | None = None) -> int:
    port = default
    for arg in argv if argv is not None else sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1], 10)
        else:
            fail(gate, f"unknown argument '{arg}'")
    if not 1 <= port <= max_port:
        fail(gate, f"--port must be an integer in 1..{max_port}")
    return port


async def read_swiss(proc: asyncio.subprocess.Process, gate: str, *, miss: str = "never saw the readiness line") -> str:
    return await _read_readiness_field(proc, gate, "swiss", miss=miss)


async def read_sturdyref_path(
    proc: asyncio.subprocess.Process, gate: str, *, miss: str = "never saw the sturdyref path readiness field"
) -> str:
    return await _read_readiness_field(proc, gate, "sturdyref-path", miss=miss)


async def _read_readiness_field(proc: asyncio.subprocess.Process, gate: str, field: str, *, miss: str) -> str:
    pattern = rb'"' + re.escape(field.encode()) + rb'":"([^"]+)"'
    return (await _ready_line(proc, gate, pattern, miss=miss)).group(1).decode()


async def _ready_line(proc: asyncio.subprocess.Process, gate: str, pattern: bytes, *, miss: str) -> re.Match[bytes]:
    """Read the partner's stdout until a line matches ``pattern``. The deadline
    bounds the whole wait, including a read the partner never answers."""
    assert proc.stdout is not None
    loop = asyncio.get_running_loop()
    deadline = loop.time() + READY_SECONDS
    while True:
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=max(0.0, deadline - loop.time()))
        except TimeoutError:
            fail(gate, f"{miss} within {READY_SECONDS:g} s")
        if not line:
            fail(gate, f"{miss}: its output closed")
        if m := re.search(pattern, line):
            return m


async def accept_loop(server) -> None:
    """Serve every session a server accepts until it closes."""
    async for session in server:
        session.serve()


async def await_greeter_ready(
    proc: asyncio.subprocess.Process, gate: str, *, miss: str = "never saw the exporter's greeter readiness line"
) -> None:
    await _ready_line(proc, gate, rb'"name":"greeter"', miss=miss)
