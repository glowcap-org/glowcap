"""Shared helpers for Python interop client scripts."""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path


def insert_bindings_path() -> None:
    # parents: [0]=python, [1]=_common, [2]=interop, [3]=the repo root.
    root = Path(__file__).resolve().parents[3]
    sys.path.insert(0, str(root / "bindings" / "python"))


def fail(gate: str, msg: str) -> None:
    print(f"{gate} FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


def ignore_port_args(gate: str, *, argv: list[str] | None = None) -> None:
    """Reject unknown args; accept ``--port=`` for build parity without using it."""
    for arg in argv if argv is not None else sys.argv[1:]:
        if not arg.startswith("--port="):
            fail(gate, f"unknown argument '{arg}'")


def parse_port(
    gate: str,
    default: int,
    *,
    max_port: int = 65535,
    argv: list[str] | None = None,
) -> int:
    port = default
    for arg in argv if argv is not None else sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1], 10)
        else:
            fail(gate, f"unknown argument '{arg}'")
    if not 1 <= port <= max_port:
        fail(gate, f"--port must be an integer in 1..{max_port}")
    return port


async def read_swiss(
    proc: asyncio.subprocess.Process,
    gate: str,
    *,
    miss: str = "never saw the readiness line",
) -> str:
    return await _read_readiness_field(proc, gate, "swiss", miss=miss)


async def read_sturdyref_path(
    proc: asyncio.subprocess.Process,
    gate: str,
    *,
    miss: str = "never saw the sturdyref path readiness field",
) -> str:
    return await _read_readiness_field(proc, gate, "sturdyref-path", miss=miss)


async def _read_readiness_field(
    proc: asyncio.subprocess.Process,
    gate: str,
    field: str,
    *,
    miss: str,
) -> str:
    assert proc.stdout is not None
    deadline = asyncio.get_running_loop().time() + 30.0
    while asyncio.get_running_loop().time() < deadline:
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=30.0)
        if not line:
            break
        m = re.search(rb'"' + field.encode() + rb'":"([^"]+)"', line)
        if m:
            return m.group(1).decode()
    fail(gate, miss)
    raise AssertionError  # unreachable


async def accept_loop(server) -> None:
    """Serve every connection a server accepts until it closes."""
    async for conn in server:
        conn.serve()


async def await_greeter_ready(
    proc: asyncio.subprocess.Process,
    gate: str,
    *,
    miss: str = "never saw the exporter's greeter readiness line",
) -> None:
    assert proc.stdout is not None
    deadline = asyncio.get_running_loop().time() + 30.0
    while asyncio.get_running_loop().time() < deadline:
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=30.0)
        if not line:
            break
        if b'"name":"greeter"' in line:
            return
    fail(gate, miss)
