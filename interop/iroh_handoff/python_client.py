"""Live three-party handoff over iroh, all in the Python binding, the
Python sibling of the Deno ``zig build demo-rooms-dm-iroh`` proof and the iroh
companion of ``python-goblins-handoff``. It proves both halves of an iroh handoff
through the binding's own surface: the gifter mints a ``desc:handoff-give`` whose
exporter location names an iroh endpoint by a ``direct-addresses`` dial hint, and
the recipient redeems it transparently by dialing that endpoint directly over
encrypted QUIC.

Topology — three iroh endpoints (separate identities) in one process, the
relay-less ``DIRECT`` posture on loopback, so the gate is deterministic and
flake-free (no discovery service, no network):
  Exporter  binds an iroh endpoint and publishes a node-giftable ``greeter``.
  Gifter    binds its own endpoint, dials the exporter (sharing one node
            identity), fetches the greeter, records the exporter's dialable URI
            as the give's exporter location, and publishes an ``introducer`` that
            returns the greeter.
  Recipient binds its own endpoint, dials the gifter, asks the introducer for the
            greeter, transparently redeems the give by dialing the exporter
            directly, and calls it — the reply must echo its name.

Returning the exporter's greeter (home = gifter↔exporter) on the recipient's
connection trips the transparent gifter; the recipient's ``send`` resolves to an
ordinary capability whose calls route straight to the exporter. The proof is the
greeter's reply carrying the name the recipient sent.

Needs ``python3`` plus the iroh ABI companion library (``zig build iroh-abi``);
run via ``zig build python-iroh-handoff``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import (  # noqa: E402
    HINT_DIRECT_ADDRESSES,
    Ref,
    TRANSPORT_IROH,
    connect,
    Locator,
    format_peer_uri,
)
from pancake.iroh import (  # noqa: E402
    IrohConfig,
    Reachability,
    listen_iroh,
)

NAME = "python-iroh-carol"

ignore_port_args("python-iroh-handoff")


async def accept_loop_with_served(server, served: list) -> None:
    """Serve every session the server accepts for the life of the run. Ends
    when the server closes and ``__anext__`` raises ``StopAsyncIteration``."""
    async for session in server:
        session.serve()
        served.append(session)


async def dialable(server) -> "tuple[str, str]":
    """An iroh endpoint reports its direct addresses asynchronously after bind;
    wait for at least one before reading the dialable id+addresses, a give with
    no direct-addresses hint is not dialable under the relay-less Direct posture."""
    for _ in range(1000):
        addrs = server.direct_addresses
        if addrs:
            return server.node_id, addrs
        await asyncio.sleep(0.02)
    fail("python-iroh-handoff", "timed out waiting for an endpoint's direct addresses")
    raise AssertionError  # unreachable


def greeter(verb: str, args: list):
    """The published actor: answer ``greet`` by echoing the caller's name."""
    if verb == "greet":
        name = args[0] if args else ""
        return f"hello {name} over iroh handoff"
    return None


async def run() -> None:
    # ── Exporter: a node-giftable greeter on its own endpoint ────────────────────
    exporter = await listen_iroh(IrohConfig(Reachability.DIRECT))
    exporter.host.publish_giftable("greeter", greeter)
    exporter_id, exporter_addrs = await dialable(exporter)
    exporter_served: list = []
    exporter_task = asyncio.create_task(accept_loop_with_served(exporter, exporter_served))
    print(f"python-iroh-handoff: exporter published greeter on {exporter_id}")

    # ── Gifter: dials the exporter under one identity, re-gifts the greeter ───────
    gifter = await listen_iroh(IrohConfig(Reachability.DIRECT))
    gifter_id, gifter_addrs = await dialable(gifter)
    exporter_uri = format_peer_uri(
        TRANSPORT_IROH, exporter_id, {HINT_DIRECT_ADDRESSES: exporter_addrs}
    )
    to_exporter = await connect(exporter_uri, Reachability.DIRECT, host=gifter.host)
    greeter_ref = await to_exporter.fetch("greeter")
    # The exporter's own signed session record names it by node id alone — not
    # dialable under the relay-less Direct posture — so record its full dialable
    # location (id + direct-addresses) as the give's exporter location.
    to_exporter.set_exporter_locator(Locator(
        "iroh",
        exporter_id,
        {HINT_DIRECT_ADDRESSES: exporter_addrs},
    ))

    def introducer(verb: str, args: list):
        if verb == "get-greeter":
            return greeter_ref
        return None

    gifter.host.publish_giftable("introducer", introducer)
    gifter_served: list = []
    gifter_task = asyncio.create_task(accept_loop_with_served(gifter, gifter_served))
    print(f"python-iroh-handoff: gifter published introducer on {gifter_id}")

    # ── Recipient: dials the gifter, redeems the give by dialing the exporter ─────
    gifter_uri = format_peer_uri(
        TRANSPORT_IROH, gifter_id, {HINT_DIRECT_ADDRESSES: gifter_addrs}
    )
    recipient = await connect(gifter_uri, Reachability.DIRECT)
    introducer_ref = await recipient.fetch("introducer")
    granted = await recipient.send(introducer_ref, "get-greeter", [])
    if not isinstance(granted, Ref):
        fail("python-iroh-handoff", f"introduction did not redeem to a capability: {granted!r}")
    print("python-iroh-handoff: recipient redeemed the give, got the greeter as an ordinary ref")

    reply = await recipient.send(granted, "greet", [NAME])
    if not isinstance(reply, str) or NAME not in reply:
        fail("python-iroh-handoff", f"greeter reply did not carry the name back: {reply!r}")
    print(f"python-iroh-handoff: greeter replied: {reply}")

    print(
        "python-iroh-handoff OK: the Python binding minted an iroh handoff give and "
        "redeemed it by dialing the exporter directly over encrypted QUIC"
    )

    # Teardown: close the dialing connections, then every accepted connection,
    # then the servers, closing a server ends its accept loop, which we await so
    # no readiness fd reader outlives the endpoint it watches.
    await recipient.close()
    await to_exporter.close()
    for session in (*exporter_served, *gifter_served):
        await session.close()
    await exporter.close()
    await gifter.close()
    await exporter_task
    await gifter_task


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(run(), timeout=90.0))
