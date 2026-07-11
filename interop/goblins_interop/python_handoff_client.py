"""Live three-party handoff with the Python binding as the recipient (Carol),
proving the binding redeems a ``desc:handoff-give`` transparently, the same
``connect``/``fetch``/``send`` application surface the demos use, no bespoke
handoff choreography in the app.

It spawns the conformance Goblins introducer host (Alice on PORT, Bob the
exporter on PORT+1), learns Alice's introducer swiss-num from its NDJSON
readiness line, then:
  1. ``connect`` to Alice and ``fetch`` the introducer.
  2. ``send(introducer, "get-greeter")``. Alice hands back Bob's greeter as a
     three-party handoff give. The binding's machine redeems it: it dials Bob
     directly (keyed with the *same* identity Alice saw), withdraws the gift, and
     resolves the send to an ordinary capability, the app never sees the give or
     the second connection.
  3. ``send(greeter, "", ["pancake-carol"])``. The bytes go straight to Bob; the
     reply must carry the name back, proving data integrity end to end.

Needs ``racket`` plus the ``goblins`` collection on PATH; run via
``zig build python-goblins-handoff``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, insert_bindings_path, parse_port, read_swiss  # noqa: E402

insert_bindings_path()

from pancake import Ref, connect, tcp_locator  # noqa: E402

HOST = "127.0.0.1"
PORT = parse_port("python-goblins-handoff", 22114, max_port=65534)
RACKET = "/usr/local/bin/racket"
HOST_SCRIPT = "conformance/goblins-peer/racket/handoff-introducer-host.rkt"


async def converse() -> None:
    proc = await asyncio.create_subprocess_exec(
        RACKET, HOST_SCRIPT, str(PORT), str(PORT + 1),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        swiss = await read_swiss(proc, "python-goblins-handoff", miss="never saw the introducer readiness line")
        print(f"python-goblins-handoff: alice published introducer swiss={swiss} on {HOST}:{PORT}")

        conn = await connect(tcp_locator(HOST, PORT))
        print("python-goblins-handoff: session open (recipient -> alice)")
        conn.serve()

        introducer = await conn.fetch(swiss)
        print("python-goblins-handoff: enlivened alice's introducer, asking for the greeter")

        greeter = await conn.send(introducer, "get-greeter", [])
        if not isinstance(greeter, Ref):
            fail("python-goblins-handoff", f"introduction did not redeem to a capability: {greeter!r}")
        print("python-goblins-handoff: introduction redeemed, got the greeter as an ordinary ref")

        reply = await conn.send(greeter, "", ["pancake-carol"])
        if not isinstance(reply, str) or "pancake-carol" not in reply:
            fail("python-goblins-handoff", f"greeter reply did not carry the name back: {reply!r}")
        print(f"python-goblins-handoff: greeter replied: {reply}")

        print(
            "python-goblins-handoff OK: the Python binding redeemed a three-party "
            "handoff from live Goblins and called the exporter directly"
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
