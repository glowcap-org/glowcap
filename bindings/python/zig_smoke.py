"""Python dogfood of the Zig pancake C ABI archives, through the idiomatic
``pancake`` module: drive OCapN with native Python values, no FFI in sight.
The public ``connect`` / ``listen`` scenarios run over the native loop
archive (``libpancake_driver``, ADR-0112); the keyed-relay byte seam is tested
only through its explicit low-level adapter. This is the consumer ``zig build
bindings`` runs."""

from __future__ import annotations

import asyncio
import gc
import re
import sys
import select
import socket
import threading
import time

import ctypes
import pancake
import pancake._host as _host_module

from pancake import (
    Context,
    FetchFailed,
    Forward,
    Keyword,
    Locator,
    Host,
    PancakeError,
    SendRedeemingResult,
    Ref,
    Set,
    Symbol,
    Tagged,
    VowBroken,
    abi_version,
    connect,
    encode_peer_locator,
    format_sturdyref,
    listen,
    listen_keyed_tcp,
    parse_sturdyref,
    socket_addr_designator,
    tcp_locator,
)
from pancake._constants import (
    DESIGNATOR_SCHEME_ADDRESS,
    ERR_FRAME_TOO_LARGE,
    ERR_INVALID_ARGUMENT,
    TRANSPORT_TCP,
)
from pancake.inproc import InprocNetlayer
from pancake._trampoline import _entry_for
from pancake.onion import (
    AUTH_COOKIE,
    AUTH_PASSWORD,
    OnionNetlayer,
    SERVICE_ID_LENGTH,
    install_provider as install_onion_provider,
)
from pancake.tcp import TcpNetlayer


def main() -> int:
    sturdyref = parse_sturdyref(
        "ocapn://wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd.onion/s/"
        "eQjP4nR28ffX5eoNCK5DWH6DT_d7BIqD3-My459CUbU"
    )
    assert sturdyref.locator.transport == "onion"
    assert sturdyref.swissnum == bytes.fromhex(
        "79 08 cf e2 74 76 f1 f7 d7 e5 ea 0d 08 ae 43 58 "
        "7e 83 4f f7 7b 04 8a 83 df e3 32 e3 9f 42 51 b5"
    )
    formatted_sturdyref = format_sturdyref(
        "ocapn://127.0.0.1%3A9045.tcp", b"durable:0123456789abcdef"
    )
    assert parse_sturdyref(formatted_sturdyref).swissnum == b"durable:0123456789abcdef"

    try:
        Ref(1)
        raise AssertionError("application code must not construct capability ids")
    except TypeError:
        pass

    # The linked library reports a nonzero ABI version.
    major, minor, patch = abi_version()
    assert major + minor + patch > 0, (major, minor, patch)

    for invalid_seed in (b"\0" * 31, b"\0" * 33):
        try:
            Host(seed=invalid_seed)
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("Host must reject a seed that is not 32 bytes")

    caller_seed = bytearray(range(32))
    owned_seed_host = Host(seed=caller_seed)
    try:
        expected_designator = owned_seed_host.designator()
        caller_seed[0] ^= 0xFF
        assert owned_seed_host.designator() == expected_designator
        assert owned_seed_host.seed == bytes(range(32))
    finally:
        owned_seed_host.release()

    locator_host = Host()
    locator_host.set_advertised_locator(Locator("tcp", "127.0.0.1:7441", {}))
    locator_host.remove_advertised_locator("tcp")
    locator_host.close_sessions()
    locator_host.release()

    async def make_loop_bound_host() -> Host:
        return Host()

    stopped_loop = asyncio.new_event_loop()
    stopped_host = stopped_loop.run_until_complete(make_loop_bound_host())
    assert not stopped_loop.is_running() and not stopped_loop.is_closed()
    stopped_host.release()
    assert stopped_host.released, (
        "release must not queue cleanup onto a stopped event loop"
    )
    stopped_loop.close()

    stopped_work_loop = asyncio.new_event_loop()
    stopped_work_finished = False

    async def make_host_with_active_work() -> Host:
        host = Host()
        started = asyncio.Event()

        async def pending() -> None:
            nonlocal stopped_work_finished
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped_work_finished = True

        host.start_dial_task(pending)
        await started.wait()
        return host

    stopped_work_host = stopped_work_loop.run_until_complete(
        make_host_with_active_work()
    )
    stopped_work_host.release()
    assert stopped_work_finished, "stopped-loop release did not join active work"
    assert stopped_work_host._raw is None, (
        "stopped-loop release retained the native Host after joining work"
    )
    stopped_work_loop.close()

    # Collection is not an operational Host verb and may run on any Python
    # thread. The finalizer therefore owns raw teardown state rather than
    # trying to hop a dead event loop or touching the collected wrapper.
    async def make_finalizable_host() -> tuple[Host, int]:
        host = Host()
        # Deliberately close the ownership cycle: Host -> behavior -> Host.
        # The process-global trampoline lookup must not turn it into a root.
        host.publish_giftable(
            "finalized",
            lambda _verb, _args: host.released,
        )
        return host, host._giftables["finalized"]

    finalizer_loop = asyncio.new_event_loop()
    finalized, finalized_ctx = finalizer_loop.run_until_complete(
        make_finalizable_host()
    )
    handoff = [finalized]
    del finalized
    finalizer_loop.close()

    def collect_host() -> None:
        handoff.pop()
        gc.collect()

    collector = threading.Thread(target=collect_host)
    collector.start()
    collector.join()
    assert _entry_for(finalized_ctx) is None, (
        "off-thread Host finalization must retire native and trampoline authority"
    )

    # A finalizer release refused outside a callback transfers to one process
    # retry owner. The next safe Host boundary retries it instead of retaining
    # the raw Host and allocator context forever.
    original_host_release = _host_module._host.pancake_host_release
    attempts = 0

    def refuse_once(_raw) -> int:
        nonlocal attempts
        attempts += 1
        return ERR_INVALID_ARGUMENT if attempts == 1 else 0

    retry_state = _host_module._HostFinalizerState(ctypes.c_void_p(1), {}, [], {}, None)
    _host_module._host.pancake_host_release = refuse_once
    try:
        _host_module._release_finalizer_state(retry_state, checked=False)
        assert _host_module._pending_finalizer_retry_count() == 1
        _host_module._drain_deferred_finalizer_states()
        assert retry_state.raw is None
        assert _host_module._pending_finalizer_retry_count() == 0
        assert attempts == 2
    finally:
        _host_module._host.pancake_host_release = original_host_release

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
        client.write_frame(b"<8'op:abort3\"bye>")
        thread.join()
        assert received == [b"<8'op:abort3\"bye>"], received
    assert client._native.closed and listener._native.closed, (
        "TCP netlayer release must retire its borrowed child handles first"
    )
    client.close()
    listener.close()

    # A dropped wrapper still owns its native handle. Listener collection must
    # stop accepting, and endpoint collection must close the connected socket;
    # otherwise the parent's WeakSet silently forgets leaked C authority.
    with TcpNetlayer() as nl:
        orphan_listener = nl.listen("127.0.0.1", 0)
        orphan_port = orphan_listener.port()
        del orphan_listener
        gc.collect()
        with socket.socket() as probe:
            probe.settimeout(1)
            assert probe.connect_ex(("127.0.0.1", orphan_port)) != 0

        listener = nl.listen("127.0.0.1", 0)
        peer = socket.create_connection(("127.0.0.1", listener.port()), timeout=1)
        orphan_endpoint = listener.accept()
        del orphan_endpoint
        gc.collect()
        peer.settimeout(1)
        assert peer.recv(1) == b""
        peer.close()
        listener.close()

    # ctypes may release the GIL in every blocking transport call. Closing a
    # connection or its owner must interrupt a blocked read, join that lease,
    # and only then free native storage.
    nl = TcpNetlayer()
    listener = nl.listen("127.0.0.1", 0)
    peer = socket.create_connection(("127.0.0.1", listener.port()), timeout=1)
    accepted = listener.accept()
    entered = threading.Event()
    read_errors: list[BaseException] = []

    def blocked_tcp_read() -> None:
        entered.set()
        try:
            accepted.read_frame()
        except BaseException as exc:
            read_errors.append(exc)

    reader = threading.Thread(target=blocked_tcp_read, daemon=True)
    reader.start()
    assert entered.wait(1)
    time.sleep(0.05)
    accepted.close()
    reader.join(timeout=2)
    assert not reader.is_alive(), "TCP close did not join a blocked read"
    assert read_errors, "TCP shutdown did not interrupt a blocked read"
    peer.close()
    listener.close()
    nl.release()

    nl = TcpNetlayer()
    listener = nl.listen("127.0.0.1", 0)
    entered = threading.Event()
    accept_errors: list[BaseException] = []

    def blocked_tcp_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_tcp_accept, daemon=True)
    accepter.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "TCP owner release did not join a blocked accept"
    assert accept_errors, "TCP listener shutdown did not interrupt a blocked accept"

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
        client.write_frame(b"<8'op:abort3\"bye>")
        thread.join()
        assert received_inproc == [b"<8'op:abort3\"bye>"], received_inproc
    assert client._native.closed and listener._native.closed, (
        "inproc netlayer release must retire its borrowed child handles first"
    )
    client.close()
    listener.close()

    with InprocNetlayer() as nl:
        orphan_listener = nl.listen("orphan-smoke")
        del orphan_listener
        gc.collect()
        try:
            nl.connect("orphan-smoke")
        except PancakeError:
            pass
        else:
            raise AssertionError("a collected inproc listener kept native authority")

    nl = InprocNetlayer()
    listener = nl.listen("blocked-read")
    client = nl.connect("blocked-read")
    accepted = listener.accept()
    entered = threading.Event()
    read_errors = []

    def blocked_inproc_read() -> None:
        entered.set()
        try:
            accepted.read_frame()
        except BaseException as exc:
            read_errors.append(exc)

    reader = threading.Thread(target=blocked_inproc_read, daemon=True)
    reader.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    reader.join(timeout=2)
    assert not reader.is_alive(), "inproc owner release did not join a blocked read"
    assert read_errors, "inproc shutdown did not interrupt a blocked read"
    client.close()

    nl = InprocNetlayer()
    listener = nl.listen("blocked-accept")
    entered = threading.Event()
    accept_errors = []

    def blocked_inproc_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_inproc_accept, daemon=True)
    accepter.start()
    assert entered.wait(1)
    time.sleep(0.05)
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "inproc owner release did not join a blocked accept"
    assert accept_errors, "inproc listener shutdown did not interrupt a blocked accept"

    print(
        "python zig-smoke OK: the blocking TCP and in-process transports shuttled a frame"
    )

    _onion_against_a_fake_daemon()
    print(
        "python zig-smoke OK: the onion transport reached a fake Tor and reported its service"
    )

    _loop_archive_stepping_parity()
    print(
        "python zig-smoke OK: the public Session surface ran over the driver archive — connect, fetch, an eventual-send round trip, VowBroken, and close"
    )

    asyncio.run(_allocator_context_round_trip())
    print(
        "python zig-smoke OK: drove a published counter round-trip from a context-backed Host"
    )

    asyncio.run(_live_trace_produces_timeline())
    print(
        "python zig-smoke OK: the live trace produced the timeline schema for a whole conversation"
    )

    asyncio.run(_async_behavior_defers())
    print(
        "python zig-smoke OK: an async behavior deferred its answer onto a resolver vow and settled off-turn"
    )

    asyncio.run(_capnp_codec_round_trip())
    print(
        "python zig-smoke OK: a capnp session opens and big-integer + keyword args round-trip"
    )

    asyncio.run(_empty_codec_is_not_the_default())
    print(
        "python zig-smoke OK: an empty codec offer is refused, not rewritten as Syrup"
    )

    asyncio.run(_feed_refusals_are_typed())
    print(
        "python zig-smoke OK: an over-cap frame refuses typed and a refused frame carries its abort cause"
    )

    asyncio.run(_tightened_admission_cap_refuses())
    print(
        "python zig-smoke OK: a tightened session limit refuses a frame the default cap admits"
    )

    asyncio.run(_disconnect_rejects_pending_send())
    print("python zig-smoke OK: an outstanding send rejects on disconnect")

    asyncio.run(_listen_surfaces_bound_port())
    print(
        "python zig-smoke OK: high-level listen() surfaces the bound port and accepts"
    )

    asyncio.run(_rude_probe_cannot_close_the_listener())
    print("python zig-smoke OK: a rude probe cannot close the listener")

    asyncio.run(_supplied_host_tcp_listener_ownership())
    print(
        "python zig-smoke OK: supplied TCP Hosts transfer to the driver transactionally"
    )

    asyncio.run(_listener_close_preserves_sibling())
    print("python zig-smoke OK: closing one listener preserves a sibling listener")

    asyncio.run(_host_release_joins_dial_task())
    print("python zig-smoke OK: Host release joins every registered DIAL task")

    asyncio.run(_supplied_host_iroh_listener_ownership())
    print("python zig-smoke OK: supplied iroh Hosts transfer to the resident driver")

    asyncio.run(_proof_refusal_releases_minted_session())
    print("python zig-smoke OK: proof refusal releases the newly minted session")

    asyncio.run(_cancelled_iroh_open_releases_constructed_endpoint())
    print("python zig-smoke OK: canceled iroh startup joins and releases its endpoint")

    asyncio.run(_iroh_release_async_joins_after_cancellation())
    print("python zig-smoke OK: canceled iroh release still joins native teardown")

    asyncio.run(_session_close_joins_owned_transport_release())
    print("python zig-smoke OK: Session.close joins owned transport teardown")

    asyncio.run(_structured_args_round_trip())
    print(
        "python zig-smoke OK: a Set round-trips as a Set, a nested capability stays sendable, a break is typed"
    )

    asyncio.run(_enliven_round_trips_then_caches())
    print(
        "python zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache"
    )

    asyncio.run(_gc_releases_dropped_import())
    print(
        "python zig-smoke OK: a dropped fetched import releases its export when GC is opted in"
    )

    asyncio.run(_fetch_failed_is_typed())
    print("python zig-smoke OK: a non-capability fetch raises the typed FetchFailed")

    asyncio.run(_pipelining_drives_chain())
    print(
        "python zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch"
    )

    asyncio.run(_turn_spawn_survives_originating_port_close())
    print(
        "python zig-smoke OK: turn-time spawn uses the Host after the originating Port closes"
    )

    asyncio.run(_unawaited_break_stays_silent())
    print(
        "python zig-smoke OK: an unawaited send is an asyncio.Future whose far break stays silent"
    )

    asyncio.run(_projections_reach_a_field())
    print(
        "python zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles"
    )

    asyncio.run(_forwarding_proxies_over_the_wire())
    print(
        "python zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire"
    )

    asyncio.run(_forwarding_proxy_local_call())
    print(
        "python zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)"
    )

    asyncio.run(_mid_turn_driving_verb_breaks_the_answer())
    print(
        "python zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer"
    )

    asyncio.run(_mid_turn_host_release_orders_sessions_before_host())
    print("python zig-smoke OK: callback-time Host release defers one driver teardown")

    asyncio.run(_send_redeeming_surfaces_the_direct_exporter())
    print(
        "python zig-smoke OK: send_redeeming surfaces the redeemed exporter session, and a reply capability hosted on it routes"
    )
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
            server_reader, server_writer = await asyncio.open_connection(
                "127.0.0.1", target_port
            )
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
                        observe(chunk, rewriting)
                    dst.write(
                        rewrite(chunk) if (rewriting and rewrite is not None) else chunk
                    )
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


async def _live_trace_produces_timeline() -> None:
    """The live timeline producer: the veneer stamps and forwards the native
    tap's facts, one flat record per fact -- session-opened with the codec
    the handshake actually negotiated, the same verb outbound at the client
    and inbound at the server, and session-closed. Endpoint labeling belongs
    to the consumer, so the records carry only the session and direction."""
    from pancake import annotate_session, enable_trace

    events: list = []
    host = Host()

    def record_then_raise(event) -> None:
        events.append(event)
        raise RuntimeError("trace sink failure must stay observer-only")

    # Trace configuration is process-global, but every native Host remains
    # owner-thread confined. Installing from a worker must hop back to this
    # loop rather than calling through a retained raw pointer.
    uninstall = await asyncio.to_thread(
        lambda: enable_trace(record_then_raise, self_label="smoke")
    )
    host.publish_giftable("greeter", lambda verb, args: f"hello {verb}")
    server = await listen("127.0.0.1", 0, host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await connect(tcp_locator("127.0.0.1", server.port))
        client.serve()
        greeter = await client.fetch("greeter")
        reply = await client.send(greeter, "trace-me", [])
        assert reply == "hello trace-me", f"traced call answers, got {reply!r}"
        # The annotation channel: the application states which partner a
        # session carries, named for the same session row the tap names.
        annotate_session(client, label="greeter-server")
        await client.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close_async()
    await host.release_async()
    await asyncio.to_thread(uninstall)

    opened = [ev for ev in events if ev["kind"] == "ocapn.session-opened"]
    assert len(opened) >= 2, f"both hosts' opens reached the one sink: {events}"
    assert all(ev["codec"] == "syrup" and ev["a_label"] == "smoke" for ev in opened)
    # And what this producer RUNS, because this schema is not pancake's alone:
    # a consumer must not read an implementation off the fact that a record
    # arrived, so a pancake host says so in words.
    assert all(ev["a_profile"] == "pancake" for ev in opened)
    # Identity and label are two facts. ``a`` is the host's own key designator
    # -- the name a partner knows it by, and so the only name two producers can
    # agree on -- and the label never stands in for it.
    assert all(re.fullmatch(r"[0-9a-f]{64}", ev["a"]) for ev in opened)
    # The OCapN Session ID is what lets a consumer merging two producers'
    # feeds tell one session watched twice from two unrelated ones: both peers
    # of a session derive it to the same value.
    assert all(ev.get("session_id") == opened[0].get("session_id") for ev in opened)
    assert re.fullmatch(r"[0-9a-f]{64}", opened[0].get("session_id", ""))
    outbound = [
        ev
        for ev in events
        if ev["kind"] == "ocapn.message-decoded"
        and ev.get("op") == "trace-me"
        and ev["outbound"]
    ]
    assert outbound, "the client's send traced outbound"
    inbound = [
        ev
        for ev in events
        if ev["kind"] == "ocapn.message-decoded"
        and ev.get("op") == "trace-me"
        and not ev["outbound"]
    ]
    assert inbound, "the server's deliver traced inbound"
    assert inbound[0]["session"] != outbound[0]["session"], (
        "each host names its own session row"
    )
    # Payload: both fact sites sit at the wire boundary (inbound dispatch,
    # the outbound drain), so both records carry the whole (sub-cap) frame
    # with its true length and the verb inside it.
    import base64 as _b64mod

    for rec in (inbound[0], outbound[0]):
        frame = _b64mod.b64decode(rec["bytes_b64"])
        assert rec["len"] == len(frame), "true length rides beside the frame"
        assert b"trace-me" in frame, "the frame bytes contain the delivered verb"
    assert any(ev["kind"] == "ocapn.session-closed" for ev in events)
    metas = [ev for ev in events if ev["kind"] == "ocapn.session-meta"]
    assert metas and metas[0]["meta"]["label"] == "greeter-server", (
        "the annotation reached the sink with its label"
    )
    assert metas[0]["session"] == outbound[0]["session"], (
        "the annotation names the same session row the tap names"
    )
    stamps = [ev["sim_t_ns"] for ev in events]
    assert stamps == sorted(stamps), "sim_t_ns is monotone"


async def _async_behavior_defers() -> None:
    """An async behavior (off-turn settlement): the worker returns a
    coroutine, the binding defers the turn's answer onto a resolver vow, and
    the settle re-enters as its own task after real awaited work, so the
    host's turn loop never blocks on it. A raise crosses as the caller's
    break carrying the behavior's own words."""
    host = Host()

    async def work(verb, args):
        await asyncio.sleep(0.005)
        if verb == "fail":
            raise ValueError("worker gave up")
        if verb == "unsupported":
            return object()
        return "computed off-turn"

    host.publish_giftable("worker", work)
    server = await listen("127.0.0.1", 0, host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await connect(tcp_locator("127.0.0.1", server.port))
        client.serve()
        worker = await client.fetch("worker")
        reply = await client.send(worker, "work", [])
        assert reply == "computed off-turn", f"async behavior reply, got {reply!r}"
        try:
            await client.send(worker, "fail", [])
        except VowBroken as broke:
            assert "worker gave up" in str(broke), (
                f"async raise carries the reason, got {broke!s}"
            )
        else:
            raise AssertionError("an async behavior's raise must break the caller")
        try:
            await client.send(worker, "unsupported", [])
        except VowBroken as broke:
            assert "unsupported" in str(broke).lower(), (
                f"async marshal failure carries the reason, got {broke!s}"
            )
        else:
            raise AssertionError("an unsupported async result must break the caller")
        await client.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        server.close()
    await host.release_async()


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
        # Closing an allocation scope is a request: the live Host retains its
        # policy until teardown, while the closing Context refuses new families.
        ctx.close()
        try:
            Host(context=ctx)
        except RuntimeError:
            pass
        else:
            raise AssertionError("a released Context must refuse a new Host")
        count = {"value": 10}

        def counter(verb, args):
            if verb == "add":
                count["value"] += args[0]
                return count["value"]
            if verb == "get":
                return count["value"]
            raise ValueError(f"no such method {verb!r}")

        host.publish_giftable("counter", counter)
        server = await listen("127.0.0.1", 0, host)
        try:

            async def serve_one() -> None:
                async for session in server:
                    local_counter = session.published_ref("counter")
                    assert local_counter is not None, (
                        "the Host alias projects onto the accepted session"
                    )
                    assert await session.send(local_counter, "get", []) == 10
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

            # Alias-only unpublish: discovery moves, the issued capability does
            # not. A removed alias misses even on the session that fetched it,
            # a second removal is a loud miss, and the ref still answers.
            assert host.unpublish_giftable("counter") is True
            assert host.unpublish_giftable("counter") is False
            try:
                await client.fetch("counter")
            except VowBroken:
                pass
            else:
                raise AssertionError("fetch of an unpublished alias must break")
            still = await client.send(counter_ref, "get", [])
            assert still == 15, f"issued ref survives unpublish, got {still!r}"

            # Durable publication (ADR-0098): the minted swiss name fetches on
            # the live session, removal makes a later fetch miss, and the
            # capability issued before removal still answers.
            swiss = host.publish_durable(counter)
            assert swiss.startswith("pancake-durable-1-") and len(swiss) == 50, swiss
            durable_ref = await client.fetch(swiss)
            assert await client.send(durable_ref, "get", []) == 15
            assert host.remove_durable(swiss) is True
            assert host.remove_durable(swiss) is False
            try:
                await client.fetch(swiss)
            except VowBroken:
                pass
            else:
                raise AssertionError("fetch of a removed durable name must break")
            kept = await client.send(durable_ref, "get", [])
            assert kept == 15, f"issued ref survives remove_durable, got {kept!r}"
            await client.close()
            await asyncio.wait_for(hosted, timeout=5)
        finally:
            server.close()
        await host.release_async()
        assert stats["allocs"] > 0, "the host allocator serviced the Host"
        assert not live, "Context release returned every custom allocation"


async def _capnp_codec_round_trip() -> None:
    """The codec selector end-to-end: both nodes minted with the Cap'n Proto
    wire grammar complete the keyed handshake and carry a deliver whose
    arguments round-trip through the capnp codec — a big integer past int64 and
    a Keyword included, so the two rare marshal arms are witnessed alongside
    the codec."""
    big = 2**80
    server = await listen("127.0.0.1", 0, codec="capnp")
    published = asyncio.Event()
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
                published.set()
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port), codec="capnp")
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [big, Keyword("prio"), b"hi"])
        assert isinstance(reply, Keyword) and reply == "done", reply
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close_async()


async def _empty_codec_is_not_the_default() -> None:
    """An omitted codec gets the Goblins-compatible floor. An explicit empty
    codec is not omission: it is invalid input and must fail before a socket is
    opened or a Host is minted with Syrup by accident."""
    for verb, action in (
        ("listen", lambda: listen("127.0.0.1", 0, codec="")),
        ("connect", lambda: connect(tcp_locator("127.0.0.1", 1), codec="")),
    ):
        try:
            opened = await action()
        except ValueError as exc:
            assert "unknown OCapN codec" in str(exc), (verb, exc)
        else:
            close = getattr(opened, "close", None)
            if close is not None:
                result = close()
                if hasattr(result, "__await__"):
                    await result
            raise AssertionError(f"{verb} accepted an empty codec")


class _InjectTransport:
    """A transport that delivers nothing, so a scene can feed bytes through the
    session's own feed seam — a binding-internal probe, the sibling of the
    Racket smoke's ``feed-bytes!``."""

    designator_scheme = DESIGNATOR_SCHEME_ADDRESS

    async def read(self):
        await asyncio.get_running_loop().create_future()  # never resolves

    async def write(self, data):
        pass

    def close(self):
        pass


def _dial_injected(host: Host):
    from pancake._session import Session as _Session

    return _Session._open_dialed_locator(
        host, TRANSPORT_TCP, socket_addr_designator("127.0.0.1", 1), _InjectTransport()
    )


async def _feed_refusals_are_typed() -> None:
    """Bounded inbox and typed abort causes over the byte-fed host. A frame
    declaring more than the frame cap is a typed refusal the moment that is
    knowable, never "read more" (ADR-0041); a refused frame names its typed
    cause (the flat PancakeError code says the failure family, the attached
    AbortDetail says the member)."""
    from pancake import _pump

    # Over-cap: the length prefix declares past the cap, refused during the scan.
    # Bytes ride the named pump module (`_pump._feed`), not a Session verb.
    session = _dial_injected(Host())
    try:
        await _pump._feed(session, b"2000000:")
        raise AssertionError("an over-cap frame must refuse typed instead of buffering")
    except PancakeError as exc:
        assert exc.code == ERR_FRAME_TOO_LARGE, exc.code
    finally:
        session.close_transport()

    # Garbage: the refusal carries the typed abort detail.
    session = _dial_injected(Host())
    try:
        assert session.last_abort() is None, "no dispatch failure recorded yet"
        try:
            await _pump._feed(session, b"this is not a frame")
            raise AssertionError("feeding garbage must raise")
        except PancakeError as exc:
            assert exc.abort is not None, "the refused frame carries its typed cause"
            assert exc.abort.domain == "codec", exc.abort
            assert exc.abort.kind == "MalformedFrame", exc.abort
            assert exc.abort.error_name == "MalformedFrame", exc.abort
    finally:
        session.close_transport()


async def _tightened_admission_cap_refuses() -> None:
    """``Host.set_session_limits`` moves the admission cap the sessions minted
    after it are held to (ADR-0082). One frame decides it: at the default cap a
    4000-byte declaration is simply incomplete, and at a tightened 1024 the same
    prefix is a typed over-cap refusal."""
    from pancake import _pump

    prefix = b"4000:"

    session = _dial_injected(Host())
    try:
        await _pump._feed(session, prefix)  # under the default cap: still incomplete
    finally:
        session.close_transport()

    tightened = Host()
    tightened.set_session_limits(max_frame_bytes=1024)
    session = _dial_injected(tightened)
    try:
        await _pump._feed(session, prefix)
        raise AssertionError("a tightened admission cap must refuse an over-cap frame")
    except PancakeError as exc:
        assert exc.code == ERR_FRAME_TOO_LARGE, exc.code
    finally:
        session.close_transport()


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server serves one call and
    then closes without warning; the client's next awaited send settles with a
    typed rejection once the disconnect lands."""
    server = await listen("127.0.0.1", 0)
    closed = asyncio.Event()
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                session.serve()
                published.set()
                await asyncio.sleep(0.05)
                await session.close()
                closed.set()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()  # a disconnect ends the serve task; expected here
        await asyncio.wait_for(published.wait(), timeout=5)
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
        identity_checked = asyncio.Event()

        async def accept_one() -> None:
            async for session in server:
                accepted.append(session)
                await identity_checked.wait()
                await session.close()
                break

        accept_task = asyncio.ensure_future(accept_one())
        client = await connect(tcp_locator("127.0.0.1", port))
        expected = encode_peer_locator(Locator(
            TRANSPORT_TCP,
            socket_addr_designator(("127.0.0.1", port)),
            {},
            "boolean-false",
        ))
        assert client.partner_identity().locator_record == expected, (
            "the accepted host advertised the listener's complete locator record"
        )
        identity_checked.set()
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
    published = asyncio.Event()
    try:
        port = server.port

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: Symbol("alive"))
                published.set()
                session.serve()
                break  # one real client is the proof

        served = asyncio.ensure_future(serve_one())

        # The probe: a raw socket that opens and immediately hangs up.
        probe_reader, probe_writer = await asyncio.open_connection("127.0.0.1", port)
        probe_writer.close()
        del probe_reader

        session = await connect(tcp_locator("127.0.0.1", port))
        await asyncio.wait_for(published.wait(), timeout=5)
        svc = await session.fetch("svc")
        reply = await session.send(svc, "ping", [])
        assert reply == Symbol("alive"), reply
        await session.close()
        await asyncio.wait_for(served, timeout=5)
    finally:
        server.close()


async def _supplied_host_tcp_listener_ownership() -> None:
    """A supplied TCP Host is the exact wrapper adopted by the driver.

    Closing the listener seals admission but does not release the yielded
    session; the final Host release happens only after that session closes.
    """
    supplied = Host()
    server = await listen("127.0.0.1", 0, host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, (
            "listener did not preserve the supplied Host wrapper"
        )
        client = await connect(tcp_locator("127.0.0.1", server.port))
        accepted = await asyncio.wait_for(accepted_task, timeout=5)
        accepted.publish("svc", lambda verb, args: Symbol("alive"))
        accepted.serve()

        close_tasks = server.close()
        await asyncio.sleep(0)
        assert not supplied.released, "listener close released a yielded supplied Host"
        svc = await client.fetch("svc")
        assert await client.send(svc, "ping", []) == Symbol("alive")
        await accepted.close()
        await client.close()
        await asyncio.gather(*close_tasks)
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.release_async()


async def _supplied_host_iroh_listener_ownership() -> None:
    """The iroh resident uses the same supplied Host and driver barrier."""
    from pancake.iroh import IrohConfig, Reachability, listen_iroh

    supplied = Host(seed=b"pancake-supplied-iroh-seed-000000"[:32])
    server = await listen_iroh(IrohConfig(Reachability.LOCAL_DISCOVERY), host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, (
            "iroh listener did not preserve the supplied Host wrapper"
        )
        client = await connect(server.uri, Reachability.LOCAL_DISCOVERY)
        accepted = await asyncio.wait_for(accepted_task, timeout=10)
        close_task = asyncio.create_task(server.close())
        await asyncio.sleep(0)
        assert not supplied.released, (
            "iroh listener close released a yielded supplied Host"
        )
        await accepted.close()
        await client.close()
        await close_task
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.release_async()


async def _listener_close_preserves_sibling() -> None:
    """Closing one listener leaves a sibling provider on the same Host usable."""
    supplied = Host()
    tcp_server = await listen("127.0.0.1", 0, host=supplied)
    keyed_server = await listen_keyed_tcp("127.0.0.1", 0, host=supplied)
    client = None
    accepted = None
    try:
        tcp_server.close()
        client = await connect(keyed_server.uri())
        accepted = await asyncio.wait_for(keyed_server.__anext__(), timeout=5)
        assert not supplied.released, "closing one listener released the shared Host"
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        keyed_server.close()
        if not supplied.released:
            await supplied.release_async()


async def _host_release_joins_dial_task() -> None:
    """A registered DIAL executor is canceled and finished before Host teardown.

    The fake executor is installed at the action seam that creates the task,
    so this proves the real Host registry and done
    callback rather than a second test-only task list.
    """
    import pancake._dial as dial_module

    original = dial_module.run_dial_ticket
    started = asyncio.Event()
    finished = asyncio.Event()

    async def pending_dial(_host, _ticket) -> None:
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            finished.set()

    dial_module.run_dial_ticket = pending_dial
    host = Host()
    try:
        # Drive the same generated action dispatcher production uses. The DIAL
        # arm must return after transferring ownership to Host, not await the
        # network operation inline and serialize every later action behind it.
        from pancake._action import _run_action
        from pancake._host_action_gen import Dial

        await _run_action(host, Dial(ticket=7))
        await asyncio.wait_for(started.wait(), timeout=1)
        host.release()
        assert host._release_started, "synchronous release did not make close terminal"
        assert host._raw is not None, "native Host freed before canceled DIAL cleanup"
        await host.release_async()
        assert finished.is_set(), "Host release returned before DIAL cleanup finished"
        assert host._raw is None, (
            "Host release retained native authority after DIAL cleanup"
        )
        assert not host._dial_tasks, (
            "the Host-owned DIAL registry retained a finished task"
        )
    finally:
        dial_module.run_dial_ticket = original
        if host._raw is not None:
            await host.release_async()


async def _proof_refusal_releases_minted_session() -> None:
    """Failure between native mint and handshake has one teardown owner."""
    import pancake._session as session_module

    class Transport:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS
        close_count = 0

        def close(self) -> None:
            self.close_count += 1

    host = Host()
    host.set_advertised_locator(Locator(
        TRANSPORT_TCP,
        socket_addr_designator("127.0.0.1", 1),
        {},
    ))
    transport = Transport()
    releases = 0
    original_bind = session_module._host.pancake_host_session_bind_verified_channel_key
    original_release = session_module._host.pancake_host_session_release

    def refuse_proof(*_args) -> int:
        return ERR_INVALID_ARGUMENT

    def count_release(raw) -> None:
        nonlocal releases
        releases += 1
        original_release(raw)

    session_module._host.pancake_host_session_bind_verified_channel_key = refuse_proof
    session_module._host.pancake_host_session_release = count_release
    try:
        try:
            await session_module.Session.establish_dialed_locator(
                host,
                TRANSPORT_TCP,
                "127.0.0.1:2",
                transport,
                verified_channel_key="00" * 32,
            )
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("a refused channel proof unexpectedly established")
        assert releases == 1, "proof refusal did not release exactly one native session"
        assert transport.close_count == 1, "proof refusal did not close its transport"
        assert not host._sessions, "proof refusal left a session registered on its Host"

        accepted_transport = Transport()
        try:
            await session_module.Session.establish_accepted(
                host,
                TRANSPORT_TCP,
                "127.0.0.1:2",
                accepted_transport,
                accepted_local_addr="127.0.0.1:2",
                verified_channel_key="00" * 32,
            )
        except PancakeError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError(
                "a refused accepted-channel proof unexpectedly established"
            )
        assert releases == 2, (
            "accepted proof refusal did not release exactly one session"
        )
        assert accepted_transport.close_count == 1, (
            "accepted proof refusal did not close its transport"
        )
        assert not host._sessions, (
            "accepted proof refusal left a session registered on its Host"
        )
    finally:
        session_module._host.pancake_host_session_bind_verified_channel_key = (
            original_bind
        )
        session_module._host.pancake_host_session_release = original_release
        await host.release_async()


async def _cancelled_iroh_open_releases_constructed_endpoint() -> None:
    """Cancellation cannot abandon an endpoint still constructing off-thread."""
    from pancake.iroh import IrohConfig, IrohNetlayer, Reachability

    started = threading.Event()
    finish = threading.Event()
    released = threading.Event()

    class ControlledNetlayer(IrohNetlayer):
        def __init__(
            self, _config, _secret_seed=None, *, _construction_token=None
        ) -> None:
            started.set()
            finish.wait()

        async def release_async(self) -> None:
            released.set()

    opening = asyncio.create_task(
        ControlledNetlayer.open(IrohConfig(Reachability.DIRECT))
    )
    assert await asyncio.to_thread(started.wait, 1), "iroh constructor did not start"
    opening.cancel()
    finish.set()
    try:
        await opening
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled iroh startup returned an endpoint")
    assert released.is_set(), (
        "cancelled iroh startup abandoned the constructed endpoint"
    )


async def _iroh_release_async_joins_after_cancellation() -> None:
    """A canceled release waiter cannot detach the native release task."""
    from pancake.iroh import IrohNetlayer

    started = threading.Event()
    finish = threading.Event()
    calls = 0

    class ControlledNetlayer(IrohNetlayer):
        def __init__(self) -> None:
            self._release_task = None

        def release(self) -> None:
            nonlocal calls
            calls += 1
            started.set()
            finish.wait()

    netlayer = ControlledNetlayer()
    release = asyncio.create_task(netlayer.release_async())
    assert await asyncio.to_thread(started.wait, 1), "release did not start"
    release.cancel()
    await asyncio.sleep(0)
    assert not release.done(), "release waiter detached before native teardown"
    finish.set()
    try:
        await release
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("release cancellation was not preserved")

    await netlayer.release_async()
    assert calls == 1, "repeated release_async started a second native release"


async def _session_close_joins_owned_transport_release() -> None:
    """Session.close keeps its sync close seam but joins owned transport cleanup."""
    from pancake._session import Session

    started = asyncio.Event()
    finish = asyncio.Event()

    class HostStub:
        def _assert_owner(self) -> None:
            pass

    class TransportStub:
        closed = False

        def close(self) -> None:
            self.closed = True

        async def wait_closed(self) -> None:
            started.set()
            await finish.wait()

    transport = TransportStub()
    session = Session.__new__(Session)
    session._host = HostStub()
    session._transport = transport
    session._closing = False
    session.owns_host = False
    session._serve_task = None
    session.close_transport = transport.close

    closing = asyncio.create_task(session.close())
    await asyncio.wait_for(started.wait(), timeout=1)
    assert transport.closed, (
        "Session.close did not preserve synchronous transport close"
    )
    assert not closing.done(), "Session.close returned before transport completion"
    finish.set()
    await closing


async def _structured_args_round_trip() -> None:
    """A ``Set`` argument crosses the application surface as a ``Set`` (never a
    plain list), a capability nested in a Set or Tagged arrives as a sendable
    :class:`Ref`, and a partner break raises the typed :class:`VowBroken`."""
    server = await listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    if verb == "boom":
                        raise ValueError("kaboom")
                    assert verb == "probe", verb
                    probe_set = args[0]
                    assert type(probe_set) is Set, (
                        f"a Set argument arrives as a Set, got {type(probe_set).__name__}"
                    )
                    assert 1 in probe_set, probe_set
                    nested = next(
                        (item for item in probe_set if isinstance(item, Ref)), None
                    )
                    assert isinstance(nested, Ref), (
                        f"a capability inside a Set lifts to a Ref, got {nested!r}"
                    )
                    note = args[1]
                    assert isinstance(note, Tagged), (
                        f"a Tagged argument arrives as a Tagged, got {note!r}"
                    )
                    assert isinstance(note.value[0], Ref), note.value
                    # The nested capability is sendable: poke back through it.
                    asyncio.ensure_future(session.tell(nested, "poke", []))
                    return Set([Symbol("ok"), 7])

                session.publish("svc", svc)
                published.set()
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
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(
            svc_ref, "probe", [Set([1, inbox]), Tagged("note", [inbox])]
        )
        assert type(reply) is Set, (
            f"a Set reply survives the round-trip as a Set, got {type(reply).__name__}"
        )
        assert Symbol("ok") in reply and 7 in reply, reply
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
    server_host = Host()

    def greeter(verb, args):
        assert verb == "hello", verb
        return Symbol("alive")

    server_host.publish_giftable("greeter", greeter)
    server = await listen("127.0.0.1", 0, server_host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        locator = tcp_locator("127.0.0.1", server.port)
        session = await connect(locator)
        session.serve()
        try:
            await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
        except PancakeError as err:
            assert err.code == ERR_INVALID_ARGUMENT, err
        else:
            raise AssertionError("enliven accepted a sturdyref for another peer")
        # The complete sturdyref must name this selected session's peer.
        sturdyref = f"{locator}/s/Z3JlZXRlcg"
        cap = await session.enliven(sturdyref)
        greeting = await session.send(cap, "hello", [])
        assert greeting == Symbol("alive"), (
            f"enlivened cap answers hello, got {greeting!r}"
        )
        # A repeat enliven hits the dedup cache: the same live capability.
        again = await session.enliven(sturdyref)
        greeting2 = await session.send(again, "hello", [])
        assert greeting2 == Symbol("alive"), (
            f"cached enliven answers hello, got {greeting2!r}"
        )
        # Listen (CapTP ``op:listen``): a held capability's resolution comes
        # back through the vow -- a listen on an already-settled capability
        # answers at once.
        settled = await session.listen(cap)
        assert isinstance(settled, Ref), (
            f"listen settles naming the capability, got {settled!r}"
        )
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)

        # A sessionless Host selects the generic driver before its DIAL action
        # exists. The driver consumes that original action and exposes the
        # exporter session without a binding-side TCP branch.
        cold_serve = asyncio.ensure_future(serve_one())
        cold = Host()
        cold_cap = await cold.enliven(sturdyref)
        cold_exporter = cold.exporter_for(cold_cap)
        assert cold_exporter is not None, "cold enliven retains its exporter session"
        cold_greeting = await cold_exporter.send(cold_cap, "hello", [])
        assert cold_greeting == Symbol("alive"), cold_greeting
        await cold.release_async()
        await asyncio.wait_for(cold_serve, timeout=5)
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
    published = asyncio.Event()

    def observe(chunk: bytes, _to_server: bool) -> None:
        if b"op:gc-export" in chunk:
            saw_gc.set()

    relay_port, relay_close = await _start_relay(server.port, observe=observe)
    try:

        async def serve_one() -> None:
            async for session in server:
                session.publish("svc", lambda verb, args: None)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = (await connect(tcp_locator("127.0.0.1", relay_port))).with_gc()
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        cap = await session.fetch("svc")
        assert cap.id > 0, "the fetched cap has a Host identity"
        # Drop the only handle; refcounting fires the finalizer, which parks the
        # token and hops to the loop. Yield loop turns for it to flush.
        del cap
        for _ in range(200):
            if saw_gc.is_set():
                break
            await asyncio.sleep(0.01)
        assert saw_gc.is_set(), (
            "the wire never carried op:gc-export for the dropped import"
        )
        # The finalizer parked the release and hopped to the loop; observing
        # op:gc-export means it ran, so no parked release is left behind (parity
        # with the TypeScript, Rust, and Racket dogfoods, which assert the same).
        assert session._host.pending_release_count() == 0, (
            "the finalizer's parked release drained after the turn"
        )
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
    plain_export: list[int] = []
    observed_wire = bytearray()
    export_known = asyncio.Event()
    # Armed only after the legitimate fetch of "plain" has granted the export,
    # so only the second fetch is doctored.
    state = {"retargeted": False, "armed": False, "capturing": False}
    pending = bytearray()

    def observe(chunk: bytes, to_server: bool) -> None:
        if to_server or not state["capturing"] or plain_export:
            return
        observed_wire.extend(chunk)
        match = re.search(rb"desc:import-object(\d+)\+", observed_wire)
        if match is not None:
            plain_export.append(int(match.group(1)))

    def retarget(chunk: bytes) -> bytes:
        if not state["armed"] or not plain_export:
            return chunk
        if state["retargeted"] and not pending:
            return chunk
        needle = b"desc:export0+"
        pending.extend(chunk)
        output = bytearray()
        while pending:
            colon = pending.find(b":")
            if colon < 0:
                break
            prefix = pending[:colon]
            if not prefix.isdigit():
                # Preserve malformed input for the product parser to diagnose.
                output.extend(pending)
                pending.clear()
                break
            frame_end = colon + 1 + int(prefix)
            if len(pending) < frame_end:
                break
            body = bytes(pending[colon + 1 : frame_end])
            del pending[:frame_end]
            if not state["retargeted"] and needle in body:
                body = body.replace(needle, b"desc:export%d+" % plain_export[0], 1)
                state["retargeted"] = True
            output.extend(str(len(body)).encode())
            output.extend(b":")
            output.extend(body)
        return bytes(output)

    relay_port, relay_close = await _start_relay(
        server.port, rewrite=retarget, observe=observe
    )
    try:

        async def serve_one() -> None:
            async for session in server:
                # The doctored fetch deliver lands here with verb "fetch";
                # answer with a plain integer, which is exactly what a fetch
                # must not resolve to.
                session.publish("plain", lambda verb, args: 42)
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
        state["capturing"] = True
        await session.fetch("plain")
        for _ in range(100):
            if plain_export:
                break
            await asyncio.sleep(0)
        assert plain_export, "the granting fetch exposed no import-object descriptor"
        state["capturing"] = False
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
    published = asyncio.Event()
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
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
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


async def _turn_spawn_survives_originating_port_close() -> None:
    """An actor first published through one Port remains a Host actor. Close
    that Port, call it through a sibling, then use the captured stale Session
    handle to spawn a child inside the sibling's turn. Host ownership selects
    turn-spawn; the dead Session is not consulted for routing."""
    server = await listen("127.0.0.1", 0)
    ready = asyncio.Event()
    try:

        async def host() -> None:
            accepted = []
            async for session in server:
                session.serve()
                accepted.append(session)
                if len(accepted) == 1:
                    origin = session

                    def root(verb, args):
                        assert verb == "create", verb
                        return origin.spawn(
                            lambda child_verb, child_args: (
                                "alive" if child_verb == "ping" else None
                            )
                        )

                    root_ref = origin.spawn(root)
                    continue

                session.publish(
                    "introducer",
                    lambda verb, args: root_ref if verb == "get" else None,
                )
                await accepted[0].close()
                ready.set()
                await session.serve()
                break

        hosted = asyncio.ensure_future(host())
        origin_client = await connect(tcp_locator("127.0.0.1", server.port))
        origin_client.serve()
        sibling = await connect(tcp_locator("127.0.0.1", server.port))
        sibling.serve()
        await ready.wait()
        introducer = await sibling.fetch("introducer")
        root = await sibling.send(introducer, "get", [])
        assert isinstance(root, Ref), f"introducer returned {root!r}, not a capability"
        child = await sibling.send(root, "create", [])
        assert isinstance(child, Ref), f"create returned {child!r}, not a capability"
        assert await sibling.send(child, "ping", []) == "alive"
        await sibling.close()
        await origin_client.close()
        await asyncio.wait_for(hosted, timeout=5)
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
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"boom: {verb}")

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        anchor = session.send(root_ref, "explode", [])
        assert isinstance(anchor, asyncio.Future), (
            "a send handle must be an asyncio.Future"
        )
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
    server = await listen("127.0.0.1", 0, host=Host(captp_version="next"))
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def root(verb, args):
                    assert verb == "make", verb
                    label = str(args[0]) if args else "anon"
                    # A Tagged wrapping a single list value: untag unwraps to it.
                    return Tagged("task", [["assigned", label, 7]])

                session.publish("root", root)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(
            tcp_locator("127.0.0.1", server.port), host=Host(captp_version="next")
        )
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        root_ref = await session.fetch("root")
        # Neither projection awaits a prior reply: they ride the unresolved make
        # answer and the whole chain leaves on one flush.
        made = session.send(root_ref, "make", ["alice"])
        label = await made.untag("task").index(1)
        assert label == "alice", (
            f"pipelined untag->index should reach the label, got {label!r}"
        )
        # The source answer settled while the projection pumped the loop; awaiting
        # it now must still resolve (a late observation settles from the store).
        full = await made
        assert isinstance(full, Tagged) and full.tag == "task", (
            f"awaited source should be the tagged task, got {full!r}"
        )
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
        assert denied is not None and "Attenuated" in str(denied), (
            "an out-of-list verb breaks Attenuated"
        )

        # Revoke: every later call through the proxy breaks.
        await session.send(root_ref, "revoke", [])
        severed = None
        try:
            await session.send(proxy, "add", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), (
            "a revoked proxy breaks Revoked"
        )

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
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def tool(verb, args):
                    if verb == "ping":
                        return "pong"
                    raise ValueError(f"no such method: {verb}")

                session.publish("tool", tool)
                published.set()
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
        await asyncio.wait_for(published.wait(), timeout=5)
        far = await session.fetch("tool")
        care_far = session.caretaker(far)
        pong = await session.send(care_far.proxy, "ping", [])
        assert pong == "pong", (
            f"a local call to a proxy over a far tool settles, got {pong!r}"
        )

        # Revoke severs the local call exactly as it severs a partner's.
        care_local.revoke()
        severed = None
        try:
            await session.send(care_local.proxy, "double", [1])
        except VowBroken as error:
            severed = error
        assert severed is not None and "Revoked" in str(severed), (
            "revoke breaks a local call too"
        )

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
    published = asyncio.Event()
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
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await connect(tcp_locator("127.0.0.1", server.port))
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
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


async def _mid_turn_host_release_orders_sessions_before_host() -> None:
    """A driver-owned Host release requested by a behavior is one deferred
    terminal operation. The driver owns its Sessions and Host together, so the
    binding parks that owner rather than recreating per-session teardown."""
    host = Host()
    server = await listen("127.0.0.1", 0, host)
    loop = asyncio.get_running_loop()
    callback_errors = []
    prior_exception_handler = loop.get_exception_handler()
    loop.set_exception_handler(lambda _loop, context: callback_errors.append(context))
    accepted = asyncio.Event()
    during = loop.create_future()

    def svc(verb, args):
        if verb != "release-host":
            return None
        host.release()
        if not during.done():
            during.set_result(host.pending_release_count())
        return "closing"

    host.publish_giftable("svc", svc)

    async def accept_two() -> None:
        count = 0
        async for session in server:
            session.serve()
            count += 1
            if count == 2:
                accepted.set()
                break

    hosted = asyncio.ensure_future(accept_two())
    first = await connect(tcp_locator("127.0.0.1", server.port))
    first.serve()
    second = await connect(tcp_locator("127.0.0.1", server.port))
    second.serve()
    try:
        await asyncio.wait_for(accepted.wait(), timeout=5)
        cap = await first.fetch("svc")
        try:
            await first.send(cap, "release-host", [])
        except Exception:
            # Host teardown may close the wire before this answer arrives.
            pass
        assert await asyncio.wait_for(during, timeout=5) == 1, (
            "callback-time release must park exactly one driver teardown"
        )
        assert host.pending_release_count() == 0, (
            "the callback unwind drains every parked release"
        )
        await asyncio.wait_for(hosted, timeout=5)
        await host.release_async()
        assert host._raw is None, "Host teardown retained native authority"
        await asyncio.sleep(0)
        assert not callback_errors, callback_errors
    finally:
        loop.set_exception_handler(prior_exception_handler)
        await first.close()
        await second.close()
        server.close()


async def _send_redeeming_surfaces_the_direct_exporter() -> None:
    """A three-party handoff with pancake as all three parties, over loopback:
    the exporter (Bob) publishes a host-wide giftable inbox, the broker holds it
    and introduces members to it, and the recipient (Carol) asks for an
    introduction with ``send_redeeming``.

    The reply's ``via`` is the *direct* Carol-to-Bob session the binding opened
    to redeem the give, not the broker session Carol sent on. That is the one
    place a reply capability is valid, because a near export names a position
    in one specific CapTP session: Carol spawns her reply inbox on ``via``, and
    Bob answers by calling it back, so the message and its answer both travel
    over the direct connection while the broker stays out of the path. A
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
                # is a live export only in the session the redeemed token
                # routes to, so this call reaching Carol is the proof that
                # `via` named that session.
                return Forward(args[1], "note", [f"bob got {args[0]}"])
            return None

        bob.host.publish_giftable("dm", dm)

        async def accept_all(server) -> None:
            async for session in server:
                session.serve()

        accepting.append(asyncio.ensure_future(accept_all(bob)))
        accepting.append(asyncio.ensure_future(accept_all(broker)))

        # The broker dials Bob under its own identity and fetches his giftable
        # inbox; returning that ref into a *different* session is what trips
        # the transparent gifter.
        broker_to_bob = await connect(
            tcp_locator("127.0.0.1", bob.port), host=broker.host
        )
        broker_to_bob.serve()
        bob_dm = await broker_to_bob.fetch("dm")

        # Replace the alias with a decoy before any introduction: the gift
        # must retain the exact inbox the broker holds, not whatever the name
        # resolves to at withdrawal (ADR-0096, on the binding path).
        decoy_delivered: list = []
        bob.host.publish_giftable(
            "dm",
            lambda verb, args: (
                decoy_delivered.append(args[0]) if verb == "dm" else None
            ),
        )

        broker.host.publish_giftable(
            "introducer",
            lambda verb, args: bob_dm if verb == "introduce" else "no capability here",
        )

        carol = await connect(tcp_locator("127.0.0.1", broker.port))
        carol.serve()
        introducer = await carol.fetch("introducer")

        settled = await carol.send_redeeming(introducer, "introduce", [])
        assert isinstance(settled, SendRedeemingResult), settled
        reply, via = settled
        assert isinstance(reply, Ref), f"introduce returned a capability, got {reply!r}"
        assert via is not None, (
            "the redeemed reply surfaces its direct exporter session"
        )
        assert via is not carol, (
            "`via` is the direct exporter session, not the broker one"
        )
        assert via.host is carol.host, "the redeem shares Carol's Host"

        # The reply inbox is hosted where the reply lives, and the DM goes out
        # over that session's connection: Bob's answer is his call back into it.
        inbox = via.spawn(lambda verb, args: acked.append(args[0]))
        note = await via.send(reply, "dm", ["hello bob", inbox])
        assert delivered == ["hello bob"], (
            f"the DM reached Bob directly, got {delivered!r}"
        )
        assert acked == ["bob got hello bob"], (
            f"Bob called the reply inbox back, got {acked!r}"
        )
        assert note is None, (
            f"the forwarded answer settles from the inbox, got {note!r}"
        )
        assert decoy_delivered == [], (
            f"the DM leaked to the alias's decoy, got {decoy_delivered!r}"
        )

        # Deterministic re-redeem: the second introduction routes to the
        # exporter already dialed, so `via` is that same live session.
        again = await carol.send_redeeming(introducer, "introduce", [])
        assert again.via is via, (
            "a re-redeem resolves the same exporter session, no second dial"
        )

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


# --- The onion transport, against a fake Tor daemon ---------------------------
#
# `pancake.onion` is the one netlayer the OCapN draft standardizes. It reaches a
# Tor daemon the deployment runs, so exercising it here means standing one up: two
# loopback servers answering the exact requests pancake sends. The bytes those
# requests must contain are pinned on the Zig side against the pinned Spritely
# Goblins netlayer and the upstream OCapN suite; this proves the Python surface
# reaches them and reads the answers back.

_ONION_SERVICE_ID = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd"
_ONION_SERVICE_KEY = b"ED25519-V3:c3RvcmVk"


def _fake_control(sock: "socket.socket", seen: list[str]) -> None:
    """Answer one control conversation, recording the AUTHENTICATE line.

    Recording the credential is the point of this fake. Every other assertion here
    uses an unauthenticated endpoint, where a mapping that sent no credential at all
    would look exactly like success.
    """
    conn, _ = sock.accept()
    with conn:
        pending = b""
        while True:
            try:
                chunk = conn.recv(1024)
            except OSError:
                return
            if not chunk:
                return
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                text = line.rstrip(b"\r").decode()
                if text.startswith("AUTHENTICATE") or text.startswith("ADD_ONION"):
                    seen.append(text)
                if text.startswith("ADD_ONION"):
                    reply = (
                        f"250-ServiceID={_ONION_SERVICE_ID}\r\n"
                        f"250-PrivateKey={_ONION_SERVICE_KEY.decode()}\r\n250 OK\r\n"
                    )
                else:
                    reply = "250 OK\r\n"
                try:
                    conn.sendall(reply.encode())
                except OSError:
                    return


def _loopback() -> "socket.socket":
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(4)
    return sock


def _address_of(sock: "socket.socket") -> str:
    host, port = sock.getsockname()
    return f"{host}:{port}"


# The SOCKS endpoint for the checks that never dial: an absolute Unix socket path,
# which is the other form OnionNetlayer accepts and the one a distribution's Tor
# actually offers. Nothing is bound there, so a check that reached it would fail
# rather than quietly connect somewhere.
_ABSENT_SOCKS = "/run/pancake-smoke/absent.socks"


def _fake_socks(sock: "socket.socket", wrote: list[bytes]) -> None:
    """Answer one SOCKS5 handshake, then record the first bytes the dialer sent.

    The fake does not proxy. A real Tor splices the circuit onto the service's
    forward target; what the transport owes is that the stream is a transparent byte
    pipe positioned after the reply, so this stands in for the far peer directly.
    """
    conn, _ = sock.accept()
    with conn:
        # Version 5, one method, no authentication.
        assert _recv_exactly(conn, 3) == b"\x05\x01\x00"
        conn.sendall(b"\x05\x00")
        # Four header bytes, the length byte, the 62-character address, the port.
        request = _recv_exactly(conn, 69)
        assert request[:5] == b"\x05\x01\x00\x03\x3e", request[:5]
        assert request[5:67].decode() == f"{_ONION_SERVICE_ID}.onion"
        assert request[67:] == (9045).to_bytes(2, "big"), request[67:]
        # Success, reserved, IPv4, then the null bound address Tor reports.
        conn.sendall(b"\x05\x00\x00\x01" + bytes(6))
        wrote.append(conn.recv(256))


def _recv_exactly(conn: "socket.socket", count: int) -> bytes:
    out = b""
    while len(out) < count:
        chunk = conn.recv(count - len(out))
        if not chunk:
            raise AssertionError("the dialer closed mid-handshake")
        out += chunk
    return out


def _listen_with_auth(auth_kind: int, secret) -> str:
    """Drive one `listen` against a fake daemon and report the AUTHENTICATE line."""
    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    with OnionNetlayer(
        socks=_ABSENT_SOCKS,
        control=_address_of(control),
        auth_kind=auth_kind,
        auth_secret=secret,
    ) as nl:
        nl.listen().close()
    control.close()
    thread.join(timeout=2)
    authenticate = [line for line in seen if line.startswith("AUTHENTICATE")]
    assert authenticate, "the fake daemon saw no AUTHENTICATE"
    return authenticate[0]


def _loop_archive_stepping_parity() -> None:
    """The driver archive from Python (ADR-0112): two stepping loops,
    the server driven by a plain thread, the client parked on the readiness
    descriptor via asyncio — dial as a ticket, session as an OPENED event,
    vow outcomes as COMPLETION events routed through the adopted wrapper
    Host's vow table, and a hangup. The server publishes through its own
    wrapper Host, so the trampoline, the fetch's settle (a real ``Ref``),
    and a missing-name break (``VowBroken``) all cross the loop tier.
    """
    from pancake._loop import DriverLoop
    from pancake.tcp import install_provider

    ready = threading.Event()
    stop = threading.Event()
    server_errors: list[BaseException] = []
    designator_box: list[str] = []

    def serve() -> None:
        try:
            server = DriverLoop.open(wire_buffer_bytes=1024, max_pending_opens=8)
            install_provider(server)
            server.wrapper_host().publish_giftable(
                "widget", lambda verb, args: "poked through the loop tier"
            )
            listener = server.listen("tcp", "127.0.0.1:0")
            server.select_listener(listener)
            designator_box.append(server.listener_locator(listener).designator)
            ready.set()
            while not stop.is_set():
                server.step(20)
            server.close()
        except BaseException as exc:
            server_errors.append(exc)
            ready.set()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    assert ready.wait(10), "the loop server never bound"
    assert not server_errors, server_errors
    designator = designator_box[0]

    async def client() -> None:
        loop = DriverLoop.open()
        install_provider(loop)
        await loop.start()

        # The whole public Session surface over the loop tier: fetch settles
        # as a real Ref, an eventual-send round-trips through the server's
        # trampoline, a missing name classifies as VowBroken, and close
        # releases through the loop's own verb.
        session = await asyncio.wait_for(
            loop.connect_session(pancake.format_peer_uri("tcp", designator)), 10
        )
        widget = await asyncio.wait_for(session.fetch("widget"), 10)
        assert isinstance(widget, Ref), widget
        reply = await asyncio.wait_for(session.send(widget, "poke", []), 10)
        assert reply == "poked through the loop tier", reply
        try:
            await asyncio.wait_for(session.fetch("nobody-home"), 10)
            raise AssertionError("fetching an unpublished name must break the vow")
        except VowBroken:
            pass
        await asyncio.wait_for(session.close(), 10)
        loop.close()

    asyncio.run(client())
    stop.set()
    thread.join(timeout=10)
    assert not thread.is_alive(), "the loop server thread did not stop"
    assert not server_errors, server_errors


def _onion_against_a_fake_daemon() -> None:
    # The generic driver retains the package callback context after the onion
    # constructor reference is dropped by the transport-owned installer.
    from pancake._loop import DriverLoop

    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    loop = DriverLoop.open()
    try:
        install_onion_provider(loop, socks=_ABSENT_SOCKS, control=_address_of(control))
        assert loop._has_transport("onion")
        listener = loop.listen("onion", "")
        locator = loop.listener_locator(listener)
        assert locator.transport == "onion", locator
        assert locator.designator == _ONION_SERVICE_ID, locator
        loop.close_listener(listener)
    finally:
        loop.close()
        control.close()
        thread.join(timeout=2)
        assert not thread.is_alive(), (
            "driver release did not close the onion control session"
        )

    # Hosting reports the id the daemon named, and the key that restores it.
    control = _loopback()
    seen: list[str] = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    with OnionNetlayer(socks=_ABSENT_SOCKS, control=_address_of(control)) as nl:
        listener = nl.listen()
        assert listener.service_id == _ONION_SERVICE_ID, listener.service_id
        assert len(listener.service_id) == SERVICE_ID_LENGTH
        assert listener.service_key == _ONION_SERVICE_KEY, listener.service_key

        # The readiness descriptor must be the live accept socket, not merely a
        # number. Nothing has dialed, so selecting on it reports not-ready and an
        # accept would park.
        fd = listener.readiness_fd()
        assert fd >= 0, fd
        assert select.select([fd], [], [], 0.05) == ([], [], []), (
            "readable with no circuit"
        )

        # Stand in for Tor forwarding a circuit: connect to the local endpoint the
        # listener bound and told the daemon about.
        add_onion = next(line for line in seen if line.startswith("ADD_ONION"))
        # `PORT=<virtual>,<target>` — the target is what follows the comma.
        forward = add_onion.split("PORT=", 1)[1].split(",", 1)[1]
        host, port = forward.rsplit(":", 1)
        with socket.create_connection((host, int(port))):
            # Now the same descriptor reports arrival, so accept returns rather than
            # parking.
            ready, _, _ = select.select([fd], [], [], 2.0)
            assert ready == [fd], "not readable after a circuit arrived"
            assert listener.wait(1000) is True
            accepted = listener.accept()
            assert accepted.readiness_fd() >= 0
            accepted.close()
        # Releasing the owner closes every child before its std.Io backend.
        nl.release()
        try:
            listener.readiness_fd()
            raise AssertionError("an owner-released listener remained callable")
        except RuntimeError:
            pass
        listener.close()  # idempotent after owner-driven release
    control.close()
    thread.join(timeout=2)

    # ctypes releases the GIL around CDLL calls. Owner release must therefore
    # interrupt an accept already parked in native code, wait for its lease to
    # return, and only then free the listener and netlayer storage.
    control = _loopback()
    seen = []
    thread = threading.Thread(target=_fake_control, args=(control, seen), daemon=True)
    thread.start()
    nl = OnionNetlayer(socks=_ABSENT_SOCKS, control=_address_of(control))
    listener = nl.listen()
    entered = threading.Event()
    accept_errors: list[BaseException] = []

    def blocked_accept() -> None:
        entered.set()
        try:
            listener.accept()
        except BaseException as exc:
            accept_errors.append(exc)

    accepter = threading.Thread(target=blocked_accept, daemon=True)
    accepter.start()
    assert entered.wait(1), "the accept thread did not start"
    # It has no incoming circuit, so remaining alive is evidence that it reached
    # the blocking accept rather than failing before the native call.
    time.sleep(0.05)
    assert accepter.is_alive(), "the empty listener did not block accept"
    nl.release()
    accepter.join(timeout=2)
    assert not accepter.is_alive(), "owner release did not drain blocked accept"
    assert accept_errors, "shutdown did not report the interrupted accept"
    control.close()
    thread.join(timeout=2)

    # Each credential form reaches the daemon as itself.
    assert _listen_with_auth(0, None) == "AUTHENTICATE"
    assert (
        _listen_with_auth(AUTH_COOKIE, bytes([0x00, 0x01, 0x0F, 0xFF]))
        == "AUTHENTICATE 00010fff"
    )
    assert _listen_with_auth(AUTH_PASSWORD, "hunter2") == 'AUTHENTICATE "hunter2"'

    # The dial half: a circuit carries a framed message. What reaches the wire is
    # the frame inside its netstring envelope, a Syrup byte string whose length
    # prefix the reader strips again.
    socks = _loopback()
    wrote: list[bytes] = []
    dialer = threading.Thread(target=_fake_socks, args=(socks, wrote), daemon=True)
    dialer.start()
    with OnionNetlayer(socks=_address_of(socks)) as nl:
        conn = nl.connect(_ONION_SERVICE_ID)
        payload = b"<8'op:abort3\"bye>"
        conn.write_frame(payload)
        dialer.join(timeout=2)
        assert wrote == [b"%d:%s" % (len(payload), payload)], wrote
        conn.close()
    socks.close()

    # A dial-only netlayer can reach out and cannot host.
    with OnionNetlayer(socks=_ABSENT_SOCKS) as nl:
        try:
            nl.listen()
            raise AssertionError("a dial-only netlayer should not host")
        except PancakeError:
            pass
        # A designator that is not a well-formed version 3 address is refused before
        # any socket opens, so this is an argument fault rather than a dial failure.
        try:
            nl.connect("not-an-onion-address")
            raise AssertionError("a malformed designator should be refused")
        except PancakeError:
            pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"python zig-smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)
