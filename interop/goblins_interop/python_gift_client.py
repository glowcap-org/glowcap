"""Live three-party handoff with the Python binding as the GIFTER (the
introducer), proving pancake can mint a ``desc:handoff-give`` that live Goblins
redeems and a ``deposit-gift`` that live Goblins accepts, the exporter half of
ADR-0009 against a real cross-implementation peer, the mirror of
``python-goblins-handoff`` (where pancake is the recipient).

Topology (all TCP loopback):
  Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
  Gifter (pancake)           fetches Bob's greeter, publishes an "introducer"
                             that returns it, and listens for the recipient.
  Carol  (Goblins recipient) dials the pancake introducer, asks for the
                             greeter, transparently redeems pancake's give, and
                             calls the greeter directly on Bob.

pancake is the gifter: when Carol asks for the greeter, pancake deposits it back
with Bob over its own Bob connection and resolves Carol's send with a signed
give. Goblins Bob must accept pancake's deposit; Goblins Carol must redeem
pancake's give and reach Bob directly. The proof is Carol's ``GIFT OK`` line
carrying the greeter's reply with the name she sent.

Needs ``python3`` + ``racket`` + the ``goblins`` collection on PATH, so it runs
as the sibling build step ``zig build python-goblins-gift``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_common" / "python"))
from helpers import fail, insert_bindings_path, parse_port  # noqa: E402

insert_bindings_path()

from pancake import Ref, connect, listen, socket_addr_designator, tcp_locator  # noqa: E402

HOST = "127.0.0.1"
PORT = parse_port("python-goblins-gift", 22122, max_port=65534)

RACKET = "/usr/local/bin/racket"
EXPORTER_SCRIPT = "conformance/goblins-peer/racket/gift-exporter-host.rkt"
RECIPIENT_SCRIPT = "conformance/goblins-peer/racket/gift-recipient.rkt"
# pancake hardcodes the same swiss the exporter host registers, the way the
# interop clients fix the echo swiss.
GREETER_SWISS = "pancakeGiftGreeterSwissnum000001"
INTRODUCER_SWISS = "introducer"


async def await_bob_ready(proc: asyncio.subprocess.Process) -> None:
    assert proc.stdout is not None
    deadline = asyncio.get_running_loop().time() + 30.0
    while asyncio.get_running_loop().time() < deadline:
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=30.0)
        if not line:
            break
        if b'"name":"greeter"' in line:
            return
    fail("python-goblins-gift", "never saw the exporter's greeter readiness line")


async def run() -> None:
    # Spawn Bob (the Goblins exporter). A piped child stream that is never read
    # deadlocks the child once its OS pipe fills — Goblins logs to stderr during
    # operation — so drain stderr in the background and print it only on failure.
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
        await await_bob_ready(bob)
        print(f"python-goblins-gift: goblins-bob exporting greeter swiss={GREETER_SWISS} on {HOST}:{PORT}")

        # pancake (the gifter) listens for the recipient on an ephemeral port and
        # runs its accept loop. One node identity (gifter.host) serves both the
        # recipient connection and the exporter connection, so the give's
        # signature matches the deposit.
        gifter = await listen(HOST, 0)

        async def accept_loop() -> None:
            async for conn in gifter:
                conn.serve()

        accept_task = asyncio.ensure_future(accept_loop())
        gifter_port = gifter.port

        # Dial Bob and fetch his greeter. The fetched ref's home is this
        # gifter<->Bob connection, which is what lets pancake re-gift it.
        to_bob = await connect(tcp_locator(HOST, PORT), host=gifter.host)
        to_bob.serve()
        greeter = await to_bob.fetch(GREETER_SWISS)
        if not isinstance(greeter, Ref):
            fail("python-goblins-gift", "could not fetch goblins-bob's greeter")
        print("python-goblins-gift: fetched goblins-bob's greeter")

        # Publish the introducer host-wide. Returning Bob's greeter (home = the
        # Bob connection) to the recipient's connection trips the transparent
        # gifter, which deposits with Bob and resolves the recipient with a give.
        def introducer(verb: str, args: list) -> object:
            return greeter if verb == "get-greeter" else None

        gifter.host.publish_giftable(INTRODUCER_SWISS, introducer)
        print(f"python-goblins-gift: pancake publishing introducer swiss={INTRODUCER_SWISS} on {HOST}:{gifter_port}")

        # Spawn Carol (the Goblins recipient): she dials pancake's introducer,
        # asks for the greeter, redeems pancake's give, and calls Bob directly.
        carol = await asyncio.create_subprocess_exec(
            RACKET, RECIPIENT_SCRIPT, socket_addr_designator(HOST, gifter_port), INTRODUCER_SWISS, str(PORT + 1),
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
        if not reply.startswith("GIFT OK:") or "goblins-carol" not in reply:
            fail("python-goblins-gift", f"recipient did not confirm the greeter reply with its name: {reply!r}")

        ok = True
        print("python-goblins-gift OK: pancake minted a three-party handoff give that live Goblins redeemed, reaching the exporter directly")

        gifter.close()
        await to_bob.close()
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
