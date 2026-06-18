"""Python dogfood of the Zig pancake C ABI archives, through the idiomatic ``pancake``
module: drive OCapN with native Python values and typed events — no ctypes in
sight. This is the consumer ``zig build bindings`` runs."""

from __future__ import annotations

import asyncio
import sys
import threading

import ctypes

from pancake import (
    AsyncConnection, Connection, Context, Deliver, Far, FetchFailed,
    Fulfill, Near, Other, PancakeError, Peer, Ref, Resolve, Set, Symbol,
    Tagged, Vat, VowBroken, abi_version, listen,
)
from pancake.inproc import InprocNetlayer
from pancake.tcp import TcpNetlayer


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
        peer = Peer.raw_open_in(ctx)
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
    with Peer.raw_open() as caller:
        caller.register_import(5)
        caller.send_deliver(Far(5), [42, b"hi"], answer=9)
        caller.step()
        wire = caller.take_outbound()
        assert wire is not None and wire.startswith(b"<10'op:deliver"), "construct a deliver"

    with Peer.raw_open() as callee:
        callee.register_export(7)
        callee.feed(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
        event = callee.poll()
        assert isinstance(event, Deliver), f"expected Deliver, got {event!r}"
        assert event.target == Near(7), event.target
        assert event.answer == 11
        assert event.args == [b"hello"], event.args

    # The inbound abort surfaces as a typed event.
    with Peer.raw_open() as peer:
        peer.feed(b'<8\'op:abort3"bye>')
        abort = peer.poll()
        assert isinstance(abort, Other) and abort.kind == 7, f"expected abort, got {abort!r}"
        assert peer.poll() is None

    # Run a real peer over a TCP socket: one frame, loopback. The blocking TCP
    # shuttle is its own à-la-carte archive, composed from `pancake.tcp`.
    with TcpNetlayer() as nl:
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

    # The socket-free in-process transport is its own archive too, surfaced as
    # `pancake.inproc`: a listener binds an opaque designator and a dialer names
    # it — the same frame shuttle as TCP, no kernel socket touched.
    with InprocNetlayer() as nl:
        listener = nl.listen("smoke")
        received_inproc: list[bytes] = []

        def serve_inproc() -> None:
            conn = listener.accept()
            received_inproc.append(conn.read_frame())
            conn.close()

        thread = threading.Thread(target=serve_inproc)
        thread.start()
        client = nl.connect("smoke")
        client.write_frame(b'<8\'op:abort3"bye>')
        thread.join()
        client.close()
        listener.close()
        assert received_inproc == [b'<8\'op:abort3"bye>'], received_inproc

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
    with Peer.raw_open() as peer:
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
        # counter.add(5) with answer 11 and a V1.0 resolver callback.
        vat.peer.feed(b"<10'op:deliver<11'desc:export7+>[3'add5+]11+<19'desc:import-promise99+>>")
        event = vat.peer.poll()
        assert isinstance(event, Deliver), f"expected Deliver, got {event!r}"
        assert vat.serve(event), "the deliver was served by the published actor"
        vat.peer.step()
        reply = vat.peer.take_outbound()
        assert reply is not None and b"op:deliver" in reply, reply
        assert b"fulfill" in reply, reply
        assert b"15+" in reply, reply  # the new count fulfilled the answer

    print("python zig-smoke OK: drove OCapN + ran a TCP and an in-process peer through the idiomatic API")

    with Peer("pre-spec") as peer:
        peer.start_session(bytes([0x77]) * 32, designator="127.0.0.1:77")
        peer.step()
        frame = peer.take_outbound()
        assert frame is not None and b"op:start-session" in frame, frame

    print("python zig-smoke OK: queued an authenticated PreSpec start-session")

    # Bounded inbox: a frame declaring more than max_frame_bytes is a typed
    # refusal, never "read more". A connection's inbox keeps growing only while
    # recv_stream returns None, so this is the contract that stops a hostile
    # partner from growing it without bound.
    with Peer.raw_open() as peer:
        peer.register_export(7)
        over_cap = b"<10'op:deliver<11'desc:export7+>[2000000:"
        try:
            peer.recv_stream(over_cap)
            raise AssertionError("recv_stream accepted an over-cap frame")
        except PancakeError as exc:
            assert exc.code == -11, exc.code  # PANCAKE_ERR_FRAME_TOO_LARGE

    print("python zig-smoke OK: an over-cap frame refuses typed instead of buffering")

    # A refused frame names its typed cause: the flat PancakeError code says the
    # failure family, the attached AbortDetail says the member.
    with Peer.raw_open() as peer:
        assert peer.last_abort() is None, "no dispatch failure recorded yet"
        try:
            peer.feed(b"this is not a frame")
            raise AssertionError("feeding garbage must raise")
        except PancakeError as exc:
            assert exc.abort is not None, "the refused frame carries its typed cause"
            assert exc.abort.domain == "codec", exc.abort
            assert exc.abort.kind == "MalformedFrame", exc.abort
            assert exc.abort.error_name == "MalformedFrame", exc.abort

    print("python zig-smoke OK: a refused frame carries its typed abort cause")

    # Application-surface lowering/lifting: a Set lowers as a Set (never a plain
    # list), and a capability nested in a Set or Tagged lowers/lifts in place.
    lowered = Connection._lower(Set([1, Ref(far=Far(3))]))
    assert type(lowered) is Set, f"a Set lowers as a Set, got {type(lowered).__name__}"
    assert lowered[1] == Far(3), lowered
    lowered_tagged = Connection._lower(Tagged("note", [Ref(far=Far(3))]))
    assert lowered_tagged.value[0] == Far(3), lowered_tagged
    lifted = Connection._lift(Set([Far(4)]))
    assert type(lifted) is Set and isinstance(lifted[0], Ref), lifted
    lifted_tagged = Connection._lift(Tagged("note", [Far(4)]))
    assert isinstance(lifted_tagged.value[0], Ref), lifted_tagged

    print("python zig-smoke OK: Set and Tagged lower and lift in place, capabilities included")

    # The full local|far seam: peerA's vat far-sends counter.add(5) to peerB's
    # published actor and observes the answer through a far vow's listener.
    with Peer.raw_open() as a_peer, Peer.raw_open() as b_peer:
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

        # Shuttle B's V1.0 resolver-callback deliver back to A; the peer surfaces
        # it as a typed Resolve event, which fires the far vow listener.
        b_peer.step()
        resolve_frame = b_peer.take_outbound()
        assert resolve_frame is not None and b"op:deliver" in resolve_frame, resolve_frame
        assert b"fulfill" in resolve_frame, resolve_frame
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

    asyncio.run(_listen_surfaces_bound_port())
    print("python zig-smoke OK: high-level listen() surfaces the bound port and accepts")

    asyncio.run(_structured_args_round_trip())
    print("python zig-smoke OK: a Set round-trips as a Set, a nested capability stays sendable, a break is typed")

    asyncio.run(_enliven_round_trips_then_caches())
    print("python zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache")

    asyncio.run(_gc_releases_dropped_import())
    print("python zig-smoke OK: a dropped fetched import releases its export when GC is opted in")

    asyncio.run(_fetch_failed_is_typed())
    print("python zig-smoke OK: a non-capability fetch raises the typed FetchFailed")

    asyncio.run(_pipelining_drives_chain())
    print("python zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch")

    asyncio.run(_unawaited_break_stays_silent())
    print("python zig-smoke OK: an unawaited send is an asyncio.Future whose far break stays silent")

    asyncio.run(_projections_reach_a_field())
    print("python zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles")
    return 0


async def _pipelining_drives_chain() -> None:
    """Promise pipelining (ADR-0007), the questioner's half: ``Connection.send``
    returns a handle that is also a ``send`` target, so a create -> assign ->
    complete -> status chain is issued against the *unresolved* ``create`` answer
    and the four delivers travel as one batch. The board's ``create`` spawns a
    fresh task and returns it; the partner's engine queues the pipelined calls on
    that pending answer and drains them onto the task once ``create`` resolves. A
    ``status`` of ``done`` proves the chain crossed without round-tripping per
    link."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for conn in server:
                def root(verb, args):
                    assert verb == "create", verb
                    state = {"done": False}

                    def task(task_verb, task_args):
                        if task_verb == "assign":
                            return "assigned"
                        if task_verb == "complete":
                            state["done"] = True
                            return "done"
                        if task_verb == "status":
                            return "done" if state["done"] else "open"
                        raise ValueError(f"no such method: {task_verb}")

                    return conn.spawn(task)

                conn.publish("root", root)
                await conn.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        conn = await Connection.connect("127.0.0.1", server.port)
        conn.serve()
        root_ref = await conn.fetch("root")
        # The four verbs leave together: none awaits create's reply, and assign /
        # complete / status target the create answer directly.
        task = conn.send(root_ref, "create", ["benchmark"])
        conn.send(task, "assign", ["alice"])
        conn.send(task, "complete", [])
        status = await conn.send(task, "status", [])
        assert status == "done", f"pipelined status should be done, got {status!r}"
        await conn.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _projections_reach_a_field() -> None:
    """Pipelined projections (ADR-0050/ADR-0052): ``RemotePromise.index(i)`` and
    ``.untag(tag)`` access an element / unwrap a tag *at the answer*, before it
    resolves, each returning a new pipelinable ``RemotePromise``. The board's
    ``make`` returns ``["assigned", label, 7]`` tagged "task"; untag unwraps the
    single-value tag to that row, index 1 takes the label -- a two-hop chain that
    rides the still-pending ``make`` answer with no extra round trip. The source
    handle is also awaited afterward to prove a far reply observed *late* (after
    a sibling projection already pumped the loop) still settles. (``get``
    projects a Struct, which the Python value model does not carry, so it is
    proven at the C ABI layer in Zig; here we prove index and untag.)"""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for conn in server:
                def root(verb, args):
                    assert verb == "make", verb
                    label = str(args[0]) if args else "anon"
                    # A Tagged wrapping a single list value: untag unwraps to it.
                    return Tagged("task", [["assigned", label, 7]])

                conn.publish("root", root)
                await conn.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        conn = await Connection.connect("127.0.0.1", server.port)
        conn.serve()
        root_ref = await conn.fetch("root")
        # Neither projection awaits a prior reply: they ride the unresolved make
        # answer and the whole chain leaves on one flush.
        made = conn.send(root_ref, "make", ["alice"])
        label = await made.untag("task").index(1)
        assert label == "alice", f"pipelined untag->index should reach the label, got {label!r}"
        # The source answer settled while the projection pumped the loop; awaiting
        # it now must still resolve (a late far reply settles from the stash).
        full = await made
        assert isinstance(full, Tagged) and full.tag == "task", f"awaited source should be the tagged task, got {full!r}"
        await conn.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _unawaited_break_stays_silent() -> None:
    """Promise pipelining (ADR-0007), the unawaited-anchor contract: a send handle
    is a real ``asyncio.Future``, and an anchor whose far answer *breaks* -- even
    after its bytes flush on a sibling's tail -- never surfaces that break,
    because an unobserved handle starts no reply wait and so sets no exception.
    This is what lets a pipelining anchor go unawaited safely."""
    loop = asyncio.get_running_loop()
    seen: list = []
    loop.set_exception_handler(lambda _loop, ctx: seen.append(ctx))
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for conn in server:
                def root(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"boom: {verb}")

                conn.publish("root", root)
                await conn.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        conn = await Connection.connect("127.0.0.1", server.port)
        conn.serve()
        root_ref = await conn.fetch("root")
        anchor = conn.send(root_ref, "explode", [])
        assert isinstance(anchor, asyncio.Future), "a send handle must be an asyncio.Future"
        # `anchor` is never awaited; awaiting ping flushes the queued batch, so
        # explode's deliver crosses the wire and the host breaks its answer. The
        # break resolve arrives with no listener and is dropped -- no exception.
        pong = await conn.send(root_ref, "ping", [])
        assert pong == "pong", f"expected pong, got {pong!r}"
        del anchor
        await asyncio.sleep(0.05)  # let the break resolve land
        assert not seen, f"unawaited break must stay silent, saw {seen}"
        await conn.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _structured_args_round_trip() -> None:
    """A ``Set`` argument crosses the application surface as a ``Set`` (never a
    plain list), a capability nested in a Set or Tagged arrives as a sendable
    :class:`Ref`, and a partner break raises the typed :class:`VowBroken`."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for conn in server:
                def svc(verb, args):
                    if verb == "boom":
                        raise ValueError("kaboom")
                    assert verb == "probe", verb
                    probe_set = args[0]
                    assert type(probe_set) is Set, f"a Set argument arrives as a Set, got {type(probe_set).__name__}"
                    assert probe_set[0] == 1, probe_set
                    nested = probe_set[1]
                    assert isinstance(nested, Ref), f"a capability inside a Set lifts to a Ref, got {nested!r}"
                    note = args[1]
                    assert isinstance(note, Tagged), f"a Tagged argument arrives as a Tagged, got {note!r}"
                    assert isinstance(note.value[0], Ref), note.value
                    # The nested capability is sendable: poke back through it.
                    asyncio.ensure_future(conn.tell(nested, "poke", []))
                    return Set([Symbol("ok"), 7])

                conn.publish("svc", svc)
                await conn.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        conn = await Connection.connect("127.0.0.1", server.port)
        conn.serve()
        poked = asyncio.get_running_loop().create_future()

        def inbox_behavior(verb, args):
            if verb == "poke" and not poked.done():
                poked.set_result(True)

        inbox = conn.spawn(inbox_behavior)
        svc_ref = await conn.fetch("svc")
        reply = await conn.send(svc_ref, "probe", [Set([1, inbox]), Tagged("note", [inbox])])
        assert type(reply) is Set, f"a Set reply survives the round-trip as a Set, got {type(reply).__name__}"
        assert reply[0] == Symbol("ok") and reply[1] == 7, reply
        await asyncio.wait_for(poked, timeout=5)

        # A partner break is the typed VowBroken, catchable by type.
        try:
            await conn.send(svc_ref, "boom", [])
            raise AssertionError("a partner break must raise VowBroken")
        except VowBroken as exc:
            assert "kaboom" in str(exc), exc

        await conn.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _enliven_round_trips_then_caches() -> None:
    """Sturdyref enliven (ADR-0012): the requester brings a durable
    ``(peer, swissnum)`` to life as a live :class:`Ref` through the dedup cache.
    A repeat enliven of the same swissnum short-circuits with no wire traffic,
    and the enlivened capability is sendable both times."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for conn in server:
                def greeter(verb, args):
                    assert verb == "hello", verb
                    return Symbol("alive")

                conn.publish("greeter", greeter)
                await conn.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        conn = await Connection.connect("127.0.0.1", server.port)
        conn.serve()
        # The connection is already open to the peer; enliven keys on the
        # sturdyref's swissnum, carried by the URI as `/s/greeter`.
        sturdyref = "ocapn://greeter-host.tcp/s/greeter"
        cap = await conn.enliven(sturdyref)
        greeting = await conn.send(cap, "hello", [])
        assert greeting == Symbol("alive"), f"enlivened cap answers hello, got {greeting!r}"
        # A repeat enliven hits the dedup cache: the same live capability.
        again = await conn.enliven(sturdyref)
        greeting2 = await conn.send(again, "hello", [])
        assert greeting2 == Symbol("alive"), f"cached enliven answers hello, got {greeting2!r}"
        await conn.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _fetch_failed_is_typed() -> None:
    """A fetch that fulfills with a plain value (not a capability) raises the
    dedicated :class:`FetchFailed` — the foreign-bootstrap shape a non-pancake
    partner can produce. The server completes a real keyed handshake, then
    answers the bootstrap fetch by hand with a plain integer: the inbound fetch
    deliver is retargeted from export 0 to export 7 so a scratch peer's
    published actor — not the engine's bootstrap interception — fulfills it."""

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = Peer()
        try:
            sock = writer.get_extra_info("sockname")
            peer.start_session(b"\x0b" * 32, designator=f"{sock[0]}:{sock[1]}")
            peer.step()
            while (frame := peer.take_outbound()) is not None:
                writer.write(frame)
            await writer.drain()

            # Pump the handshake by hand so the bytes after the client's
            # start-session stay in our inbox instead of an AsyncConnection's.
            inbox = bytearray()
            while not peer.session_is_open():
                chunk = await reader.read(65536)
                assert chunk, "client closed during the handshake"
                inbox.extend(chunk)
                while not peer.session_is_open():
                    consumed = peer.recv_stream(inbox)
                    if consumed is None:
                        break
                    del inbox[:consumed]
                    peer.step()
                    while (frame := peer.take_outbound()) is not None:
                        writer.write(frame)
                await writer.drain()

            scratch = Peer.raw_open()
            try:
                vat = Vat(scratch)
                vat.publish(7, lambda verb, args: 42)
                while True:
                    doctored = bytes(inbox).replace(b"desc:export0+", b"desc:export7+")
                    consumed = scratch.recv_stream(doctored)
                    if consumed is not None:
                        break
                    chunk = await reader.read(65536)
                    assert chunk, "client closed before the fetch arrived"
                    inbox.extend(chunk)
                event = scratch.poll()
                assert isinstance(event, Deliver), f"the doctored fetch surfaced, got {event!r}"
                assert vat.serve(event), "the scratch actor served the doctored fetch"
                scratch.step()
                reply = scratch.take_outbound()
                assert reply is not None, "the scratch actor fulfilled the fetch"
                writer.write(reply)
                await writer.drain()
            finally:
                scratch.release()
            await reader.read(65536)  # hold the stream open until the client closes
            writer.close()
        finally:
            peer.release()

    srv = await asyncio.start_server(serve, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    async with srv:
        conn = await Connection.connect("127.0.0.1", port)
        try:
            await conn.fetch("not-a-capability")
            raise AssertionError("a non-capability fetch must raise FetchFailed")
        except FetchFailed as exc:
            assert exc.name == "not-a-capability", exc
        await conn.close()


async def _gc_releases_dropped_import() -> None:
    """Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
    capability releases its import -- one ``op:gc-export`` -- when the runtime
    reclaims the last :class:`Ref` to it. The raw host watches the wire for that
    release frame; the client drops its only handle, and CPython's refcounting
    fires the finalizer promptly."""
    result: dict = {}

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = Peer()
        try:
            peer.register_bootstrap_cap(b"svc")
            sock = writer.get_extra_info("sockname")
            peer.start_session(b"\x0c" * 32, designator=f"{sock[0]}:{sock[1]}")
            peer.step()
            while (frame := peer.take_outbound()) is not None:
                writer.write(frame)
            await writer.drain()

            inbox = bytearray()
            saw_gc = False
            while not saw_gc:
                chunk = await reader.read(65536)
                if not chunk:
                    break
                if b"op:gc-export" in chunk:
                    saw_gc = True
                inbox.extend(chunk)
                # Feed the peer so the engine auto-answers the bootstrap fetch.
                while True:
                    consumed = peer.recv_stream(inbox)
                    if consumed is None:
                        break
                    del inbox[:consumed]
                    peer.step()
                    while (frame := peer.take_outbound()) is not None:
                        writer.write(frame)
                await writer.drain()
            result["saw_gc"] = saw_gc
            writer.close()
        finally:
            peer.release()

    srv = await asyncio.start_server(serve, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    async with srv:
        conn = (await Connection.connect("127.0.0.1", port)).with_gc()
        conn.serve()
        cap = await conn.fetch("svc")
        assert cap.far is not None, "the fetched cap is a far import"
        # Drop the only handle; refcounting fires the finalizer, which schedules
        # the release drain. Yield a few loop turns for it to flush.
        del cap
        for _ in range(200):
            if result.get("saw_gc"):
                break
            await asyncio.sleep(0.01)
        await conn.close()
    assert result.get("saw_gc"), "host never saw op:gc-export for the dropped import"


async def _listen_surfaces_bound_port() -> None:
    """`listen` binds a `Server` whose `.port` reads the kernel-chosen ephemeral
    port (the parity gap with Deno/Rust/Racket), and a client can dial it."""
    server = await listen("127.0.0.1", 0)
    try:
        port = server.port
        assert port != 0, "bound ephemeral port should be readable"

        accepted: list = []

        async def accept_one() -> None:
            async for conn in server:
                accepted.append(conn)
                await conn.close()
                break

        accept_task = asyncio.ensure_future(accept_one())
        client = await Connection.connect("127.0.0.1", port)
        # Both keyed handshakes complete; one connection was accepted on the
        # bound port.
        await asyncio.wait_for(accept_task, timeout=5)
        assert len(accepted) == 1, "the dialed connection was accepted"
        await client.close()
    finally:
        server.close()


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server reads the client's
    deliver and then closes without answering."""

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # Complete the responder handshake (the client's connect handshakes), then
        # read the client's deliver and drop the connection unanswered.
        peer = Peer()
        peer.register_export(7)  # admit the client's deliver instead of aborting it
        ac = AsyncConnection.from_stream(peer, reader, writer)
        sock = writer.get_extra_info("sockname")
        peer.start_session(b"\x07" * 32, designator=f"{sock[0]}:{sock[1]}")
        await ac.flush()
        await ac._drive_until_session_open()
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
        server = Peer.raw_open()
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
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        async with AsyncConnection.from_stream(Peer.raw_open(), reader, writer) as client:
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
