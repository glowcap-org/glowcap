"""Per-binding noise-relay managed-listen proof, Python half:
``relay.noise.listen`` registers a fresh durable key at the reference relay
and serves accepted Noise_XK-sealed sessions. Run by ``harness.ts``, which
appends ``<relayUrl> <registerUrl>`` and dials the printed locator.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "interop" / "_common" / "python"))
from helpers import insert_bindings_path  # noqa: E402

insert_bindings_path()

from glowcap import Argument  # noqa: E402
from glowcap import relay  # noqa: E402


async def main() -> None:
    if len(sys.argv) < 3:
        print("usage: python_listener.py <relayUrl> <registerUrl>", file=sys.stderr)
        raise SystemExit(2)
    relay_url, register_url = sys.argv[-2], sys.argv[-1]

    seed = os.urandom(32)
    async with await relay.noise.listen(relay_url, register_url, seed=seed) as server:

        def greet(verb: str, args: list[Argument]) -> str:
            if verb != "greet":
                raise LookupError("no such method")
            if len(args) != 1 or not isinstance(args[0], str):
                raise TypeError("bad invocation")
            return f"Hello, {args[0]}"

        server.host.publish("greeter", greet)
        print(f"RELAY-LISTENER-READY {server.uri}", flush=True)

        accepted = await server.__anext__()
        async with accepted as session:
            await session.serve()


if __name__ == "__main__":
    asyncio.run(main())
