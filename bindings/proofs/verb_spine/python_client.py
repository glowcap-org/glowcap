"""The Python half of the verb-spine proof family: one process that walks the
promise, dial, listen, and GC verbs against the fixed peer and prints one
``VERB-SPINE <marker>`` line per scene. ``harness.ts`` owns the marker contract
and the two locators appended to argv; read its header before changing a scene
here.

Run via ``zig build python-verb-spine``.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "interop" / "_common" / "python"))
from helpers import insert_bindings_path  # noqa: E402

insert_bindings_path()

from glowcap import (  # noqa: E402
    GlowcapError,
    Ref,
    Runtime,
    Session,
    parse_locator,
    tcp,
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def mark(marker: str, detail: str = "") -> None:
    print(f"VERB-SPINE {marker}{'' if detail == '' else ' ' + detail}", flush=True)


def expect_string(what: str, actual, wanted: str) -> None:
    if actual == wanted:
        return
    fail(f"{what}: expected {wanted!r}, got {actual!r}")


async def settles(handle) -> bool:
    """Whether a handle settled with a value. Every call site here expects a
    reported failure, so the failure is consumed rather than escaping as an
    exception nobody retrieved."""
    try:
        await handle
        return True
    except Exception:
        return False


def send_handle(session: Session, target, verb: str, args: list, what: str):
    """Send, and require that the call itself hands back a handle. A binding
    that raises here has put a synchronous failure channel on a
    promise-returning verb, which is the trap this family exists to catch."""
    try:
        handle = session.send(target, verb, args)
    except BaseException as raised:  # noqa: BLE001 - the escape under test
        fail(f"{what}: send raised instead of returning a handle: {raised!r}")
        raise AssertionError  # unreachable
    if not hasattr(handle, "__await__"):
        fail(f"{what}: send did not return an awaitable handle, got {handle!r}")
    return handle


def echo_behavior(verb: str, args: list):
    if verb != "echo":
        raise LookupError(f"echo has no verb {verb}")
    return args[0] if args and isinstance(args[0], str) else "?"


async def serve_once(server, served: list) -> None:
    """Publish ``echo`` on the first session this listener accepts, serve it,
    and hand the session back so the caller can retire it."""
    async for accepted in server:
        accepted.publish("echo", echo_behavior)
        accepted.serve()
        served.append(accepted)
        return


async def run(peer_uri: str, dead_uri: str) -> None:
    runtime = await Runtime.open(provider=tcp.provider())
    try:
        # ── dial-ok ──────────────────────────────────────────────────────────
        session = await runtime.connect(parse_locator(peer_uri))
        session.with_gc()
        spine = await session.fetch("spine")
        mark("dial-ok", peer_uri)

        # ── promise-handle ───────────────────────────────────────────────────
        greeted = send_handle(session, spine, "greet", ["spine"], "greet")
        expect_string("greet", await greeted, "hello, spine")
        mark("promise-handle")

        # ── promise-index / promise-untag / promise-get ──────────────────────
        # Each projection is issued at the unsettled answer, before anything
        # awaits it: that is what makes a dependent read one round trip rather
        # than two.
        listing = session.send(spine, "list", [])
        second_element = listing.index(1)
        expect_string("list index 1", await second_element, "beta")
        mark("promise-index")

        boxed = session.send(spine, "boxed", [])
        cell_tail = boxed.untag("cell").index(1)
        expect_string("boxed untag then index 1", await cell_tail, "cell-1")
        mark("promise-untag")

        record = session.send(spine, "record", [])
        record_name = record.get("name")
        expect_string("record field name", await record_name, "spine-record")
        mark("promise-get")

        # ── gc-released ──────────────────────────────────────────────────────
        minted = await session.send(spine, "mint", [])
        if not isinstance(minted, Ref):
            fail(f"mint did not answer with a capability: {minted!r}")
        expect_string("minted ping", await session.send(minted, "ping", []), "pong")
        session.release(minted)
        second_release_accepted = False
        try:
            session.release(minted)
            second_release_accepted = True
        except Exception:
            pass  # tolerant: the refusal this scene requires
        if second_release_accepted:
            fail("releasing a spent capability twice was accepted")
        through_spent = send_handle(
            session, minted, "ping", [], "send through a released capability"
        )
        if await settles(through_spent):
            fail("a send through a released capability was answered")
        mark("gc-released")

        # ── promise-failed ───────────────────────────────────────────────────
        # The documented escape, as behavior: a send that could never be issued
        # comes back as a settled failure, never as a raised error at the call.
        await session.close()
        ghost = send_handle(session, spine, "greet", ["ghost"], "send on a closed session")
        if await settles(ghost):
            fail("a send on a closed session was answered")
        mark("promise-failed")

        # ── listen-served ────────────────────────────────────────────────────
        server = await tcp.listen("127.0.0.1", 0)
        # A closed listener no longer has a locator to read, so name it while
        # it lives.
        own_uri = server.uri
        served: list = []
        serving = asyncio.create_task(serve_once(server, served))
        own = await runtime.connect(server.locator)
        echo = await own.fetch("echo")
        expect_string("own listener echo", await own.send(echo, "echo", ["heard"]), "heard")
        await own.close()
        await serving
        for accepted in served:
            await accepted.close()
        await server.close()
        mark("listen-served", own_uri)

        # ── dial-refused ─────────────────────────────────────────────────────
        stray = None
        try:
            stray = await runtime.connect(parse_locator(dead_uri))
        except GlowcapError as refusal:
            mark("dial-refused", str(refusal))
        if stray is not None:
            await stray.close()
            fail(f"dialing {dead_uri} opened a session; nothing is listening there")
    finally:
        await runtime.close()

    mark("ok")


async def main() -> None:
    if len(sys.argv) < 3:
        print("usage: python_client.py <peerUri> <deadUri>", file=sys.stderr)
        raise SystemExit(2)
    peer_uri, dead_uri = sys.argv[-2], sys.argv[-1]
    await asyncio.wait_for(run(peer_uri, dead_uri), timeout=20.0)


if __name__ == "__main__":
    asyncio.run(main())
