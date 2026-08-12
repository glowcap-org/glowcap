#!/usr/bin/env python3
"""The Python driver-provider parity proof (ADR-0112): the binding's byte-fed
iroh surface serves while its native-loop surface dials the same live
endpoint through the common provider ABI — both halves in one process,
one asyncio thread.

The server half is the shipped path: ``listen_iroh`` accepts keyed sessions
on the binding's own readiness loop and publishes a greeter on each. The
client half is the rewire: an iroh netlayer supplies its provider package,
``DriverLoop`` adopts it, and dial,
session, fetch, and the vow's outcome all arrive as loop events — the dial's
handshake stepping on a confined worker thread while the byte-fed surface keeps
serving on the event loop, which is the coexistence the record stages.

Needs the iroh ABI (``zig build iroh-abi``); run via
``zig build python-iroh-driver-provider``.
"""

from __future__ import annotations

import asyncio
import ctypes
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, ignore_port_args, insert_bindings_path  # noqa: E402

insert_bindings_path()

from pancake._ffi_host import _host as _host_ffi  # noqa: E402
from pancake._loop import DriverLoop  # noqa: E402
from pancake.iroh import (  # noqa: E402
    IrohConfig,
    Reachability,
    adopt_loop_provider,
    listen_iroh,
)

GREETING = "hello through the Python iroh transport"

ignore_port_args("python-iroh-driver-provider")


def _greeter(verb: str, args: list):
    if verb == "greet":
        return GREETING
    return None


async def _run_accepts(server, served: list) -> None:
    async for session in server:
        session.publish("greeter", _greeter)
        session.serve()
        served.append(session)


async def main() -> None:
    server = await listen_iroh(
        IrohConfig(Reachability.LOCAL_DISCOVERY, worker_threads=1)
    )
    server_id = server.node_id
    print(f"python-iroh-driver-provider: server endpoint id {server_id}")
    served: list = []
    accept_task = asyncio.create_task(_run_accepts(server, served))

    loop = DriverLoop.open()
    await adopt_loop_provider(
        loop, IrohConfig(Reachability.LOCAL_DISCOVERY, worker_threads=1)
    )
    await loop.start()

    session = await asyncio.wait_for(loop.dial("iroh", server_id), timeout=20)
    print(
        "python-iroh-driver-provider: the loop dialed by endpoint id through the "
        "provider ABI and opened the keyed session"
    )

    vow = ctypes.c_uint64(0)
    rc = _host_ffi.pancake_host_session_fetch(
        ctypes.c_void_p(session), b"greeter", 7, ctypes.byref(vow)
    )
    if rc != 0:
        fail("python-iroh-driver-provider", f"fetch refused with code {rc}")
    outcome = loop.completion(vow.value)
    loop.step_now()
    settled = await asyncio.wait_for(outcome, timeout=20)
    if settled is not True:
        fail("python-iroh-driver-provider", f"fetch settled oddly: {settled!r}")
    print(
        "python-iroh-driver-provider: the fetch's settle arrived as a COMPLETION "
        "event on the loop's queue"
    )

    loop.session_release(session)
    loop.close()

    for session in served:
        await session.close()
    await server.close()
    await accept_task

    print(
        "python-iroh-driver-provider: OK — the byte-fed surface served while the "
        "native loop dialed the same endpoint through the provider ABI"
    )


if __name__ == "__main__":
    asyncio.run(main())
