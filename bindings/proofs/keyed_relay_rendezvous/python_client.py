"""Per-binding keyed-relay rendezvous proof: the Python binding cold-dials a
non-listening peer by its key designator through the reference relay's
rendezvous bridge (ADR-0088). The core classifies the locator as the
``rendezvous`` dial shape; the binding opens the WebSocket leg its host's
locator names while the Host fallback is deliberately dead.

Run via ``zig build python-keyed-relay-rendezvous`` (the harness passes
``<locator>``). Needs the optional ``websockets`` extra, which
the build step supplies from ``bindings/python/uv.lock``.
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
    if len(sys.argv) < 2:
        fail("keyed-relay-rendezvous", "usage: python_client.py <locator>")
    locator = sys.argv[-1]

    host = Host()
    host.rendezvous_url = (
        lambda peer_id: f"ws://127.0.0.1:1/relay?rendezvous={peer_id}"
    )
    session = await connect(locator, host=host)
    try:
        greeter = await session.fetch("greeter")
        reply = await session.send(greeter, "greet", ["python"])
        expected = "hello python, cold-dialed by rendezvous"
        if reply != expected:
            fail("keyed-relay-rendezvous", f"unexpected greeting: {reply!r}")
    finally:
        await session.close()
    print(
        "PASS: the Python binding cold-dialed a registered peer by rendezvous — "
        "the locator's rendezvous-relay route overrode the dead Host fallback "
        "and the keyed session answered"
    )


asyncio.run(main())
