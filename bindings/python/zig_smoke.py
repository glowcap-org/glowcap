"""Python dogfood of the Zig libpancake C ABI, through the idiomatic ``pancake``
module: drive OCapN with native Python values and typed events — no ctypes in
sight. This is the consumer ``zig build bindings`` runs."""

from __future__ import annotations

import asyncio
import sys
import threading

import ctypes

from pancake import (  # noqa: F401
    Argument, AsyncConnection, Break, Connection, Context, Deliver, Far, Fulfill,
    Near, Netlayer, Other, Peer, Ref, Resolve, Symbol, Vat, VowBroken, abi_version,
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

    # A pure-local vat: near-call and eventual-send over a local actor.
    local_vat = Vat()
    seen: dict = {}

    def adder(verb: str, args: list):
        if verb == "add":
            return args[0] + args[1]
        raise ValueError(f"no such method {verb!r}")

    actor = local_vat.spawn(adder)
    assert local_vat.call(actor, "add", [2, 3]) == 5, "near-call returns the value"
    vow = local_vat.send(actor, "add", [4, 6])
    local_vat.on(vow, on_fulfilled=lambda value: seen.update(local=value))
    local_vat.drive()
    assert seen.get("local") == 10, seen
    # Near-calling a far ref is illegal; only send reaches one.
    try:
        local_vat.call(Ref.to(Far(7)), "add", [1, 2])
    except Exception:
        pass
    else:
        raise AssertionError("near-calling a far ref must raise")

    # Host a Goblins-shaped actor on an export and run a deliver -> resolve turn.
    with Peer() as peer:
        vat = Vat(peer)
        count = {"value": 10}

        def counter(verb: str, args: list):
            if verb == "add":
                count["value"] += args[0]
                return count["value"]
            if verb == "get":
                return count["value"]
            raise ValueError(f"no such method {verb!r}")

        vat.publish(7, counter)
        # counter.add(5) with answer 11.
        vat.peer.feed(b"<10'op:deliver<11'desc:export7+>[3'add5+]11+f>")
        event = vat.peer.poll()
        assert isinstance(event, Deliver), f"expected Deliver, got {event!r}"
        assert vat.serve(event), "the deliver was served by the published actor"
        vat.peer.step()
        reply = vat.peer.take_outbound()
        assert reply is not None and b"op:resolve" in reply, reply
        assert b"15+" in reply, reply  # the new count fulfilled the answer

    print("python zig-smoke OK: drove OCapN + ran a TCP peer through the idiomatic API")

    # The full local|far seam: peerA's vat far-sends counter.add(5) to peerB's
    # published actor and observes the answer through a far vow's listener.
    with Peer() as a_peer, Peer() as b_peer:
        vat_a = Vat(a_peer)
        vat_b = Vat(b_peer)

        b_count = {"value": 10}

        def b_counter(verb: str, args: list):
            if verb == "add":
                b_count["value"] += args[0]
                return b_count["value"]
            raise ValueError(f"no such method {verb!r}")

        vat_b.publish(7, b_counter)
        a_peer.register_import(7)

        # A sends `counter.add(5)` to the far ref and listens on the far vow.
        result: dict = {}
        far_counter = Ref.to(Far(7))
        far_vow = vat_a.send(far_counter, "add", [5])
        vat_a.on(far_vow, on_fulfilled=lambda value: result.update(value=value))

        # Shuttle A's outbound deliver to B and serve it (-> 15, resolve).
        a_peer.step()
        deliver_frame = a_peer.take_outbound()
        assert deliver_frame is not None and b"op:deliver" in deliver_frame, deliver_frame
        b_peer.feed(deliver_frame)
        b_event = b_peer.poll()
        assert isinstance(b_event, Deliver), f"B expected Deliver, got {b_event!r}"
        assert vat_b.serve(b_event), "B's published actor served the deliver"

        # Shuttle B's resolve back to A and serve it (fires the far vow listener).
        b_peer.step()
        resolve_frame = b_peer.take_outbound()
        assert resolve_frame is not None and b"op:resolve" in resolve_frame, resolve_frame
        a_peer.feed(resolve_frame)
        a_event = a_peer.poll()
        assert isinstance(a_event, Resolve), f"A expected Resolve, got {a_event!r}"
        assert vat_a.serve(a_event), "A's far vow was served by the resolve"
        assert result.get("value") == 15, result

    print("python zig-smoke OK: far-send round trip through the local|far actor seam")

    asyncio.run(_async_round_trip())
    print("python zig-smoke OK: drove OCapN over asyncio (deliver -> fulfill round trip)")

    asyncio.run(_disconnect_rejects_pending_send())
    print("python zig-smoke OK: an outstanding send rejects on disconnect")
    return 0


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server reads the client's
    deliver and then closes without answering."""

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # Complete the responder handshake (the client's connect handshakes), then
        # read the client's deliver and drop the connection unanswered.
        peer = Peer.new_negotiating()
        peer.register_export(7)  # admit the client's deliver instead of aborting it
        ac = AsyncConnection.from_stream(peer, reader, writer)
        sock = writer.get_extra_info("sockname")
        peer.start_session_keyed(b"\x07" * 32, designator=f"{sock[0]}:{sock[1]}")
        await ac.flush()
        while not peer.session_is_open():
            if await ac.next_event() is None:
                return
        await ac.next_event()  # the client's deliver
        await ac.aclose()

    srv = await asyncio.start_server(serve, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    async with srv:
        conn = await Connection.connect("127.0.0.1", port)
        conn.serve()  # a disconnect ends the serve task; expected here
        conn.peer.register_import(7)
        rejected = False
        try:
            await conn.send(Ref.to(Far(7)), "ping", [])
        except VowBroken:
            rejected = True
        assert rejected, "an outstanding send rejects when the connection drops"
        await conn.close()


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
