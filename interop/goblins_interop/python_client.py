"""Live interop proof for the Python binding: a peer built on ``libpancake``'s C
ABI holds a *keyed* OCapN conversation with a real Spritely Goblins vat over
TCP, driven through the *same* ``connect``/``fetch``/``send`` application surface
the
cross-language demos use, so what is proven against a real Goblins vat is the
application API itself, not a bespoke handshake script.

It spawns the conformance Goblins host, learns the echo cap's swiss-num from its
NDJSON readiness line, then ``connect`` (which completes the keyed
``op:start-session`` handshake), ``fetch`` the echo cap, and ``send`` it a
positional call, asserting Goblins resolves it. Needs ``racket`` plus the
``goblins`` collection on PATH; run via ``zig build python-goblins-interop``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, insert_bindings_path, parse_port, read_swiss  # noqa: E402

insert_bindings_path()

from pancake import connect, tcp_locator  # noqa: E402

HOST = "127.0.0.1"
PORT = parse_port("python-goblins-interop", 22097)
RACKET = "/usr/local/bin/racket"
HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt"


async def converse() -> None:
    proc = await asyncio.create_subprocess_exec(
        RACKET, HOST_SCRIPT, HOST, str(PORT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        swiss = await read_swiss(proc, "python-goblins-interop", miss="never saw the Goblins echo cap readiness line")
        print(f"python-goblins-interop: goblins published echo swiss={swiss} on {HOST}:{PORT}")

        conn = await connect(tcp_locator(HOST, PORT))
        print("python-goblins-interop: session open, keyed start-session accepted by goblins")
        conn.serve()

        echo = await conn.fetch(swiss)
        print("python-goblins-interop: fetched goblins echo cap, calling it")
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
