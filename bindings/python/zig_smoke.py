"""Python dogfood of the Zig libpancake C ABI, through the idiomatic ``pancake``
module: drive OCapN with native Python values and typed events — no ctypes in
sight. This is the consumer ``zig build bindings`` runs."""

from __future__ import annotations

import asyncio
import sys
import threading

import ctypes

from pancake import (  # noqa: F401
    Argument, AsyncConnection, Break, Context, Deliver, Far, Fulfill, Near,
    Netlayer, Other, Peer, Resolve, abi_version,
)


def main() -> int:
    # The linked library reports a nonzero ABI version.
    major, minor, patch = abi_version()
    assert major + minor + patch > 0, (major, minor, patch)

    # Drive a peer in a context backed by a counting host allocator.
    stats = {"allocs": 0}
    live: dict = {}  # address -> owning ctypes buffer, kept alive until freed

    def host_alloc(size: int, alignment: int) -> int:
        stats["allocs"] += 1
        # Over-allocate so we can hand back an aligned address.
        backing = (ctypes.c_uint8 * (size + alignment))()
        base = ctypes.addressof(backing)
        addr = (base + alignment - 1) & ~(alignment - 1) if alignment > 1 else base
        live[addr] = backing
        return addr

    def host_free(address: int, size: int, alignment: int) -> None:
        live.pop(address, None)

    with Context.with_allocator(host_alloc, host_free) as ctx:
        peer = Peer.new_in(ctx)
        try:
            peer.register_export(7)
            # feed_owned transfers the bytes into the inbound queue; step applies.
            peer.feed_owned(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
            peer.step()
            event = peer.poll()
            assert isinstance(event, Deliver), f"expected Deliver, got {event!r}"
            assert event.target == Near(7), event.target
            assert event.args == [b"hello"], event.args
            assert stats["allocs"] > 0, "the host allocator serviced the peer"
        finally:
            # Release the peer before the context it was created in.
            peer.release()
    # Construct a call with native Python args and read it back as a typed Event.
    with Peer() as caller:
        caller.register_import(5)
        caller.send_deliver(Far(5), [42, b"hi"], answer=9)
        caller.step()
        wire = caller.take_outbound()
        assert wire is not None and wire.startswith(b"<10'op:deliver"), "construct a deliver"

    with Peer() as callee:
        callee.register_export(7)
        callee.feed(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
        event = callee.poll()
        assert isinstance(event, Deliver), f"expected Deliver, got {event!r}"
        assert event.target == Near(7), event.target
        assert event.answer == 11
        assert event.args == [b"hello"], event.args

    # The inbound abort surfaces as a typed event.
    with Peer() as peer:
        peer.feed(b'<8\'op:abort3"bye>')
        abort = peer.poll()
        assert isinstance(abort, Other) and abort.kind == 7, f"expected abort, got {abort!r}"
        assert peer.poll() is None

    # Run a real peer over a TCP socket: one frame, loopback.
    with Netlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        port = listener.port()
        received: list[bytes] = []

        def serve() -> None:
            conn = listener.accept()
            received.append(conn.read_frame())
            conn.close()

        thread = threading.Thread(target=serve)
        thread.start()
        client = nl.connect("127.0.0.1", port)
        client.write_frame(b'<8\'op:abort3"bye>')
        thread.join()
        client.close()
        listener.close()
        assert received == [b'<8\'op:abort3"bye>'], received

    print("python zig-smoke OK: drove OCapN + ran a TCP peer through the idiomatic API")

    asyncio.run(_async_round_trip())
    print("python zig-smoke OK: drove OCapN over asyncio (deliver -> fulfill round trip)")
    return 0


async def _async_round_trip() -> None:
    """A client delivers to a server export over asyncio; the server fulfills
    the answer and the client reads back the typed Resolve."""

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        server = Peer()
        server.register_export(7)
        async with AsyncConnection.from_stream(server, reader, writer) as conn:
            event = await conn.next_event()
            assert isinstance(event, Deliver), f"server expected Deliver, got {event!r}"
            assert event.target == Near(7), event.target
            assert event.args == [42], event.args
            assert event.answer == 9, event.answer
            await conn.send_resolve(event.answer, Fulfill(b"pong"))
            # Keep the connection open long enough for the client to read the reply.
            await conn.next_event()

    srv = await asyncio.start_server(serve, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    async with srv:
        async with await AsyncConnection.connect("127.0.0.1", port) as client:
            client.peer.register_import(7)
            await client.send_deliver(Far(7), [42], answer=9)
            event = await client.next_event()
            assert isinstance(event, Resolve), f"client expected Resolve, got {event!r}"
            assert event.answer == 9, event.answer
            assert isinstance(event.resolution, Fulfill), event.resolution
            assert event.resolution.value == b"pong", event.resolution.value


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"python zig-smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
