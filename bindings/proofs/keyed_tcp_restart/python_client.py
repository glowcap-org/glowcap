"""Per-binding keyed-tcp restart proof: happy path, key-squatter
refusal, and same-seed-fresh-port restart — the Python sibling of
``test/driver/keyed_tcp_restart_test.zig``.

Needs ``python3`` and the installed pancake archives; run via
``zig build python-keyed-tcp-restart``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "interop" / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake import (  # noqa: E402
    DurableProvenance,
    PancakeError,
    connect,
    keyed_tcp_locator,
    listen_keyed_tcp,
)

ignore_port_args("python-keyed-tcp-restart")

GREETING = "hello from the keyed listener"
SEED_HAPPY = bytes([0x71]) * 32
SEED_HONEST = bytes([0x72]) * 32
SEED_SQUATTER = bytes([0x73]) * 32
SEED_RESTART = bytes([0x74]) * 32


def greeter(verb: str, args: list):
    if verb == "greet":
        return GREETING
    return None


async def serve_once(server) -> None:
    async for session in server:
        session.publish("greeter", greeter)
        session.serve()
        return


async def call_greeter(uri: str, expected: str) -> None:
    session = await connect(uri)
    try:
        # Keyed TCP carries a key-shaped designator. The verified session hello
        # must claim the dial target, but the cleartext channel does not prove
        # control of that durable key.
        proved = session.partner_identity()
        if proved.designator != expected:
            fail("keyed-tcp-restart", f"partner claimed {proved.designator}, not the dialed {expected}")
        # Every session signs with a fresh key (ADR-0097), distinct
        # from the claimed durable designator.
        if proved.session_key.hex() == expected:
            fail("keyed-tcp-restart", "session key still equals the durable designator; sessions are not independently keyed")
        # Raw keyed TCP carries the stable key-shaped locator but does not prove
        # that whoever answered controls it.
        if proved.provenance is not DurableProvenance.UNAUTHENTICATED:
            fail(
                "keyed-tcp-restart",
                f"keyed-tcp durable provenance is {proved.provenance}, not unauthenticated",
            )
        if proved.durable_identity_authenticated():
            fail("keyed-tcp-restart", "raw keyed-tcp authenticated an unproved locator claim")
        greeter_ref = await session.fetch("greeter")
        reply = await session.send(greeter_ref, "greet", [])
        if reply != GREETING:
            fail("keyed-tcp-restart", f"unexpected greeting: {reply!r}")
    finally:
        await session.close()


async def scene_happy() -> None:
    server = await listen_keyed_tcp("127.0.0.1", 0, seed=SEED_HAPPY)
    task = asyncio.create_task(serve_once(server))
    await call_greeter(server.uri(), server.designator)
    await task
    server.close()
    print("python-keyed-tcp-restart: happy path ok")


async def scene_squatter() -> None:
    # Listener holds a different key than the dialed designator.
    honest = await listen_keyed_tcp("127.0.0.1", 0, seed=SEED_HONEST)
    designator = honest.designator
    honest.close()
    squatter = await listen_keyed_tcp("127.0.0.1", 0, seed=SEED_SQUATTER)
    task = asyncio.create_task(serve_once(squatter))
    uri = keyed_tcp_locator(designator, "127.0.0.1", squatter.port)
    try:
        await call_greeter(uri, designator)
        fail("keyed-tcp-restart", "squatter dial should have been refused")
    except PancakeError as e:
        print(f"python-keyed-tcp-restart: squatter refused ({e})")
    await asyncio.wait([task], timeout=2)
    squatter.close()
    print("python-keyed-tcp-restart: squatter refusal ok")


async def scene_restart() -> None:
    first = await listen_keyed_tcp("127.0.0.1", 0, seed=SEED_RESTART)
    designator = first.designator
    task = asyncio.create_task(serve_once(first))
    await call_greeter(first.uri(), designator)
    await task
    first.close()

    second = await listen_keyed_tcp("127.0.0.1", 0, seed=SEED_RESTART)
    if second.designator != designator:
        fail("keyed-tcp-restart", f"restart designator drifted: {designator} vs {second.designator}")
    task = asyncio.create_task(serve_once(second))
    # Same designator, only the hint (port) updated.
    await call_greeter(keyed_tcp_locator(designator, "127.0.0.1", second.port), designator)
    await task
    second.close()
    print("python-keyed-tcp-restart: restart ok")


async def main() -> None:
    await scene_happy()
    await scene_squatter()
    await scene_restart()
    print("python-keyed-tcp-restart: all scenes ok")


if __name__ == "__main__":
    asyncio.run(main())
