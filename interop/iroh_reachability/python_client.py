"""Live real-internet iroh reachability proof in the Python binding, the binding
sibling of the Zig ``iroh-reachability`` driver. Two iroh endpoints in one
process reach each other by node id ALONE over n0's public relays and DNS/pkarr
discovery: no direct-address hints, no in-process address book.

Both endpoints bind with the ``DISCOVERY`` posture. The server publishes its node
info to pkarr on bind; the client dials the server by its 64-hex node id with an
empty hint set, so a session that opens proves the dial was resolved over real
discovery infrastructure and carried over a real relay / hole-punched path, not
hinted, not loopback-booked. The client's dial rides the ``connect(locator)``
``DISCOVERY`` retry that settles while the publish propagates.

Not a hermetic gate. This step touches public n0 infrastructure
(``*.relay.iroh.network``, ``dns.iroh.link``), and discovery-propagation timing
makes it unsuitable for ``zig build check``. It runs only as the opt-in
``zig build python-iroh-reachability``, the same posture as
``python-iroh-loop``, so it can never make ``check`` flaky.

Needs ``python3`` plus the iroh ABI companion library (``zig build iroh-abi``)
and a live internet connection; run via ``zig build python-iroh-reachability``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import Runtime, format_peer_uri, TRANSPORT_IROH  # noqa: E402
from pancake.iroh import (  # noqa: E402
    IrohConfig,
    Reachability,
    listen,
    provider,
)

NAME = "python-iroh-world"

ignore_port_args("python-iroh-reachability")


def greeter(verb: str, args: list):
    """The published actor: answer ``greet`` by echoing the caller's name."""
    if verb == "greet":
        name = args[0] if args else ""
        return f"hello {name} over iroh discovery"
    return None


async def accept_loop(server, served: list) -> None:
    """Serve every session the server accepts for the life of the run. Ends
    when the server closes and ``__anext__`` raises ``StopAsyncIteration``."""
    async for session in server:
        session.serve()
        served.append(session)


async def run() -> None:
    # ── Server: a giftable greeter, dialable by node id alone over discovery ──────
    server = await listen(IrohConfig(Reachability.DISCOVERY))
    server.host.publish_giftable("greeter", greeter)
    server_id = server.node_id
    served: list = []
    server_task = asyncio.create_task(accept_loop(server, served))
    print(
        f"python-iroh-reachability: server published greeter on {server_id} "
        "(pkarr-published; no direct addrs shared)"
    )

    # ── Client: dial by node id ALONE — empty hints — over real n0 discovery ──────
    runtime = await Runtime.open(provider=provider(IrohConfig(Reachability.DISCOVERY)))
    client = await runtime.connect(format_peer_uri(TRANSPORT_IROH, server_id))
    print("python-iroh-reachability: client dialed by node id alone and opened the keyed session")

    greeter_ref = await client.fetch("greeter")
    reply = await client.send(greeter_ref, "greet", [NAME])
    if not isinstance(reply, str) or NAME not in reply:
        fail("python-iroh-reachability", f"greeter reply did not carry the name back: {reply!r}")
    print(f"python-iroh-reachability: greeter replied: {reply}")

    print(
        "python-iroh-reachability OK: the Python binding reached a peer by node id alone "
        "over n0 relays + DNS/pkarr discovery, no direct-address hints"
    )

    # Teardown: close the dialing connection, then every accepted connection, then
    # the server, closing a server ends its accept loop, which we await so no
    # readiness fd reader outlives the endpoint it watches.
    await client.close()
    await runtime.close()
    for session in served:
        await session.close()
    await server.close()
    await server_task


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(run(), timeout=120.0))
