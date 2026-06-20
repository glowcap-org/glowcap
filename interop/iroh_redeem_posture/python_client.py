"""Hermetic proof that a recipient's **configured redeem posture** governs how a
*hint-less* iroh handoff give is dialed (ADR-0009), all in the Python binding,
the sibling of the Rust/Racket ``iroh_redeem_posture`` clients.

A give whose exporter location names the exporter by **node id alone** (no
``direct-addresses``) cannot be dialed ``DIRECT`` — the recipient must resolve the
id. Which discovery posture it resolves under is the recipient node's
``redeem_reachability`` knob: ``DISCOVERY`` (n0 relays + DNS/pkarr) by default,
lowerable for a deployment policy. This gate sets that knob to ``LOCAL_DISCOVERY``
— an in-process address book, no network — and proves the hint-less redeem dials
by id through it and withdraws the gift.

It is a *discriminating* proof: with the default ``DISCOVERY``, the hint-less
redeem would reach for n0's public relays + DNS and fail with no internet; the
redeem succeeds here only because ``_dial_exporter`` honors the configured
posture. Deterministic and flake-free, three ``LOCAL_DISCOVERY`` endpoints in one
process sharing one address book.

Topology:
  Exporter  binds a ``LOCAL_DISCOVERY`` endpoint, publishes a node-giftable
            ``greeter``.
  Gifter    binds its own endpoint, dials the exporter by id (one node identity),
            fetches the greeter, and records the exporter's **id-only** location as
            the give's exporter location, a hint-less give.
  Recipient binds its own endpoint, sets its redeem posture to ``LOCAL_DISCOVERY``,
            dials the gifter, asks for the greeter, redeems the hint-less give by
            resolving the exporter's id through the book, and calls it.

Needs ``python3`` plus the iroh ABI companion library (``zig build iroh-abi``);
run via ``zig build python-iroh-redeem-posture``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bindings" / "python"))

from pancake import Ref, encode_peer_locator  # noqa: E402
from pancake.iroh import (  # noqa: E402
    Reachability,
    connect_iroh,
    connect_iroh_with_node,
    listen_iroh,
)

NAME = "python-redeem-posture-carol"

for _arg in sys.argv[1:]:
    # The gate takes no arguments; `-Dport` is meaningless for an in-process
    # local-discovery run, so accept and ignore a `--port=` for build parity.
    if not _arg.startswith("--port="):
        print(f"python-iroh-redeem-posture: unknown argument '{_arg}'", file=sys.stderr)
        raise SystemExit(2)


def fail(msg: str) -> None:
    print(f"python-iroh-redeem-posture FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


def greeter(verb: str, args: list):
    """The published actor: answer ``greet`` by echoing the caller's name."""
    if verb == "greet":
        name = args[0] if args else ""
        return f"hello {name} over a configured-posture redeem"
    return None


async def accept_loop(server, served: list) -> None:
    """Serve every connection the server accepts for the life of the run."""
    async for conn in server:
        conn.serve()
        served.append(conn)


async def run() -> None:
    # ── Exporter: a node-giftable greeter on its own local-discovery endpoint ─────
    exporter = listen_iroh(Reachability.LOCAL_DISCOVERY)
    exporter.node.publish_giftable("greeter", greeter)
    exporter_id = exporter.node_id
    exporter_served: list = []
    exporter_task = asyncio.create_task(accept_loop(exporter, exporter_served))
    print(f"python-iroh-redeem-posture: exporter published greeter on {exporter_id}")

    # ── Gifter: dials the exporter by id, re-gifts the greeter under a hint-less give
    gifter = listen_iroh(Reachability.LOCAL_DISCOVERY)
    gifter_id = gifter.node_id
    to_exporter = await connect_iroh_with_node(
        exporter_id, "", Reachability.LOCAL_DISCOVERY, gifter.node
    )
    greeter_ref = await to_exporter.fetch("greeter")
    # Record the exporter's location by **node id alone** — no direct-addresses.
    # This is what forces the recipient down the configured-posture redeem path
    # instead of a Direct dial.
    to_exporter.set_exporter_locator(encode_peer_locator("iroh", exporter_id, ""))

    def introducer(verb: str, args: list):
        if verb == "get-greeter":
            return greeter_ref
        return None

    gifter.node.publish_giftable("introducer", introducer)
    gifter_served: list = []
    gifter_task = asyncio.create_task(accept_loop(gifter, gifter_served))
    print(f"python-iroh-redeem-posture: gifter published introducer on {gifter_id}")

    # ── Recipient: configures its redeem posture, then redeems the hint-less give ─
    recipient = await connect_iroh(gifter_id, "", Reachability.LOCAL_DISCOVERY)
    # The knob under test: without it, the hint-less redeem defaults to DISCOVERY
    # (n0 relays + DNS) and would fail with no network. The node is shared, so
    # this reaches the connection that performs the redeem.
    recipient.node.redeem_reachability = Reachability.LOCAL_DISCOVERY
    introducer_ref = await recipient.fetch("introducer")
    granted = await recipient.send(introducer_ref, "get-greeter", [])
    if not isinstance(granted, Ref):
        fail(f"introduction did not redeem to a capability: {granted!r}")
    print(
        "python-iroh-redeem-posture: recipient redeemed the hint-less give under its "
        "configured LocalDiscovery posture, got the greeter as an ordinary ref"
    )

    reply = await recipient.send(granted, "greet", [NAME])
    if not isinstance(reply, str) or NAME not in reply:
        fail(f"greeter reply did not carry the name back: {reply!r}")
    print(f"python-iroh-redeem-posture: greeter replied: {reply}")

    print(
        "python-iroh-redeem-posture OK: a hint-less iroh give was redeemed by id through "
        "the recipient's configured LocalDiscovery posture (default Discovery would need the network)"
    )

    # Teardown: dialing connections first, then accepted connections, then servers.
    await recipient.close()
    await to_exporter.close()
    for conn in (*exporter_served, *gifter_served):
        await conn.close()
    await exporter.close()
    await gifter.close()
    await exporter_task
    await gifter_task


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(run(), timeout=90.0))
