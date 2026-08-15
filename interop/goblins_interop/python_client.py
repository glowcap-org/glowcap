"""Live interop proof for the Python binding: a peer built on ``libpancake``'s C
ABI holds a *keyed* OCapN conversation with a real Spritely Goblins vat over
TCP, driven through the *same* ``connect``/``enliven``/``send`` application
surface the cross-language demos use, so what is proven against a real Goblins
vat is the application API itself, not a bespoke handshake script.

It spawns the conformance Goblins host, learns the echo cap's swiss-num from its
NDJSON readiness line, then ``connect`` (keyed ``op:start-session``),
``enliven`` the echo sturdyref (bootstrap fetch + ADR-0012 dedup), ``send`` a
positional call, then a repeat ``enliven`` of the same swiss-num. Needs
``racket`` plus ``goblins`` on PATH; ``zig build python-goblins-interop``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, insert_bindings_path, parse_port, read_sturdyref_path  # noqa: E402

insert_bindings_path()

from pancake import Runtime, format_locator_uri, tcp  # noqa: E402
HOST = "127.0.0.1"
PORT = parse_port("python-goblins-interop", 22097)
RACKET = "racket"
HOST_SCRIPT = "conformance/goblins-peer/racket/goblins-host.rkt"


async def converse() -> None:
    proc = await asyncio.create_subprocess_exec(
        RACKET,
        HOST_SCRIPT,
        HOST,
        str(PORT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        sturdyref_path = await read_sturdyref_path(
            proc,
            "python-goblins-interop",
            miss="never saw the Goblins echo sturdyref path readiness field",
        )
        print(
            f"python-goblins-interop: goblins published its echo sturdyref path on {HOST}:{PORT}"
        )

        locator = tcp.locator(HOST, PORT)
        async with Runtime.open(provider=tcp.provider()) as runtime:
            session = await runtime.connect(locator)
            print(
                "python-goblins-interop: session open, keyed start-session accepted by goblins"
            )
            session.serve()

        # A sturdyref names a peer, and the enliven checks that peer against
        # the session it rides (ADR-0098). Build it from the very locator this
        # session dialed, so the two cannot drift apart.
            sturdyref = f"{format_locator_uri(locator)}/s/{sturdyref_path}"
            echo = await session.enliven(sturdyref)
            print("python-goblins-interop: enlivened goblins echo cap, calling it")

        # The echo actor is `(lambda args args)`: it returns its argument
        # list, so assert the content survived the round-trip (the native
        # driver's bar), not merely that something resolved.
            def assert_echoed(reply, expected):
                if reply != [expected]:
                    fail(
                        "python-goblins-interop",
                        f"echo returned {reply!r}, expected [{expected!r}]",
                    )

            assert_echoed(await session.send(echo, "", [b"pancake-ping"]), b"pancake-ping")

            again = await session.enliven(sturdyref)
        # The dedup cache hands back the same capability, so the two handles
        # carry one opaque Host identity (ADR-0096). The id is the whole
        # observable: a binding cannot see the wire import behind it, which is
        # the point of the identity being opaque.
            if echo.id != again.id:
                fail(
                    "python-goblins-interop",
                    "repeat enliven did not return the same capability (dedup miss)",
                )
            assert_echoed(
                await session.send(again, "", [b"pancake-ping-again"]), b"pancake-ping-again"
            )
            print(
                "python-goblins-interop: repeat enliven same import (dedup), second call resolved"
            )

            print(
                "python-goblins-interop OK: keyed handshake + enliven/dedup + echo "
                "deliver/resolve with live Goblins"
            )
            await session.close()
    finally:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        await proc.wait()


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(converse(), timeout=90.0))
