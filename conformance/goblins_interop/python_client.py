"""Live interop proof for the Python binding: a peer built on ``libpancake``'s C
ABI holds a *keyed* OCapN conversation with a real Spritely Goblins vat over TCP
— driven through the *same* ``connect``/``fetch``/``send`` application surface the
cross-language demos use, so what is proven against a real Goblins vat is the
application API itself, not a bespoke handshake script.

It spawns the conformance Goblins host, learns the echo cap's swiss-num from its
NDJSON readiness line, then ``connect`` (which completes the keyed
``op:start-session`` handshake), ``fetch`` the echo cap, and ``send`` it a
positional call — asserting Goblins resolves it. Needs ``racket`` plus the
``goblins`` collection on PATH; run via ``zig build python-goblins-interop``.
"""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bindings" / "python"))

from pancake import connect  # noqa: E402

HOST = "127.0.0.1"
PORT = 22097
RACKET = "/usr/local/bin/racket"
HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt"


def fail(msg: str) -> None:
    print(f"python-goblins-interop FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


async def read_swiss(proc: asyncio.subprocess.Process) -> str:
    assert proc.stdout is not None
    deadline = asyncio.get_running_loop().time() + 30.0
    while asyncio.get_running_loop().time() < deadline:
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=30.0)
        if not line:
            break
        m = re.search(rb'"swiss":"([^"]+)"', line)
        if m:
            return m.group(1).decode()
    fail("never saw the Goblins echo cap readiness line")
    raise AssertionError  # unreachable


async def converse() -> None:
    proc = await asyncio.create_subprocess_exec(
        RACKET, HOST_SCRIPT, HOST, str(PORT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        swiss = await read_swiss(proc)
        print(f"python-goblins-interop: goblins published echo swiss={swiss} on {HOST}:{PORT}")

        # `connect` completes the keyed handshake; reaching here means Goblins
        # accepted our signed start-session and we accepted its.
        conn = await connect(HOST, PORT)
        print("python-goblins-interop: session open, keyed start-session accepted by goblins")
        conn.serve()

        echo = await conn.fetch(swiss)
        print("python-goblins-interop: fetched goblins echo cap, calling it")

        # Goblins invokes a cap positionally (no method symbol), so verb is "".
        await conn.send(echo, "", [b"pancake-ping"])

        print(
            "python-goblins-interop OK: keyed handshake + bootstrap fetch + echo "
            "deliver/resolve with live Goblins"
        )
        await conn.close()
    finally:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        await proc.wait()


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(converse(), timeout=90.0))
