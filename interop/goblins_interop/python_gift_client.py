"""Live three-party handoff with the Python binding as the GIFTER (the
introducer), proving glowcap can mint a ``desc:handoff-give`` that live Goblins
redeems and a ``deposit-gift`` that live Goblins accepts, the exporter half of
ADR-0009 against a real cross-implementation peer, the mirror of
``python-goblins-handoff`` (where glowcap is the recipient).

Topology (all TCP loopback):
  Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
  Gifter (glowcap)           lifts Bob's greeter from a vendor reply, then
                             publishes an "introducer" that returns it twice
                             in one nested Passable value.
  Carol  (Goblins recipient) dials the glowcap introducer, asks for the
                             greeters, transparently redeems both gives, and
                             calls both directly on Bob.

glowcap is the gifter: when Carol asks for the greeters, glowcap deposits both
occurrences with Bob and resolves Carol's send with two signed gives. Goblins
must redeem both and reach Bob directly; Carol's ``GIFT NESTED OK`` line carries
both replies and the distinct names she sent.

Needs ``python3`` + ``racket`` + the ``goblins`` collection on PATH, so it runs
as the sibling build step ``zig build python-goblins-gift``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import (  # noqa: E402
    await_greeter_ready,
    fail,
    insert_bindings_path,
    parse_port,
)

insert_bindings_path()

from glowcap import Ref, Runtime, tcp  # noqa: E402
HOST = "127.0.0.1"
PORT = parse_port("python-goblins-gift", 22122, max_port=65534)

RACKET = "racket"
EXPORTER_SCRIPT = "conformance/goblins-peer/racket/gift-exporter-host.rkt"
RECIPIENT_SCRIPT = "conformance/goblins-peer/racket/gift-recipient.rkt"
# glowcap hardcodes the same swiss the exporter host registers, the way the
# interop clients fix the echo swiss.
GREETER_SWISS = "glowcapGiftGreeterSwissnum000001"
VENDOR_SWISS = "glowcapGiftVendorSwissnum0000001"
INTRODUCER_SWISS = "introducer"


async def run() -> None:
    # Spawn Bob (the Goblins exporter). A piped child stream that is never read
    # deadlocks the child once its OS pipe fills, Goblins logs to stderr during
    # operation, so drain stderr in the background and print it only on failure.
    bob = await asyncio.create_subprocess_exec(
        RACKET, EXPORTER_SCRIPT, HOST, str(PORT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    bob_stderr_chunks: list[bytes] = []

    async def drain_bob_stderr() -> None:
        assert bob.stderr is not None
        while True:
            chunk = await bob.stderr.read(4096)
            if not chunk:
                return
            bob_stderr_chunks.append(chunk)

    bob_stderr_task = asyncio.ensure_future(drain_bob_stderr())

    ok = False
    carol: asyncio.subprocess.Process | None = None
    gifter = None
    to_bob = None
    try:
        await await_greeter_ready(bob, "python-goblins-gift")
        print(f"python-goblins-gift: goblins-bob exporting greeter swiss={GREETER_SWISS} on {HOST}:{PORT}")

        # glowcap (the gifter) listens for the recipient on an ephemeral port and
        # runs its accept loop. One node identity (gifter.host) serves both the
        # recipient connection and the exporter connection, so the give's
        # signature matches the deposit.
        gifter = await tcp.listen(HOST, 0)

        async def accept_loop() -> None:
            async for session in gifter:
                session.serve()

        accept_task = asyncio.ensure_future(accept_loop())
        gifter_port = gifter.port

        # Fetch a vendor, then lift Bob's greeter from an ordinary call reply.
        # The reply ref's home is this gifter<->Bob connection, so glowcap can
        # re-gift it without an enrollment verb.
        gifter_runtime = await Runtime.open(
            provider=tcp.provider(), adopt_host=gifter.host
        )
        to_bob = await gifter_runtime.connect(tcp.locator(HOST, PORT))
        to_bob.serve()
        vendor = await to_bob.fetch(VENDOR_SWISS)
        greeter = await to_bob.send(vendor, "", [])
        if not isinstance(greeter, Ref):
            fail("python-goblins-gift", "the vendor reply was not a capability")
        print("python-goblins-gift: lifted goblins-bob's greeter from a reply")

        # Two recursively placed occurrences force the binding's complete Value
        # lowering path and the core's one-message/two-give transaction.
        def introducer(verb: str, args: list) -> object:
            return [greeter, [greeter]] if verb == "get-greeter" else None

        gifter.host.publish(INTRODUCER_SWISS, introducer)
        print(f"python-goblins-gift: glowcap publishing introducer swiss={INTRODUCER_SWISS} on {HOST}:{gifter_port}")

        # Spawn Carol (the Goblins recipient): she dials glowcap's introducer,
        # asks for both greeters, redeems both gives, and calls Bob directly.
        carol = await asyncio.create_subprocess_exec(
            RACKET, RECIPIENT_SCRIPT, tcp.address_designator(HOST, gifter_port), INTRODUCER_SWISS, str(PORT + 1), "nested",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        carol_out, carol_err = await carol.communicate()
        reply = carol_out.decode().strip()
        carol_err_text = carol_err.decode().strip()
        if reply:
            print(f"python-goblins-gift: {reply}")
        if carol.returncode != 0:
            fail("python-goblins-gift", f"recipient exited non-zero{(': ' + carol_err_text) if carol_err_text else ''}")
        if (
            not reply.startswith("GIFT NESTED OK:")
            or "goblins-carol-one" not in reply
            or "goblins-carol-two" not in reply
        ):
            fail("python-goblins-gift", f"recipient did not confirm the greeter reply with its name: {reply!r}")

        ok = True
        print("python-goblins-gift OK: two nested binding values became distinct gives that live Goblins redeemed and called directly")

        await gifter.close()
        await to_bob.close()
        await gifter_runtime.close()
        accept_task.cancel()
        try:
            await accept_task
        except (asyncio.CancelledError, OSError):
            pass
    finally:
        try:
            bob.kill()
        except ProcessLookupError:
            pass
        await bob.wait()
        await bob_stderr_task
        if not ok:
            err = b"".join(bob_stderr_chunks).decode().strip()
            if err:
                print(f"python-goblins-gift: exporter stderr:\n{err}", file=sys.stderr)
        if carol is not None and carol.returncode is None:
            try:
                carol.kill()
            except ProcessLookupError:
                pass
            await carol.wait()
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(run(), timeout=120.0))
