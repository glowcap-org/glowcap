"""Python dogfood of the Zig pancake C ABI archives, through the idiomatic
``pancake`` module over the byte-fed host archive (``libpancake_driver``,
ADR-0072): drive OCapN with native Python values, no FFI in sight. This is the
consumer ``zig build bindings`` runs."""

from __future__ import annotations

import asyncio
import sys
import threading

import ctypes

from pancake import (
    Context,
    FetchFailed,
    Forward,
    Keyword,
    Host,
    PancakeError,
    RedeemedReply,
    Ref,
    Set,
    Symbol,
    Tagged,
    VowBroken,
    abi_version,
    connect,
    listen,
    socket_addr_designator,
    tcp_locator,
)
from pancake._constants import TRANSPORT_TCP
from pancake.inproc import InprocNetlayer
from pancake.tcp import TcpNetlayer


def main() -> int:
    # The linked library reports a nonzero ABI version.
    major, minor, patch = abi_version()
    assert major + minor + patch > 0, (major, minor, patch)

    # Run a real frame over a TCP socket: one frame, loopback. The blocking TCP
    # shuttle is its own à-la-carte archive, composed from `pancake.tcp`.
    with TcpNetlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        port = listener.port()
        received: list[bytes] = []

        def serve() -> None:
            accepted = listener.accept()
            received.append(accepted.read_frame())
            accepted.close()

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
    # it, the same frame shuttle as TCP, no kernel socket touched.
    with InprocNetlayer() as nl:
        listener = nl.listen("smoke")
        received_inproc: list[bytes] = []

        def serve_inproc() -> None:
            accepted = listener.accept()
            received_inproc.append(accepted.read_frame())
            accepted.close()

        thread = threading.Thread(target=serve_inproc)
        thread.start()
        client = nl.connect("smoke")
        client.write_frame(b'<8\'op:abort3"bye>')
        thread.join()
        client.close()
        listener.close()
        assert received_inproc == [b'<8\'op:abort3"bye>'], received_inproc

    print("python zig-smoke OK: the blocking TCP and in-process transports shuttled a frame")

    asyncio.run(_allocator_context_round_trip())
    print("python zig-smoke OK: drove a published counter round-trip from a context-backed Host")

    asyncio.run(_capnp_codec_round_trip())
    print("python zig-smoke OK: a capnp session opens and big-integer + keyword args round-trip")

    asyncio.run(_feed_refusals_are_typed())
    print("python zig-smoke OK: an over-cap frame refuses typed and a refused frame carries its abort cause")

    asyncio.run(_disconnect_rejects_pending_send())
    print("python zig-smoke OK: an outstanding send rejects on disconnect")

    asyncio.run(_listen_surfaces_bound_port())
    print("python zig-smoke OK: high-level listen() surfaces the bound port and accepts")

    asyncio.run(_rude_probe_cannot_close_the_listener())
    print("python zig-smoke OK: a rude probe cannot close the listener")

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

    asyncio.run(_forwarding_proxies_over_the_wire())
    print("python zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire")

    asyncio.run(_forwarding_proxy_local_call())
    print("python zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)")

    asyncio.run(_mid_turn_driving_verb_breaks_the_answer())
    print("python zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer")

    asyncio.run(_send_redeeming_surfaces_the_direct_exporter())
    print("python zig-smoke OK: send_redeeming surfaces the redeemed exporter session, and a reply capability hosted on it routes")
    return 0


async def _start_relay(target_port: int, rewrite=None, observe=None):
    """A byte-level TCP relay between a client and a server that are both real
    pancake connections: it shuttles raw bytes both ways, optionally rewriting
    the client->server stream and observing the traffic. This is how the smoke
    watches the wire (a gc release frame) or doctors it (a retargeted fetch)
    without either endpoint dropping out of the application surface."""
    writers: list = []

    async def handle(client_reader, client_writer) -> None:
        try:
            server_reader, server_writer = await asyncio.open_connection("127.0.0.1", target_port)
        except OSError:
            client_writer.close()
            return
        writers.extend([client_writer, server_writer])

        async def pump(src, dst, rewriting: bool) -> None:
            try:
                while True:
                    chunk = await src.read(65536)
                    if not chunk:
                        break
                    if observe is not None:
                        observe(chunk)
                    dst.write(rewrite(chunk) if (rewriting and rewrite is not None) else chunk)
                    await dst.drain()
            except OSError:
                pass
            finally:
                dst.close()

        asyncio.ensure_future(pump(client_reader, server_writer, True))
        asyncio.ensure_future(pump(server_reader, client_writer, False))

    relay = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = relay.sockets[0].getsockname()[1]

    def close() -> None:
        relay.close()
        for w in writers:
            w.close()

    return port, close


async def _allocator_context_round_trip() -> None:
    """The basic round-trip: publish a counter, fetch it, drive it with sends.
    The server Host lives in a caller-supplied allocation context, so every
    byte the host owns routes through the custom allocator — proving
    :class:`Context` against the byte-fed host, released in the documented
    order (Host before context)."""
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
        host = Host(context=ctx)
        server = await listen("127.0.0.1", 0, host)
        try:
            async def serve_one() -> None:
                async for session in server:
                    count = {"value": 10}

                    def counter(verb, args):
                        if verb == "add":
                            count["value"] += args[0]
                            return count["value"]
                        if verb == "get":
                            return count["value"]
                        raise ValueError(f"no such method {verb!r}")

                    session.publish("counter", counter)
                    await session.serve()
                    break

            hosted = asyncio.ensure_future(serve_one())
            client = await connect(tcp_locator("127.0.0.1", server.port))
            client.serve()
            counter_ref = await client.fetch("counter")
            grown = await client.send(counter_ref, "add", [5])
            assert grown == 15, f"counter.add(5) returns 15, got {grown!r}"
            read = await client.send(counter_ref, "get", [])
            assert read == 15, f"counter.get() returns 15, got {read!r}"
            await client.close()
            await asyncio.wait_for(hosted, timeout=5)
        finally:
            server.close()
        # Release the Host before the context that owns its allocations.
        host.release()
        assert stats["allocs"] > 0, "the host allocator serviced the Host"


async def _capnp_codec_round_trip() -> None:
    """The codec selector end-to-end: both nodes minted with the Cap'n Proto
    wire grammar complete the keyed handshake and carry a deliver whose
    arguments round-trip through the capnp codec — a big integer past int64 and
    a Keyword included, so the two rare marshal arms are witnessed alongside
    the codec."""
    big = 2 ** 80
    server = await listen("127.0.0.1", 0, codec="capnp")
    try:
        async def serve_one() -> None:
            async for session in server:
                def svc(verb, args):
                    assert verb == "probe", verb
                    assert args[0] == big, args
                    assert isinstance(args[1], Keyword) and args[1] == "prio", args
                    assert args[2] == b"hi", args
                    return Keyword("done")

                session.publish("svc", svc)
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port), codec="capnp")
        session.serve()
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [big, Keyword("prio"), b"hi"])
        assert isinstance(reply, Keyword) and reply == "done", reply
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        server.close()


async def _feed_refusals_are_typed() -> None:
    """Bounded inbox and typed abort causes over the byte-fed host. A frame
    declaring more than the frame cap is a typed refusal the moment that is
    knowable, never "read more" (ADR-0041); a refused frame names its typed
    cause (the flat PancakeError code says the failure family, the attached
    AbortDetail says the member). The bytes are injected through the
    connection's own feed seam — a binding-internal probe, the sibling of the
    Racket smoke's ``feed-bytes!``."""
    from pancake import _pump
    from pancake._session import Session as _Conn

    class _InjectTransport:
        async def read(self):
            await asyncio.get_running_loop().create_future()  # never resolves

        async def write(self, data):
            pass

        def close(self):
            pass

    # Over-cap: the length prefix declares past the cap, refused during the scan.
    # Bytes ride the named pump module (`_pump._feed`), not a Session verb.
    conn = _Conn._open_dialed_locator(
        Host(), TRANSPORT_TCP, socket_addr_designator("127.0.0.1", 1), _InjectTransport()
    )
    try:
        await _pump._feed(conn, b"<10'op:deliver<11'desc:export7+>[2000000:")
        raise AssertionError("an over-cap frame must refuse typed instead of buffering")
    except PancakeError as exc:
        assert exc.code == -11, exc.code  # PANCAKE_ERR_FRAME_TOO_LARGE
    finally:
        conn.close_transport()

    # Garbage: the refusal carries the typed abort detail.
    conn = _Conn._open_dialed_locator(
        Host(), TRANSPORT_TCP, socket_addr_designator("127.0.0.1", 1), _InjectTransport()
    )
    try:
        assert conn.last_abort() is None, "no dispatch failure recorded yet"
        try:
            await _pump._feed(conn, b"this is not a frame")
            raise AssertionError("feeding garbage must raise")
        except PancakeError as exc:
            assert exc.abort is not None, "the refused frame carries its typed cause"
            assert exc.abort.domain == "codec", exc.abort
            assert exc.abort.kind == "MalformedFrame", exc.abort
            assert exc.abort.error_name == "MalformedFrame", exc.abort
    finally:
        conn.close_transport()


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server serves one call and
    then closes without warning; the client's next awaited send settles with a
    typed rejection once the disconnect lands."""
    server = await listen("127.0.0.1", 0)
    closed = asyncio.Event()
    try:
        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                session.serve()
                await asyncio.sleep(0.05)
                await session.close()
                closed.set()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()  # a disconnect ends the serve task; expected here
        svc = await session.fetch("svc")
        await session.send(svc, "ping", [])
        await closed.wait()
        rejected = False
        try:
            await session.send(svc, "late", [])
        except (PancakeError, VowBroken):
            rejected = True
        assert rejected, "an outstanding send rejects when the connection drops"
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        server.close()


async def _listen_surfaces_bound_port() -> None:
    """`listen` binds a `Server` whose `.port` reads the kernel-chosen ephemeral
    port, and a client can dial it."""
    server = await listen("127.0.0.1", 0)
    try:
        port = server.port
        assert port != 0, "bound ephemeral port should be readable"

        accepted: list = []

        async def accept_one() -> None:
            async for session in server:
                accepted.append(session)
                await session.close()
                break

        accept_task = asyncio.ensure_future(accept_one())
        client = await connect(tcp_locator("127.0.0.1", port))
        # Both keyed handshakes complete; one connection was accepted on the
        # bound port.
        await asyncio.wait_for(accept_task, timeout=5)
        assert len(accepted) == 1, "the dialed connection was accepted"
        await client.close()
    finally:
        server.close()


async def _rude_probe_cannot_close_the_listener() -> None:
    """A rude TCP probe — connect, say nothing, hang up — is that connection's
    failure, not the listener's. The Server's iterator must skip the failed
    handshake and keep accepting; without the skip, one port scan takes a
    long-lived server down."""
    server = await listen("127.0.0.1", 0)
    try:
        port = server.port

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: Symbol("alive"))
                session.serve()
                break  # one real client is the proof

        served = asyncio.ensure_future(serve_one())

        # The probe: a raw socket that opens and immediately hangs up.
        probe_reader, probe_writer = await asyncio.open_connection("127.0.0.1", port)
        probe_writer.close()
        del probe_reader

        session = await connect(tcp_locator("127.0.0.1", port))
        svc = await session.fetch("svc")
        reply = await session.send(svc, "ping", [])
        assert reply == Symbol("alive"), reply
        await session.close()
        await asyncio.wait_for(served, timeout=5)
    finally:
        server.close()


async def _structured_args_round_trip() -> None:
    """A ``Set`` argument crosses the application surface as a ``Set`` (never a
    plain list), a capability nested in a Set or Tagged arrives as a sendable
    :class:`Ref`, and a partner break raises the typed :class:`VowBroken`."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
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
                    asyncio.ensure_future(session.tell(nested, "poke", []))
                    return Set([Symbol("ok"), 7])

                session.publish("svc", svc)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        poked = asyncio.get_running_loop().create_future()

        def inbox_behavior(verb, args):
            if verb == "poke" and not poked.done():
                poked.set_result(True)

        inbox = session.spawn(inbox_behavior)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [Set([1, inbox]), Tagged("note", [inbox])])
        assert type(reply) is Set, f"a Set reply survives the round-trip as a Set, got {type(reply).__name__}"
        assert reply[0] == Symbol("ok") and reply[1] == 7, reply
        await asyncio.wait_for(poked, timeout=5)

        # A partner break is the typed VowBroken, catchable by type.
        try:
            await session.send(svc_ref, "boom", [])
            raise AssertionError("a partner break must raise VowBroken")
        except VowBroken as exc:
            assert "kaboom" in str(exc), exc

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _enliven_round_trips_then_caches() -> None:
    """Sturdyref enliven (ADR-0012): the requester brings a durable
    ``(peer, swissnum)`` to life as a live :class:`Ref` through the host's
    dedup cache. A repeat enliven of the same swissnum short-circuits with no
    wire traffic (its completion is queued before the minting call returns),
    and the enlivened capability is sendable both times."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
                def greeter(verb, args):
                    assert verb == "hello", verb
                    return Symbol("alive")

                session.publish("greeter", greeter)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        # The connection is already open to the peer; enliven keys on the
        # sturdyref's swissnum, carried by the URI as `/s/greeter`.
        sturdyref = "ocapn://greeter-host.tcp/s/greeter"
        cap = await session.enliven(sturdyref)
        greeting = await session.send(cap, "hello", [])
        assert greeting == Symbol("alive"), f"enlivened cap answers hello, got {greeting!r}"
        # A repeat enliven hits the dedup cache: the same live capability.
        again = await session.enliven(sturdyref)
        greeting2 = await session.send(again, "hello", [])
        assert greeting2 == Symbol("alive"), f"cached enliven answers hello, got {greeting2!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _gc_releases_dropped_import() -> None:
    """Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
    capability releases its import -- one ``op:gc-exports`` -- when the runtime
    reclaims the last :class:`Ref` to it. Both ends are real connections; a
    byte relay between them watches the wire for the release frame. The client
    drops its only handle, and CPython's refcounting fires the finalizer
    promptly."""
    server = await listen("127.0.0.1", 0)
    saw_gc = asyncio.Event()

    def observe(chunk: bytes) -> None:
        if b"op:gc-export" in chunk:
            saw_gc.set()

    relay_port, relay_close = await _start_relay(server.port, observe=observe)
    try:
        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = (await connect(tcp_locator("127.0.0.1", relay_port))).with_gc()
        session.serve()
        cap = await session.fetch("svc")
        assert cap.far is not None, "the fetched cap is a far token"
        # Drop the only handle; refcounting fires the finalizer, which parks the
        # token and hops to the loop. Yield loop turns for it to flush.
        del cap
        for _ in range(200):
            if saw_gc.is_set():
                break
            await asyncio.sleep(0.01)
        assert saw_gc.is_set(), "the wire never carried op:gc-export for the dropped import"
        # The finalizer parked the release and hopped to the loop; observing
        # op:gc-export means it ran, so no parked release is left behind (parity
        # with the TypeScript, Rust, and Racket dogfoods, which assert the same).
        assert (
            session._host.pending_release_count() == 0
        ), "the finalizer's parked release drained after the turn"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        relay_close()
        server.close()


async def _fetch_failed_is_typed() -> None:
    """A fetch that fulfills with a plain value (not a capability) raises the
    dedicated :class:`FetchFailed` — the foreign-bootstrap shape a non-pancake
    partner can produce. A pancake host always answers a fetch with a
    capability, so a relay doctors the wire: the client's bootstrap-fetch
    deliver is retargeted from export 0 to the export of a published object
    that answers with a plain integer, so the client's fetch answer fulfills
    with 42. The client fetches "plain" legitimately first: that reply's
    marshal is what grants the export (ADR-0074), so the doctored deliver
    that follows is admitted rather than refused as a probe of an ungranted
    position."""
    server = await listen("127.0.0.1", 0)
    plain_export: list = []
    export_known = asyncio.Event()
    # Armed only after the legitimate fetch of "plain" has granted the export,
    # so only the second fetch is doctored.
    state = {"retargeted": False, "armed": False}

    def retarget(chunk: bytes) -> bytes:
        if not state["armed"] or state["retargeted"] or not plain_export:
            return chunk
        needle = b"desc:export0+"
        if needle in chunk:
            state["retargeted"] = True
            return chunk.replace(needle, b"desc:export%d+" % plain_export[0], 1)
        return chunk

    relay_port, relay_close = await _start_relay(server.port, rewrite=retarget)
    try:
        async def serve_one() -> None:
            async for session in server:
                # The doctored fetch deliver lands here with verb "fetch";
                # answer with a plain integer, which is exactly what a fetch
                # must not resolve to.
                plain = session.publish("plain", lambda verb, args: 42)
                assert plain.near is not None and plain.near.id < 10, "the retarget needs a single-digit export"
                plain_export.append(plain.near.id)
                export_known.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", relay_port))
        session.serve()
        await export_known.wait()
        # The granting fetch: its resolve marshals the "plain" reference,
        # which is what makes the position addressable for the doctored
        # deliver below.
        await session.fetch("plain")
        state["armed"] = True
        try:
            await session.fetch("not-a-capability")
            raise AssertionError("a non-capability fetch must raise FetchFailed")
        except FetchFailed as exc:
            assert exc.name == "not-a-capability", exc
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        relay_close()
        server.close()


async def _pipelining_drives_chain() -> None:
    """Promise pipelining (ADR-0007), the questioner's half: ``Session.send``
    returns a handle that is also a ``send`` target, so a create -> assign ->
    complete -> status chain is issued against the *unresolved* ``create`` answer
    and the four delivers travel as one batch. The board's ``create`` spawns a
    fresh task from inside the served turn (the turn-time spawn) and returns
    it; the partner's engine queues the pipelined calls on that pending answer
    and drains them onto the task once ``create`` resolves. A ``status`` of
    ``done`` proves the chain crossed without round-tripping per link."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
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

                    return session.spawn(task)

                session.publish("root", root)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        root_ref = await session.fetch("root")
        # The four verbs leave together: none awaits create's reply, and assign /
        # complete / status target the create answer directly.
        task = session.send(root_ref, "create", ["benchmark"])
        session.send(task, "assign", ["alice"])
        session.send(task, "complete", [])
        status = await session.send(task, "status", [])
        assert status == "done", f"pipelined status should be done, got {status!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _unawaited_break_stays_silent() -> None:
    """Promise pipelining (ADR-0007), the unawaited-anchor contract: a send
    handle is a real ``asyncio.Future``, and an anchor whose far answer
    *breaks* -- even after its bytes flush on a sibling's tail -- never
    surfaces that break, because an unobserved handle materializes no
    exception (the outcome is recorded, not thrown). This is what lets a
    pipelining anchor go unawaited safely."""
    loop = asyncio.get_running_loop()
    seen: list = []
    loop.set_exception_handler(lambda _loop, ctx: seen.append(ctx))
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
                def root(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"boom: {verb}")

                session.publish("root", root)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        root_ref = await session.fetch("root")
        anchor = session.send(root_ref, "explode", [])
        assert isinstance(anchor, asyncio.Future), "a send handle must be an asyncio.Future"
        # `anchor` is never awaited; awaiting ping flushes the queued batch, so
        # explode's deliver crosses the wire and the host breaks its answer. The
        # break's FAIL completion is recorded with no waiter -- no exception.
        pong = await session.send(root_ref, "ping", [])
        assert pong == "pong", f"expected pong, got {pong!r}"
        del anchor
        await asyncio.sleep(0.05)  # let the break land
        assert not seen, f"unawaited break must stay silent, saw {seen}"
        await session.close()
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
    a sibling projection already pumped the loop) still settles from the
    recorded outcome."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
                def root(verb, args):
                    assert verb == "make", verb
                    label = str(args[0]) if args else "anon"
                    # A Tagged wrapping a single list value: untag unwraps to it.
                    return Tagged("task", [["assigned", label, 7]])

                session.publish("root", root)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        root_ref = await session.fetch("root")
        # Neither projection awaits a prior reply: they ride the unresolved make
        # answer and the whole chain leaves on one flush.
        made = session.send(root_ref, "make", ["alice"])
        label = await made.untag("task").index(1)
        assert label == "alice", f"pipelined untag->index should reach the label, got {label!r}"
        # The source answer settled while the projection pumped the loop; awaiting
        # it now must still resolve (a late observation settles from the store).
        full = await made
        assert isinstance(full, Tagged) and full.tag == "task", f"awaited source should be the tagged task, got {full!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _forwarding_proxies_over_the_wire() -> None:
    """Object-capability forwarding proxies over the wire (ADR-0064). The server
    fetches the client's published tool — a far reference on the server side —
    wraps it in a caretaker and an attenuator, and hands the proxies back. A
    call through the proxy forwards across the server to the client's tool (the
    far deferred-answer path) and settles the caller's answer; the attenuator
    passes only its allow-listed verb; and a revoke breaks every later call."""
    server = await listen("127.0.0.1", 0)
    tool_ready = asyncio.Event()
    proxy_ready = asyncio.Event()
    try:
        async def serve_one() -> None:
            async for session in server:
                session.serve()
                await tool_ready.wait()
                tool = await session.fetch("tool")
                care = session.caretaker(tool)
                readonly = session.attenuate(tool, ["get"])

                def root(verb, args):
                    if verb == "proxy":
                        return care.proxy
                    if verb == "readonly":
                        return readonly
                    if verb == "revoke":
                        care.revoke()
                        return None
                    raise ValueError(f"no such method: {verb}")

                session.publish("root", root)
                proxy_ready.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()  # serve so the server's forwarded call arrives

        def tool(verb, args):
            if verb == "add":
                n = args[0] if args and isinstance(args[0], int) else 0
                return n + 1
            if verb == "get":
                return 7
            raise ValueError(f"no such method: {verb}")

        session.publish("tool", tool)
        tool_ready.set()
        await proxy_ready.wait()
        root_ref = await session.fetch("root")

        # Live caretaker: a call forwards across the server to the far tool.
        proxy = await session.send(root_ref, "proxy", [])
        assert isinstance(proxy, Ref), "the caretaker proxy lifts to a Ref"
        total = await session.send(proxy, "add", [41])
        assert total == 42, f"caretaker forwards to the far tool, got {total!r}"

        # Attenuator: the allow-listed verb forwards; any other breaks.
        readonly = await session.send(root_ref, "readonly", [])
        assert isinstance(readonly, Ref), "the attenuator proxy lifts to a Ref"
        got = await session.send(readonly, "get", [])
        assert got == 7, f"the attenuator forwards an allowed verb, got {got!r}"
        denied = None
        try:
            await session.send(readonly, "add", [1])
        except VowBroken as error:
            denied = error
        assert denied is not None and "Attenuated" in str(denied), "an out-of-list verb breaks Attenuated"

        # Revoke: every later call through the proxy breaks.
        await session.send(root_ref, "revoke", [])
        severed = None
        try:
            await session.send(proxy, "add", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), "a revoked proxy breaks Revoked"

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _forwarding_proxy_local_call() -> None:
    """The wart ADR-0064 closes: a forwarding proxy is an ordinary spawned actor,
    so its own host calls it locally exactly as a partner calls it over the
    wire. A caretaker over a *local* tool answers a local send; a caretaker
    over a *far* tool forwards across the wire and the local send still
    settles; and a revoke breaks the local call too, no second-class behavior
    on the hosting side."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
                def tool(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"no such method: {verb}")

                session.publish("tool", tool)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()

        # A caretaker over a local tool, called locally by its own host.
        def local_tool(verb, args):
            if verb == "double":
                return (args[0] if args and isinstance(args[0], int) else 0) * 2
            raise ValueError(f"no such method: {verb}")

        care_local = session.caretaker(session.spawn(local_tool))
        doubled = await session.send(care_local.proxy, "double", [21])
        assert doubled == 42, f"a local proxy answers a local call, got {doubled!r}"

        # A caretaker over a far tool, called locally: the proxy forwards across
        # the wire and the local send still settles on the partner's reply.
        far = await session.fetch("tool")
        care_far = session.caretaker(far)
        pong = await session.send(care_far.proxy, "ping", [])
        assert pong == "pong", f"a local call to a proxy over a far tool settles, got {pong!r}"

        # Revoke severs the local call exactly as it severs a partner's.
        care_local.revoke()
        severed = None
        try:
            await session.send(care_local.proxy, "double", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), "revoke breaks a local call too"

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _mid_turn_driving_verb_breaks_the_answer() -> None:
    """The callback latch crosses the binding: a behavior that reaches for a
    host-driving verb mid-turn (publish, here) is refused by the C tier, the
    refusal surfaces as the behavior's own raise, and the answer breaks with
    it — the turn neither deadlocks nor corrupts the host. The connection
    stays fully usable afterwards."""
    server = await listen("127.0.0.1", 0)
    try:
        async def serve_one() -> None:
            async for session in server:
                def svc(verb, args):
                    if verb == "reenter":
                        # A driving verb inside the turn: the latch refuses it
                        # and the raised PancakeError's words become the broken
                        # answer.
                        session.publish("nested", lambda v, a: None)
                        return "unreachable"
                    return "pong"

                session.publish("svc", svc)
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        svc_ref = await session.fetch("svc")
        broke = None
        try:
            await session.send(svc_ref, "reenter", [])
        except VowBroken as error:
            broke = error
        assert broke is not None, "a mid-turn driving verb breaks the answer"
        # The turn unwound cleanly: the same session still answers.
        pong = await session.send(svc_ref, "ping", [])
        assert pong == "pong", f"the connection survives the refused turn, got {pong!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        server.close()


async def _send_redeeming_surfaces_the_direct_exporter() -> None:
    """A three-party handoff with pancake as all three parties, over loopback:
    the exporter (Bob) publishes a host-wide giftable inbox, the broker holds it
    and introduces members to it, and the recipient (Carol) asks for an
    introduction with ``send_redeeming``.

    The reply's ``via`` is the *direct* Carol-to-Bob connection the binding
    dialed to redeem the give, not the broker connection Carol sent on. That is
    the one place a reply capability is valid, because a near export names a
    position on one specific connection's peer: Carol spawns her reply inbox on
    ``via``, and Bob answers by calling it back, so the message and its answer
    both travel the direct connection while the broker stays out of the path. A
    second introduction resolves the same ``via`` with no fresh dial, which is
    what makes the attribution deterministic rather than a which-dial-ran
    guess."""
    delivered: list = []
    acked: list = []

    bob = await listen("127.0.0.1", 0)
    broker = await listen("127.0.0.1", 0)
    accepting: list = []
    try:
        def dm(verb, args):
            if verb == "dm":
                delivered.append(args[0])
                # Answer by calling back the capability the sender spawned. It
                # is a live export only on the connection the redeemed token
                # routes to, so this call reaching Carol is the proof that
                # `via` named that connection.
                return Forward(args[1], "note", [f"bob got {args[0]}"])
            return None

        bob.host.publish_giftable("dm", dm)

        async def accept_all(server) -> None:
            async for session in server:
                session.serve()

        accepting.append(asyncio.ensure_future(accept_all(bob)))
        accepting.append(asyncio.ensure_future(accept_all(broker)))

        # The broker dials Bob under its own identity and fetches his giftable
        # inbox; returning that ref to a *different* connection is what trips
        # the transparent gifter.
        broker_to_bob = await connect(tcp_locator("127.0.0.1", bob.port), host=broker.host)
        broker_to_bob.serve()
        bob_dm = await broker_to_bob.fetch("dm")
        broker.host.publish_giftable(
            "introducer",
            lambda verb, args: bob_dm if verb == "introduce" else "no capability here",
        )

        carol = await connect(tcp_locator("127.0.0.1", broker.port))
        carol.serve()
        introducer = await carol.fetch("introducer")

        settled = await carol.send_redeeming(introducer, "introduce", [])
        assert isinstance(settled, RedeemedReply), settled
        reply, via = settled
        assert isinstance(reply, Ref), f"introduce returned a capability, got {reply!r}"
        assert via is not None, "the redeemed reply surfaces its direct exporter session"
        assert via is not carol, "`via` is the direct exporter connection, not the broker one"
        assert via.host is carol.host, "the redeem shares Carol's Host"

        # The reply inbox is hosted where the reply lives, and the DM goes out
        # on that same connection: Bob's answer is his call back into it.
        inbox = via.spawn(lambda verb, args: acked.append(args[0]))
        note = await via.send(reply, "dm", ["hello bob", inbox])
        assert delivered == ["hello bob"], f"the DM reached Bob directly, got {delivered!r}"
        assert acked == ["bob got hello bob"], f"Bob called the reply inbox back, got {acked!r}"
        assert note is None, f"the forwarded answer settles from the inbox, got {note!r}"

        # Deterministic re-redeem: the second introduction routes to the
        # exporter already dialed, so `via` is that same live session.
        again = await carol.send_redeeming(introducer, "introduce", [])
        assert again.via is via, "a re-redeem resolves the same exporter session, no second dial"

        # A reply that is no capability at all has no exporter to name.
        plain = await carol.send_redeeming(introducer, "ping", [])
        assert plain.reply == "no capability here", plain.reply
        assert plain.via is None, "a non-capability reply names no exporter session"

        await carol.close()
        await broker_to_bob.close()
    finally:
        for task in accepting:
            task.cancel()
        broker.close()
        bob.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"python zig-smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
