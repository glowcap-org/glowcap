"""A whole conversation at a time: the in-process relay, the live trace's
timeline, deferred behaviors, both codecs, typed feed refusals, tightened
admission, and a disconnect rejecting the pending send."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar
import re

import ctypes

from glowcap import (
    tcp,
    Context,
    Keyword,
    Locator,
    Host,
    GlowcapError,
    VowBroken,
    Runtime,
)
from glowcap._constants import (
    DESIGNATOR_SCHEME_ADDRESS,
    ERR_FRAME_TOO_LARGE,
    TRANSPORT_TCP,
)

from smoke.runtime import tcp_connect



_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)

async def _start_relay(target_port: int, rewrite=None, observe=None):
    """A byte-level TCP relay between a client and a server that are both real
    glowcap connections: it shuttles raw bytes both ways, optionally rewriting
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
                        observe(chunk, rewriting)
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


async def _live_trace_produces_timeline() -> None:
    """The live timeline producer: the veneer stamps and forwards the native
    tap's facts, one flat record per fact -- session-opened with the codec
    the handshake actually negotiated, the same verb outbound at the client
    and inbound at the server, and session-closed. Endpoint labeling belongs
    to the consumer, so the records carry only the session and direction."""
    from glowcap import annotate_session, enable_trace

    events: list = []
    host = Host()
    trace_failure = RuntimeError("trace sink failure must stay observer-only")

    def record_then_raise(event) -> None:
        events.append(event)
        raise trace_failure

    # Trace configuration is process-global, but every native Host remains
    # owner-thread confined. Installing from a worker must hop back to this
    # loop rather than calling through a retained raw pointer.
    uninstall = await asyncio.to_thread(lambda: enable_trace(record_then_raise, self_label="smoke"))
    host.publish("greeter", lambda verb, args: f"hello {verb}")
    server = await tcp.listen("127.0.0.1", 0, host=host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        client_host = client.host
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
        await server.close()
        await host.close()
    await asyncio.to_thread(uninstall)
    trace_diagnostics = host.take_failures() + client_host.take_failures()
    assert trace_diagnostics, "trace sink failures disappeared"
    assert all(
        failure.operation == "trace.sink"
        and failure.scope_id > 0
        and failure.primary_name == "RuntimeError"
        and failure.primary_message == str(trace_failure)
        for failure in trace_diagnostics
    ), trace_diagnostics

    opened = [ev for ev in events if ev["kind"] == "ocapn.session-opened"]
    assert len(opened) >= 2, f"both hosts' opens reached the one sink: {events}"
    assert all(ev["codec"] == "syrup" and ev["a_label"] == "smoke" for ev in opened)
    # And what this producer RUNS, because this schema is not glowcap's alone:
    # a consumer must not read an implementation off the fact that a record
    # arrived, so a glowcap host says so in words.
    assert all(ev["a_profile"] == "glowcap" for ev in opened)
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
        ev for ev in events if ev["kind"] == "ocapn.message-decoded" and ev.get("op") == "trace-me" and ev["outbound"]
    ]
    assert outbound, "the client's send traced outbound"
    inbound = [
        ev
        for ev in events
        if ev["kind"] == "ocapn.message-decoded" and ev.get("op") == "trace-me" and not ev["outbound"]
    ]
    assert inbound, "the server's deliver traced inbound"
    assert inbound[0]["session"] != outbound[0]["session"], "each host names its own session row"
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
    assert metas and metas[0]["meta"]["label"] == "greeter-server", "the annotation reached the sink with its label"
    assert metas[0]["session"] == outbound[0]["session"], "the annotation names the same session row the tap names"
    stamps = [ev["sim_t_ns"] for ev in events]
    assert stamps == sorted(stamps), "sim_t_ns is monotone"


async def _async_behavior_defers() -> None:
    """An async behavior (off-turn settlement): the worker returns a
    coroutine, the binding defers the turn's answer onto a resolver vow, and
    the settle re-enters as its own task after real awaited work, so the
    host's turn loop never blocks on it. A raise crosses as the caller's
    break carrying the behavior's own words."""
    host = Host()
    entered = {verb: asyncio.Event() for verb in ("work", "fail", "unsupported", "late-work", "late-fail")}
    resume = {verb: asyncio.Event() for verb in entered}

    async def work(verb, args):
        entered[verb].set()
        await resume[verb].wait()
        if verb in ("fail", "late-fail"):
            raise ValueError("worker gave up")
        if verb == "unsupported":
            return object()
        return "computed off-turn"

    host.publish("worker", work)
    server = await tcp.listen("127.0.0.1", 0, host=host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        hosted = asyncio.ensure_future(serve_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        client.serve()
        worker = await client.fetch("worker")

        async def invoke(verb):
            pending = client.send(worker, verb, [])
            await entered[verb].wait()
            resume[verb].set()
            return await pending

        reply = await invoke("work")
        assert reply == "computed off-turn", f"async behavior reply, got {reply!r}"
        try:
            await invoke("fail")
        except VowBroken as broke:
            assert "worker gave up" in str(broke), f"async raise carries the reason, got {broke!s}"
        else:
            raise AssertionError("an async behavior's raise must break the caller")
        try:
            await invoke("unsupported")
        except VowBroken as broke:
            assert "unsupported" in str(broke).lower(), f"async marshal failure carries the reason, got {broke!s}"
        else:
            raise AssertionError("an unsupported async result must break the caller")
        late = asyncio.gather(
            client.send(worker, "late-work", []),
            client.send(worker, "late-fail", []),
            return_exceptions=True,
        )
        await entered["late-work"].wait()
        await entered["late-fail"].wait()
        await client.close()
        await asyncio.wait_for(hosted, timeout=5)
        settlements = tuple(host._behavior_tasks)
        assert len(settlements) == 2, "both deferred completions remain owned"
        resume["late-work"].set()
        resume["late-fail"].set()
        await asyncio.gather(*settlements)
        assert all(isinstance(reply, BaseException) for reply in await late)
        assert not host.terminal_failures, "late completion poisoned the Host"
    finally:
        await server.close()
    await asyncio.wait_for(host.close(), timeout=1)


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

        host.publish("counter", counter)
        server = await tcp.listen("127.0.0.1", 0, host=host)
        held_counter = None
        try:

            async def serve_one() -> None:
                nonlocal held_counter
                async for session in server:
                    local_counter = session.published_ref("counter")
                    held_counter = local_counter
                    assert local_counter is not None, "the Host alias projects onto the accepted session"
                    assert await session.send(local_counter, "get", []) == 10
                    await session.serve()
                    break

            hosted = asyncio.ensure_future(serve_one())
            client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
            client.serve()
            counter_ref = await client.fetch("counter")
            grown = await client.send(counter_ref, "add", [5])
            assert grown == 15, f"counter.add(5) returns 15, got {grown!r}"
            read = await client.send(counter_ref, "get", [])
            assert read == 15, f"counter.get() returns 15, got {read!r}"

            # Alias-only unpublish: discovery moves, the issued capability does
            # not. A removed alias misses even on the session that fetched it,
            # a second removal is a loud miss, and the ref still answers.
            assert host.unpublish("counter") is True
            assert host.unpublish("counter") is False
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
            assert swiss.startswith("glowcap-durable-1-") and len(swiss) == 50, swiss
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
            assert held_counter is not None
            exact_name = host.publish_reference(held_counter)
            exact_ref = await client.fetch(exact_name)
            assert await client.send(exact_ref, "add", [2]) == 17
            assert await client.send(counter_ref, "get", []) == 17
            assert host.remove_durable(exact_name)
            assert await client.send(exact_ref, "get", []) == 17
            await client.close()
            await asyncio.wait_for(hosted, timeout=5)
        finally:
            await server.close()
        await host.close()
        assert stats["allocs"] > 0, "the host allocator serviced the Host"
        assert not live, "Context release returned every custom allocation"


async def _capnp_codec_round_trip() -> None:
    """The codec selector end-to-end: both nodes minted with the Cap'n Proto
    wire grammar complete the keyed handshake and carry a deliver whose
    arguments round-trip through the capnp codec — a big integer past int64 and
    a Keyword included, so the two rare marshal arms are witnessed alongside
    the codec."""
    big = 2**80
    server = await tcp.listen("127.0.0.1", 0, codec="capnp")
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
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port), codec="capnp")
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [big, Keyword("prio"), b"hi"])
        assert isinstance(reply, Keyword) and reply == "done", reply
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()


async def _empty_codec_is_not_the_default() -> None:
    """An omitted codec gets the Goblins-compatible floor. An explicit empty
    codec is not omission: it is invalid input and must fail before a socket is
    opened or a Host is minted with Syrup by accident."""
    for verb, action in (
        ("listen", lambda: tcp.listen("127.0.0.1", 0, codec="")),
        (
            "connect",
            lambda: Runtime.open(provider=tcp.provider(), codec="", handshake_timeout_ms=10_000),
        ),
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
    from glowcap._session import Session as _Session

    return _Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, tcp.address_designator("127.0.0.1", 1), {}, "boolean-false"),
        _InjectTransport(),
    )


async def _feed_refusals_are_typed() -> None:
    """Bounded inbox and typed abort causes over the byte-fed host. A frame
    declaring more than the frame cap is a typed refusal the moment that is
    knowable, never "read more" (ADR-0041); a refused frame names its typed
    cause (the flat GlowcapError code says the failure family, the attached
    AbortDetail says the member)."""
    from glowcap import _pump

    # Over-cap: the length prefix declares past the cap, refused during the scan.
    # Bytes ride the named pump module (`_pump._feed`), not a Session verb.
    session = _dial_injected(Host())
    try:
        await _pump._feed(session, b"2000000:")
        raise AssertionError("an over-cap frame must refuse typed instead of buffering")
    except GlowcapError as exc:
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
        except GlowcapError as exc:
            assert exc.abort is not None, "the refused frame carries its typed cause"
            assert exc.abort.domain == "codec", exc.abort
            assert exc.abort.kind == "MalformedFrame", exc.abort
            assert exc.abort.error_name == "MalformedFrame", exc.abort
            assert exc.abort.abort_delivery_error_name is None, exc.abort
            assert exc.abort.secondary_error_name is None, exc.abort
            assert exc.abort.secondary_error_count == 0, exc.abort
    finally:
        session.close_transport()


async def _tightened_admission_cap_refuses() -> None:
    """``Host.set_session_limits`` moves the admission cap the sessions minted
    after it are held to (ADR-0082). One frame decides it: at the default cap a
    4000-byte declaration is simply incomplete, and at a tightened 1024 the same
    prefix is a typed over-cap refusal."""
    from glowcap import _pump

    prefix = b"4000:"

    session = _dial_injected(Host())
    try:
        await _pump._feed(session, prefix)  # under the default cap: still incomplete
    finally:
        session.close_transport()

    tightened = Host()
    tightened.set_ingress_limits(
        max_pending_turns=4096,
        max_pending_bytes=1024 * 1024,
        max_chunk_bytes=128 * 1024,
    )
    tightened.set_session_limits(
        max_frame_bytes=1024,
        max_retained_sent_answer_bytes=8 * 1024 * 1024,
    )
    session = _dial_injected(tightened)
    try:
        await _pump._feed(session, prefix)
        raise AssertionError("a tightened admission cap must refuse an over-cap frame")
    except GlowcapError as exc:
        assert exc.code == ERR_FRAME_TOO_LARGE, exc.code
    finally:
        session.close_transport()


async def _disconnect_rejects_pending_send() -> None:
    """An outstanding ``send`` rejects when the connection drops, rather than
    hanging on a reply that can never arrive. The server serves one call and
    then closes without warning; the client's next awaited send settles with a
    typed rejection once the disconnect lands."""
    server = await tcp.listen("127.0.0.1", 0)
    closed = asyncio.Event()
    called = asyncio.Event()
    hold_late_reply = asyncio.Event()
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:
                async def service(verb, args):
                    if verb == "ping":
                        return None
                    called.set()
                    await hold_late_reply.wait()
                    return None

                session.publish("svc", service)
                session.serve()
                published.set()
                await called.wait()
                await session.close()
                hold_late_reply.set()
                closed.set()
                break

        hosted = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()  # a disconnect ends the serve task; expected here
        await asyncio.wait_for(published.wait(), timeout=5)
        svc = await session.fetch("svc")
        await session.send(svc, "ping", [])
        pending = session.send(svc, "late", [])
        await called.wait()
        await closed.wait()
        rejected = False
        try:
            await pending
        except (GlowcapError, VowBroken):
            rejected = True
        assert rejected, "an outstanding send rejects when the connection drops"
        await session.close()
        await asyncio.wait_for(hosted, timeout=5)
    finally:
        await server.close()
