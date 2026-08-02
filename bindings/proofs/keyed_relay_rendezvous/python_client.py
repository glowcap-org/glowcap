"""Per-binding keyed-relay rendezvous proof: the Python binding cold-dials a
non-listening peer by its key designator through the reference relay's
rendezvous bridge (ADR-0088). The core classifies the locator as the
``rendezvous`` dial shape; the binding opens the WebSocket leg its host's
``rendezvous_url`` names and runs the keyed handshake end to end.

Run via ``zig build python-keyed-relay-rendezvous`` (the harness passes
``<relay-port> <designator>``). Needs the optional ``websockets`` extra, which
the build step supplies with ``uv run --with websockets``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "interop" / "_common" / "python"))
from helpers import fail, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import Host, connect  # noqa: E402


async def main() -> None:
    if len(sys.argv) < 3:
        fail("keyed-relay-rendezvous", "usage: python_client.py <relay-port> <designator>")
    # The harness appends the two; a pinned -Dport flag may sit before them.
    relay_port, designator = int(sys.argv[-2]), sys.argv[-1]

    host = Host()
    host.rendezvous_url = (
        lambda peer_id: f"ws://127.0.0.1:{relay_port}/relay?rendezvous={peer_id}"
    )
    conn = await connect(f"ocapn://{designator}.keyed-relay", host=host)
    try:
        greeter = await conn.fetch("greeter")
        reply = await conn.send(greeter, "greet", ["python"])
        expected = "hello python, cold-dialed by rendezvous"
        if reply != expected:
            fail("keyed-relay-rendezvous", f"unexpected greeting: {reply!r}")
    finally:
        await conn.close()
    print(
        "PASS: the Python binding cold-dialed a registered peer by rendezvous — "
        "the core classified the keyed-relay locator, the host's configured "
        "relay mapping opened the bridge, and the keyed session answered"
    )


asyncio.run(main())
