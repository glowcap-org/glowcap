"""Python row of the live Goblins-listener matrix."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import insert_bindings_path  # noqa: E402

insert_bindings_path()

from glowcap import Argument, tcp  # noqa: E402

ACTOR_SWISS = "glowcapActorSwissnumABCDEFGH1234"


def greeter(_verb: str, args: list[Argument]) -> str:
    value = args[0] if args else b"stranger"
    who = value.decode() if isinstance(value, bytes) else str(value)
    return f"Hello from a binding host: {who}"


async def main() -> None:
    server = await tcp.listen("127.0.0.1", 0)
    try:
        server.host.publish_giftable(ACTOR_SWISS, greeter)
        print(f"GOBLINS-LISTENER-READY {server.port}", flush=True)
        accepted = await server.__anext__()
        async with accepted as session:
            await session.serve()
    finally:
        await server.close()


if __name__ == "__main__":
    asyncio.run(main())
