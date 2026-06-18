"""Live three-party handoff with the Python binding as the recipient (Carol),
proving the binding redeems a ``desc:handoff-give`` transparently — the same
``connect``/``fetch``/``send`` application surface the demos use, no bespoke
handoff choreography in the app.

It spawns the conformance Goblins introducer host (Alice on PORT, Bob the
exporter on PORT+1), learns Alice's introducer swiss-num from its NDJSON
readiness line, then:
  1. ``connect`` to Alice and ``fetch`` the introducer.
  2. ``send(introducer, "get-greeter")``. Alice hands back Bob's greeter as a
     three-party handoff give. The binding's machine redeems it: it dials Bob
     directly (keyed with the *same* identity Alice saw), withdraws the gift, and
     resolves the send to an ordinary capability — the app never sees the give or
     the second connection.
  3. ``send(greeter, "", ["pancake-carol"])``. The bytes go straight to Bob; the
     reply must carry the name back, proving data integrity end to end.

Needs ``racket`` plus the ``goblins`` collection on PATH; run via
``zig build python-goblins-handoff``.
"""

from __future__ import annotations

import asyncio
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bindings" / "python"))

from pancake import Ref, connect, tcp_locator  # noqa: E402

HOST = "127.0.0.1"
# Alice's port; Bob (the exporter) listens on PORT+1. --port=N (from
# `zig build python-goblins-handoff -Dport=N`) moves the pair when 22114 is taken.
PORT = 22114
for _arg in sys.argv[1:]:
    if _arg.startswith("--port="):
        PORT = int(_arg.split("=", 1)[1], 10)
    else:
        print(f"python-goblins-handoff: unknown argument '{_arg}'", file=sys.stderr)
        raise SystemExit(2)
if not 1 <= PORT <= 65534:
    print("python-goblins-handoff: --port must be an integer in 1..65534 (bob listens on port+1)", file=sys.stderr)
    raise SystemExit(2)
RACKET = "/usr/local/bin/racket"
HOST_SCRIPT = "conformance/goblins-peer/racket/handoff-introducer-host.rkt"


def fail(msg: str) -> None:
    print(f"python-goblins-handoff FAILED: {msg}", file=sys.stderr)
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
    fail("never saw the introducer readiness line")
    raise AssertionError  # unreachable


async def converse() -> None:
    proc = await asyncio.create_subprocess_exec(
        RACKET, HOST_SCRIPT, str(PORT), str(PORT + 1),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        swiss = await read_swiss(proc)
        print(f"python-goblins-handoff: alice published introducer swiss={swiss} on {HOST}:{PORT}")

        # `connect` completes the keyed handshake; the machine's retained identity
        # is the recipient key the gift Alice deposits will name.
        conn = await connect(tcp_locator(HOST, PORT))
        print("python-goblins-handoff: session open (recipient -> alice)")
        conn.serve()

        introducer = await conn.fetch(swiss)
        print("python-goblins-handoff: enlivened alice's introducer, asking for the greeter")

        # The introduction: Alice returns Bob's greeter as a handoff give. The
        # binding redeems it transparently, so this resolves to an ordinary Ref.
        greeter = await conn.send(introducer, "get-greeter", [])
        if not isinstance(greeter, Ref):
            fail(f"introduction did not redeem to a capability: {greeter!r}")
        print("python-goblins-handoff: introduction redeemed — got the greeter as an ordinary ref")

        # Call the greeter. The send routes straight to Bob (the exporter); the
        # reply must echo the name we sent, so the handoff proves data integrity.
        reply = await conn.send(greeter, "", ["pancake-carol"])
        if not isinstance(reply, str) or "pancake-carol" not in reply:
            fail(f"greeter reply did not carry the name back: {reply!r}")
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
