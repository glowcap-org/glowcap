"""The application verbs: structured args, enliven caching, GC of projected
capabilities, typed fetch failures, pipelining, turn-time spawn,
projections, forwarding proxies, and mid-turn refusals."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar
import re


from glowcap import (
    tcp,
    FetchFailed,
    ErrorValue,
    Host,
    GlowcapError,
    Ref,
    Set,
    Struct,
    Symbol,
    Tagged,
    VowBroken,
    Runtime,
    format_locator_uri,
)
from glowcap._constants import (
    ERR_INVALID_ARGUMENT,
)

from smoke.conversation import _start_relay
from smoke.runtime import tcp_connect
from .authority import (
    _forwarding_proxies_over_the_wire as _forwarding_proxies_over_the_wire,
    _forwarding_proxy_local_call as _forwarding_proxy_local_call,
    _mid_turn_driving_verb_breaks_the_answer as _mid_turn_driving_verb_breaks_the_answer,
    _mid_turn_host_release_orders_sessions_before_host as _mid_turn_host_release_orders_sessions_before_host,
)



_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar("scenario_runtimes", default=None)

async def _structured_args_round_trip() -> None:
    """``Set`` and ``Struct`` cross the typed application surface, a capability nested in a Set or Tagged arrives as a sendable
    :class:`Ref`, and a partner break raises the typed :class:`VowBroken`."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    try:

        async def serve_one() -> None:
            async for session in server:

                def svc(verb, args):
                    if verb == "boom":
                        raise ValueError("kaboom")
                    assert verb == "probe", verb
                    probe_set = args[0]
                    assert type(probe_set) is Set, f"a Set argument arrives as a Set, got {type(probe_set).__name__}"
                    assert 1 in probe_set, probe_set
                    nested = next((item for item in probe_set if isinstance(item, Ref)), None)
                    assert isinstance(nested, Ref), f"a capability inside a Set lifts to a Ref, got {nested!r}"
                    note = args[1]
                    assert isinstance(note, Tagged), f"a Tagged argument arrives as a Tagged, got {note!r}"
                    assert isinstance(note.value[0], Ref), note.value
                    record = args[2]
                    assert isinstance(record, Struct), f"a Struct argument arrives as Struct, got {record!r}"
                    assert ("count", 7) in record.entries, record
                    error_value = args[3]
                    assert error_value == ErrorValue("failure is a value"), error_value
                    # The nested capability is sendable: poke back through it.
                    asyncio.ensure_future(session.tell(nested, "poke", []))
                    return [Set([Symbol("ok"), 7]), record, error_value]

                session.publish("svc", svc)
                published.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        session.serve()
        poked = asyncio.get_running_loop().create_future()
        snapshot = asyncio.get_running_loop().create_future()

        def inbox_behavior(verb, args):
            if verb == "poke" and not poked.done():
                poked.set_result(True)
            if verb == "snapshot" and not snapshot.done():
                snapshot.set_result(args[0])
                return args[0]

        inbox = session.spawn(inbox_behavior)
        local_args = ["before"]
        local_reply = session.send(inbox, "snapshot", local_args)
        local_args[0] = "after"
        await asyncio.wait_for(published.wait(), timeout=5)
        svc_ref = await session.fetch("svc")
        reply = await session.send(svc_ref, "probe", [Set([1, inbox]), Tagged("note", [inbox]), Struct([("count", 7), ("name", "widget")]), ErrorValue("failure is a value")])
        assert isinstance(reply, list) and type(reply[0]) is Set, reply
        assert isinstance(reply[1], Struct), reply
        assert reply[2] == ErrorValue("failure is a value"), reply
        assert Symbol("ok") in reply[0] and 7 in reply[0], reply
        await asyncio.wait_for(poked, timeout=5)
        assert await local_reply == "before"
        assert await asyncio.wait_for(snapshot, timeout=5) == "before"

        # A partner break is the typed VowBroken, catchable by type.
        try:
            await session.send(svc_ref, "boom", [])
            raise AssertionError("a partner break must raise VowBroken")
        except VowBroken as exc:
            assert "kaboom" in str(exc), exc

        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)

    finally:
        await server.close()

async def _enliven_round_trips_then_caches() -> None:
    """Sturdyref enliven (ADR-0007): the requester brings a durable
    ``(peer, swissnum)`` to life as a live :class:`Ref` through the host's
    dedup cache. A repeat enliven of the same swissnum short-circuits with no
    wire traffic (its completion is queued before the minting call returns),
    and the enlivened capability is sendable both times."""
    server_host = Host()

    def greeter(verb, args):
        assert verb == "hello", verb
        return Symbol("alive")

    server_host.publish("greeter", greeter)
    server = await tcp.listen("127.0.0.1", 0, host=server_host)
    try:

        async def serve_one() -> None:
            async for session in server:
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        locator = tcp.locator("127.0.0.1", server.port)
        session = await tcp_connect(locator)
        session.serve()
        try:
            await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
        except GlowcapError as err:
            assert err.code == ERR_INVALID_ARGUMENT, err
        else:
            raise AssertionError("enliven accepted a sturdyref for another peer")
        # The complete sturdyref must name this selected session's peer.
        sturdyref = f"{format_locator_uri(locator)}/s/Z3JlZXRlcg"
        cap = await session.enliven(sturdyref)
        greeting = await session.send(cap, "hello", [])
        assert greeting == Symbol("alive"), f"enlivened cap answers hello, got {greeting!r}"
        # A repeat enliven hits the dedup cache: the same live capability.
        again = await session.enliven(sturdyref)
        assert again == cap, "cached enliven preserves Target equality"
        greeting2 = await session.send(again, "hello", [])
        assert greeting2 == Symbol("alive"), f"cached enliven answers hello, got {greeting2!r}"
        fetched = await session.host.fetch_at(locator, "greeter")
        assert await session.send(fetched, "hello", []) == Symbol("alive")
        host_cap = await session.host.enliven(sturdyref, captp_version="v1_0")
        assert await session.send(host_cap, "hello", []) == Symbol("alive")
        try:
            await session.host.enliven(sturdyref, captp_version="next")
        except VowBroken:
            pass
        else:
            raise AssertionError("next interpreted a v1.0 swiss as the same authority")
        # Listen (CapTP ``op:listen``): a held capability's resolution comes
        # back through the vow: a listen on an already-settled capability
        # answers at once.
        observation = session.listen(cap)
        try:
            await session.send(observation, "hello", [])
        except GlowcapError as err:
            assert err.code == ERR_INVALID_ARGUMENT, err
        else:
            raise AssertionError("an op:listen observer became a remote pipeline target")
        settled = await observation
        assert isinstance(settled, Ref), f"listen settles naming the capability, got {settled!r}"
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)

        # A sessionless Host selects the generic driver before its DIAL action
        # exists. The driver consumes that original action and exposes the
        # exporter session without a binding-side TCP branch.
        cold_serve = asyncio.ensure_future(serve_one())
        cold = Host()
        cold.register_connector(tcp.connector())
        cold_cap = await cold.enliven(sturdyref, captp_version="v1_0")
        cold_exporter = cold.exporter_for(cold_cap)
        assert cold_exporter is not None, "cold enliven retains its exporter session"
        cold_greeting = await cold_exporter.send(cold_cap, "hello", [])
        assert cold_greeting == Symbol("alive"), cold_greeting
        await cold.close()
        await asyncio.wait_for(cold_serve, timeout=5)
    finally:
        await server.close()


async def _distributed_release_reaches_each_capability_home() -> None:
    """Distributed release (ADR-0025): fetch results, nested send replies, and
    nested delivered arguments each release their projected capability at its
    actual home. Both real wire directions are observed before teardown, so a
    session-close sweep cannot satisfy the proof accidentally."""
    server = await tcp.listen("127.0.0.1", 0)
    published = asyncio.Event()
    gc_counts = {True: 0, False: 0}
    gc_tails = {True: b"", False: b""}
    gc_seen = {True: asyncio.Event(), False: asyncio.Event()}
    needle = b"op:gc-export"

    def observe(chunk: bytes, to_server: bool) -> None:
        combined = gc_tails[to_server] + chunk
        found = combined.count(needle)
        gc_counts[to_server] += found
        gc_tails[to_server] = combined[-(len(needle) - 1):]
        if found:
            gc_seen[to_server].set()

    async def await_gc(to_server: bool, expected: int, label: str) -> None:
        if gc_counts[to_server] >= expected:
            return
        gc_seen[to_server].clear()
        await asyncio.wait_for(gc_seen[to_server].wait(), timeout=2)
        assert gc_counts[to_server] >= expected, label

    relay_port, relay_close = await _start_relay(server.port, observe=observe)
    try:

        async def serve_one() -> None:
            async for session in server:
                session.with_gc()
                delegated = session.spawn(lambda verb, args: None)
                inbound = asyncio.get_running_loop().create_future()

                def factory(verb, args):
                    if verb == "reply":
                        return Struct([("nested", [delegated])])
                    assert verb == "accept", verb
                    assert (
                        len(args) == 1
                        and isinstance(args[0], Struct)
                        and args[0].entries[0][0] == "nested"
                        and isinstance(args[0].entries[0][1], list)
                        and isinstance(args[0].entries[0][1][0], Ref)
                    ), args
                    if not inbound.done():
                        inbound.set_result(args[0].entries[0][1][0])
                    return None

                session.publish("factory", factory)
                published.set()
                serving = session.serve()
                session.release(await inbound)
                await serving
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = (await tcp_connect(tcp.locator("127.0.0.1", relay_port))).with_gc()
        session.serve()
        await asyncio.wait_for(published.wait(), timeout=5)
        factory = await session.fetch("factory")

        reply = await session.send(factory, "reply", [])
        assert (
            isinstance(reply, Struct)
            and reply.entries[0][0] == "nested"
            and isinstance(reply.entries[0][1], list)
            and isinstance(reply.entries[0][1][0], Ref)
        ), reply
        session.release(reply.entries[0][1][0])
        await await_gc(True, 1, "the nested send reply did not release")

        callback = session.spawn(lambda verb, args: None)
        await session.send(factory, "accept", [Struct([("nested", [callback])])])
        await await_gc(False, 1, "the nested delivered argument did not release")

        session.release(factory)
        await await_gc(True, 2, "the fetched capability did not release")
        await session.close()
        await asyncio.wait_for(serve_task, timeout=5)
    finally:
        relay_close()
        await server.close()


async def _fetch_failed_is_typed() -> None:
    """A fetch that fulfills with a plain value (not a capability) raises the
    dedicated :class:`FetchFailed`: the foreign-bootstrap shape a non-glowcap
    partner can produce. A glowcap host always answers a fetch with a
    capability, so a relay doctors the wire: the client's bootstrap-fetch
    deliver is retargeted from export 0 to the export of a published object
    that answers with a plain integer, so the client's fetch answer fulfills
    with 42. The client fetches "plain" legitimately first: that reply's
    marshal is what grants the export (ADR-0027), so the doctored deliver
    that follows is admitted rather than refused as a probe of an ungranted
    position."""
    server = await tcp.listen("127.0.0.1", 0)
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

    relay_port, relay_close = await _start_relay(server.port, rewrite=retarget, observe=observe)
    try:

        async def serve_one() -> None:
            async for session in server:
                # The doctored fetch deliver lands here with verb "fetch".
                # Answer with a plain integer, a value a fetch must not
                # resolve to.
                session.publish("plain", lambda verb, args: 42)
                export_known.set()
                await session.serve()
                break

        serve_task = asyncio.ensure_future(serve_one())
        session = await tcp_connect(tcp.locator("127.0.0.1", relay_port))
        session.serve()
        await export_known.wait()
        # The granting fetch: its resolve marshals the "plain" reference,
        # making the position addressable for the doctored deliver below.
        state["capturing"] = True
        await session.fetch("plain")
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
        await server.close()


async def _turn_spawn_survives_originating_port_close() -> None:
    """An actor first published through one Port remains a Host actor. Close
    that Port, call it through a sibling, then use the captured stale Session
    handle to spawn a child inside the sibling's turn. Host ownership selects
    turn-spawn. The dead Session is not consulted for routing."""
    server = await tcp.listen("127.0.0.1", 0)
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
                        return origin.spawn(lambda child_verb, child_args: ("alive" if child_verb == "ping" else None))

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
        origin_client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        origin_client.serve()
        sibling = await tcp_connect(tcp.locator("127.0.0.1", server.port))
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
        await server.close()
