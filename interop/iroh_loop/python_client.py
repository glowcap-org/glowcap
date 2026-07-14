"""Live iroh scale proof for the Python binding: many concurrent connections
served from one readiness loop (ADR-0057), the Python sibling of the Zig
``zig build iroh-loop`` gate.

The iroh netlayer has one I/O model — an event-driven readiness loop. This gate
proves it through the binding: one Python :class:`pancake.iroh.IrohServer` runs a
single :class:`_IrohLoop` that registers the endpoint's readiness fd with the
asyncio event loop and serves every accepted connection's peer from that one
loop. Many clients dial it at once, each over its own iroh endpoint, fetch the
published greeter, and call it several times. Every reply must come back correct —
so the one server loop is provably multiplexing all the connections at once, not
serving them one at a time.

It exercises the whole loop surface live through the binding: the readiness fd,
the records ``drain_ready`` returns, non-blocking ``try_accept``, and
``try_read`` / ``try_write`` with their ``WOULD_BLOCK`` re-arming. Teardown is
non-blocking by construction, no parked read races a release.

Needs ``python3`` plus the iroh ABI companion library
(``zig build iroh-abi``); run via ``zig build python-iroh-loop``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import TRANSPORT_IROH, connect, format_peer_uri  # noqa: E402
from pancake.iroh import Reachability, listen_iroh  # noqa: E402

# Concurrent connections, each served on the one server loop; calls each makes
# before closing, several turns per connection so the proof is sustained
# multiplexing, not a single round trip. Mirrors the Zig iroh-loop gate.
NUM_CONNS = 16
CALLS_PER_CONN = 4
GREETING = "hello over the iroh loop"

ignore_port_args("python-iroh-loop")


def _greeter(verb: str, args: list):
    """The published actor: answer ``greet`` with a static greeting."""
    if verb == "greet":
        return GREETING
    return None


async def _run_accepts(server, served: list) -> None:
    """Accept every dial, publish this connection's greeter, and serve it, all
    from the server's one readiness loop. Ends when the server closes."""
    async for conn in server:
        conn.publish("greeter", _greeter)
        conn.serve()
        served.append(conn)


async def _client_once(server_id: str) -> None:
    """One client: bind its own iroh endpoint, dial the server by id alone (the
    local-discovery book resolves it), fetch the greeter, and call it
    ``CALLS_PER_CONN`` times, checking every reply."""
    locator = format_peer_uri(TRANSPORT_IROH, server_id)
    conn = await connect(locator, Reachability.LOCAL_DISCOVERY)
    try:
        greeter = await conn.fetch("greeter")
        for _ in range(CALLS_PER_CONN):
            reply = await conn.send(greeter, "greet", ["world"])
            if reply != GREETING:
                raise RuntimeError(f"wrong reply: {reply!r}")
    finally:
        await conn.close()


async def main() -> None:
    server = listen_iroh(Reachability.LOCAL_DISCOVERY)
    server_id = server.node_id
    print(f"python-iroh-loop: server endpoint id {server_id}")

    served: list = []
    accept_task = asyncio.create_task(_run_accepts(server, served))

    # Fan out all clients at once: they share nothing, so the only thing that can
    # serve them all is the one server loop multiplexing.
    results = await asyncio.gather(
        *(_client_once(server_id) for _ in range(NUM_CONNS)),
        return_exceptions=True,
    )

    # Bring the server-side connections and the server down so the gate never
    # hangs and no fd reader outlives the endpoint it watches.
    for conn in served:
        await conn.close()
    await server.close()
    await accept_task

    errors = [r for r in results if isinstance(r, BaseException)]
    if errors:
        fail("python-iroh-loop", f"{len(errors)}/{NUM_CONNS} client(s) failed; first: {errors[0]!r}")

    print(
        f"python-iroh-loop: OK, {NUM_CONNS} concurrent iroh connections, "
        f"{CALLS_PER_CONN} calls each, served from one loop over the readiness "
        f"fd + non-blocking frame I/O"
    )


if __name__ == "__main__":
    asyncio.run(main())
