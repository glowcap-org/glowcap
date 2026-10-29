"""Listeners and lifetimes: bound ports surface, rude probes bounce,
supplied Hosts transfer transactionally, iroh cancellation joins FFI
teardown, and every session-close path retains its exact failures."""

from __future__ import annotations

import asyncio
from contextvars import ContextVar
import threading

import glowcap

from glowcap import (
    FEATURE_FULL,
    FEATURE_MULTI_LOCATION,
    tcp,
    Locator,
    Host,
    GlowcapError,
    Symbol,
    Runtime,
    encode_peer_locator,
    parse_locator,
)
from glowcap._constants import (
    DESIGNATOR_SCHEME_ADDRESS,
    ERR_INVALID_ARGUMENT,
    TRANSPORT_KEYED_TCP,
    TRANSPORT_NOISE_TCP,
    TRANSPORT_TCP,
)

from smoke.runtime import tcp_connect
from .close import (
    _cancelled_session_close_waiter_does_not_stop_driver as _cancelled_session_close_waiter_does_not_stop_driver,
    _host_close_joins_session_transport_failure as _host_close_joins_session_transport_failure,
    _host_close_shuts_a_still_open_listener as _host_close_shuts_a_still_open_listener,
    _loop_finish_close_reports_finite_grace_timeout as _loop_finish_close_reports_finite_grace_timeout,
    _repeated_host_close_observes_recorded_timeout as _repeated_host_close_observes_recorded_timeout,
    _session_wire_failure_is_exact_and_retired as _session_wire_failure_is_exact_and_retired,
    _silent_loop_dial_reaches_ffi_handshake_deadline as _silent_loop_dial_reaches_ffi_handshake_deadline,
    _observe_session_retirement_without_serve_or_close as _observe_session_retirement_without_serve_or_close,
)
from .session_coordinator import (
    cancelled_close_waiter_preserves_transport_coordinator as cancelled_close_waiter_preserves_transport_coordinator,
    cancelled_loop_close_waiter_preserves_terminal_chain as cancelled_loop_close_waiter_preserves_terminal_chain,
    partner_release_keeps_a_freed_handle_from_loop_close as partner_release_keeps_a_freed_handle_from_loop_close,
)

_scenario_runtimes: ContextVar[list[Runtime] | None] = ContextVar(
    "scenario_runtimes", default=None
)


async def _listen_surfaces_bound_port() -> None:
    """`listen` binds a `Server` whose `.port` reads the kernel-chosen ephemeral
    port, and a client can dial it."""
    server = await tcp.listen("127.0.0.1", 0)
    try:
        port = server.port
        assert port != 0, "bound ephemeral port should be readable"

        accepted: list = []
        identity_checked = asyncio.Event()

        async def accept_one() -> None:
            async for session in server:
                accepted.append(session)
                assert session.transport_name == TRANSPORT_TCP
                assert session.profile.captp_version == "v1_0"
                assert session.profile.codec == "syrup"
                assert session.profile.features == FEATURE_FULL & ~FEATURE_MULTI_LOCATION
                await identity_checked.wait()
                await session.close()
                break

        accept_task = asyncio.ensure_future(accept_one())
        client = await tcp_connect(tcp.locator("127.0.0.1", port))
        expected = encode_peer_locator(
            Locator(
                TRANSPORT_TCP,
                tcp.address_designator("127.0.0.1", port),
                {"glowcap/features": ("pipelining,handoff,wire_delta,sturdyref,untag")},
                "map",
            )
        )
        assert client.partner_identity().locator_record == expected, (
            "the accepted host advertised the listener's complete locator record"
        )
        assert client.transport_name == TRANSPORT_TCP
        assert client.profile.features == FEATURE_FULL & ~FEATURE_MULTI_LOCATION
        assert client.profile.captp_version == "v1_0"
        assert client.profile.codec == "syrup"
        identity_checked.set()
        # Both keyed handshakes complete; one connection was accepted on the
        # bound port.
        await asyncio.wait_for(accept_task, timeout=5)
        assert len(accepted) == 1, "the dialed connection was accepted"
        await client.close()
    finally:
        await server.close()


async def _rude_probe_cannot_close_the_listener() -> None:
    """A rude TCP probe, connect, say nothing, hang up, is that connection's
    failure, not the listener's. The Server's iterator must skip the failed
    handshake and keep accepting. Without the skip, one port scan takes a
    long-lived server down."""
    server = await tcp.listen("127.0.0.1", 0)
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

        session = await tcp_connect(tcp.locator("127.0.0.1", port))
        await asyncio.wait_for(published.wait(), timeout=5)
        svc = await session.fetch("svc")
        reply = await session.send(svc, "ping", [])
        assert reply == Symbol("alive"), reply
        await session.close()
        await asyncio.wait_for(served, timeout=5)
    finally:
        await server.close()


async def _supplied_host_tcp_listener_ownership() -> None:
    """A supplied TCP Host is the exact wrapper adopted by the driver.

    Closing the listener seals admission but does not release the yielded
    session. The final Host close happens only after that session closes.
    """
    supplied = Host()
    server = await tcp.listen("127.0.0.1", 0, host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, (
            "listener did not preserve the supplied Host wrapper"
        )
        assert parse_locator(server.uri).transport == TRANSPORT_TCP, server.uri
        client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
        accepted = await asyncio.wait_for(accepted_task, timeout=5)
        accepted.publish("svc", lambda verb, args: Symbol("alive"))
        accepted.serve()

        await server.close()
        assert not supplied.released, "listener close released a yielded supplied Host"
        svc = await client.fetch("svc")
        assert await client.send(svc, "ping", []) == Symbol("alive")
        await accepted.close()
        await client.close()
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.close()


async def _failed_listener_preserves_supplied_host() -> None:
    """Post-adoption failure keeps the caller's Host and retires listener rows."""
    supplied = Host()
    retry = None
    try:
        try:
            await tcp.listen("0.0.0.0", 0, host=supplied)
            raise AssertionError("wildcard listen without an advertised host must fail")
        except GlowcapError as error:
            assert error.code == ERR_INVALID_ARGUMENT, error

        assert not supplied.released, "failed listen released the supplied Host"
        loop = supplied._driver_loop
        assert loop is not None, "failed listen detached the adopted driver loop"
        assert not loop._listeners, loop._listeners
        assert not loop._listener_waiters, loop._listener_waiters
        assert not loop._accepts, loop._accepts

        retry = await tcp.listen("127.0.0.1", 0, host=supplied)
        assert retry.host is supplied
    finally:
        if retry is not None:
            await retry.close()
        if not supplied.released:
            await supplied.close()


async def _supplied_host_iroh_listener_ownership() -> None:
    """The iroh resident uses the same supplied Host and driver barrier."""
    from glowcap.iroh import IrohConfig, Reachability, listen

    supplied = Host()
    server = await listen(IrohConfig(Reachability.LOCAL_DISCOVERY), host=supplied)
    accepted_task = asyncio.create_task(server.__anext__())
    client = None
    accepted = None
    try:
        assert server.host is supplied, (
            "iroh listener did not preserve the supplied Host wrapper"
        )
        from glowcap.iroh import provider as iroh_provider

        runtime = await Runtime.open(
            provider=iroh_provider(IrohConfig(Reachability.LOCAL_DISCOVERY))
        )
        client = await runtime.connect(server.locator)
        accepted = await asyncio.wait_for(accepted_task, timeout=10)
        await server.close()
        assert not supplied.released, (
            "iroh listener close released a yielded supplied Host"
        )
        await accepted.close()
        await client.close()
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        if not supplied.released:
            await supplied.close()


async def _listener_close_preserves_sibling() -> None:
    """Closing one listener leaves a sibling provider on the same Host usable."""
    supplied = Host()
    tcp_server = await tcp.listen("127.0.0.1", 0, host=supplied)
    keyed_server = await tcp.keyed.listen("127.0.0.1", 0, host=supplied)
    noise_server = await tcp.noise.listen("127.0.0.1", 0, host=supplied)
    client = None
    accepted = None
    try:
        await tcp_server.close()
        assert keyed_server.locator.transport == TRANSPORT_KEYED_TCP
        assert noise_server.locator.transport == TRANSPORT_NOISE_TCP
        assert parse_locator(keyed_server.uri) == keyed_server.locator
        assert parse_locator(noise_server.uri) == noise_server.locator
        client = await tcp_connect(keyed_server.locator)
        accepted = await asyncio.wait_for(keyed_server.__anext__(), timeout=5)
        assert not supplied.released, "closing one listener released the shared Host"
    finally:
        if accepted is not None:
            await accepted.close()
        if client is not None:
            await client.close()
        await keyed_server.close()
        await noise_server.close()
        if not supplied.released:
            await supplied.close()


async def _host_release_joins_dial_task() -> None:
    """CANCEL_DIAL joins the registered executor before acknowledging it.

    The fake executor is installed at the action seam that creates the task,
    so this proves the real Host registry and done
    callback rather than a second test-only task list.
    """
    import glowcap._dial as dial_module

    original = dial_module.run_dial_ticket
    started = asyncio.Event()
    finished = asyncio.Event()

    async def pending_dial(_host, _ticket, _route_index) -> None:
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
        from glowcap._action import _run_action
        from glowcap._host_action_gen import CancelDial, Dial

        await _run_action(host, Dial(ticket=7, route_index=0))
        await asyncio.wait_for(started.wait(), timeout=1)
        await _run_action(host, CancelDial(ticket=7, route_index=0))
        assert finished.is_set(), "CANCEL_DIAL returned before DIAL cleanup finished"
        await host.close()
        assert host._raw is None, (
            "Host close retained FFI authority after CANCEL_DIAL cleanup"
        )
        assert not host._dial_tasks, (
            "the Host-owned DIAL registry retained a finished task"
        )
    finally:
        dial_module.run_dial_ticket = original
        if host._raw is not None:
            await host.close()


async def _proof_refusal_releases_minted_session() -> None:
    """Failure between FFI mint and handshake has one teardown owner."""
    import glowcap._session as session_module

    class Transport:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS
        close_count = 0

        def close(self) -> None:
            self.close_count += 1

    host = Host()
    host.set_advertised_locator(
        Locator(
            TRANSPORT_TCP,
            tcp.address_designator("127.0.0.1", 1),
            {},
        )
    )
    transport = Transport()
    releases = 0
    original_bind = session_module._host.glowcap_host_session_bind_verified_channel_key
    original_release = session_module._host.glowcap_host_session_release

    def refuse_proof(*_args) -> int:
        return ERR_INVALID_ARGUMENT

    def count_release(raw) -> int:
        nonlocal releases
        releases += 1
        return original_release(raw)

    session_module._host.glowcap_host_session_bind_verified_channel_key = refuse_proof
    session_module._host.glowcap_host_session_release = count_release
    try:
        try:
            await session_module.Session.establish_dialed_locator(
                host,
                Locator(TRANSPORT_TCP, "127.0.0.1:2", {}, "boolean-false"),
                transport,
                verified_channel_key="00" * 32,
            )
        except GlowcapError as exc:
            assert exc.code == ERR_INVALID_ARGUMENT, exc.code
        else:
            raise AssertionError("a refused channel proof unexpectedly established")
        assert releases == 1, "proof refusal did not release exactly one FFI session"
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
        except GlowcapError as exc:
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
        session_module._host.glowcap_host_session_bind_verified_channel_key = (
            original_bind
        )
        session_module._host.glowcap_host_session_release = original_release
        await host.close()


async def _cancelled_iroh_open_releases_constructed_endpoint() -> None:
    """Cancellation cannot abandon an endpoint still constructing off-thread."""
    from glowcap.iroh import IrohConfig, IrohNetlayer, Reachability

    started = threading.Event()
    finish = threading.Event()
    released = threading.Event()
    cleanup_failure = RuntimeError("canceled iroh construction cleanup failed")
    glowcap.take_runtime_failures()

    class ControlledNetlayer(IrohNetlayer):
        def __init__(
            self, _config, _secret_seed=None, *, _construction_token=None
        ) -> None:
            started.set()
            finish.wait()

        async def close(self) -> None:
            released.set()
            raise cleanup_failure

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
    diagnostics = glowcap.take_runtime_failures()
    assert len(diagnostics) == 1, diagnostics
    assert diagnostics[0].operation == "iroh-release-after-cancel"
    assert diagnostics[0].primary_message == str(cleanup_failure)


async def _iroh_close_joins_after_cancellation() -> None:
    """A canceled close waiter cannot detach the FFI release task."""
    from glowcap.iroh import IrohNetlayer

    started = threading.Event()
    finish = threading.Event()
    calls = 0

    class ControlledNetlayer(IrohNetlayer):
        def __init__(self) -> None:
            self._close_task = None

        def _release_blocking(self) -> None:
            nonlocal calls
            calls += 1
            started.set()
            finish.wait()

    netlayer = ControlledNetlayer()
    close = asyncio.create_task(netlayer.close())
    assert await asyncio.to_thread(started.wait, 1), "close did not start"
    close.cancel()
    assert not close.done(), "close waiter detached before FFI teardown"
    finish.set()
    try:
        await close
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("close cancellation was not preserved")

    await netlayer.close()
    assert calls == 1, "repeated close started a second FFI release"


async def _session_close_joins_owned_transport_release() -> None:
    """Session.close joins transport cleanup after the core close effect."""
    from glowcap._session import Session
    from glowcap._session.writer import Outbound

    started = asyncio.Event()
    finish = asyncio.Event()

    class HostStub:
        def _assert_owner(self) -> None:
            pass

        def _track_session_retirement_failure(self, _error) -> None:
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
    session._outbound = Outbound(session)
    session._host = HostStub()
    session._transport = transport
    session._closing = False
    session._released = True
    session._close_future = None
    session._close_task = None
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = None
    session._wire_failure = None
    session._transport_lost = False
    session._transport_close_started = True
    session.close_transport = transport.close
    transport.close()

    closing = asyncio.create_task(session.close())
    await asyncio.wait_for(started.wait(), timeout=1)
    assert transport.closed, "the core close effect did not retire the transport"
    assert not closing.done(), "Session.close returned before transport completion"
    finish.set()
    await closing


async def _session_repeated_close_joins_published_failure() -> None:
    """Released state cannot let a repeated close outrun its shared result."""
    from glowcap._session import Session
    from glowcap._session.writer import Outbound

    class HostStub:
        def _assert_owner(self) -> None:
            pass

        def _track_session_retirement_failure(self, _error) -> None:
            pass

    session = Session.__new__(Session)
    session._outbound = Outbound(session)
    session._host = HostStub()
    session._transport = object()
    session._closing = True
    session._released = True
    session._close_future = asyncio.get_running_loop().create_future()
    session._close_task = None
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = None
    session._wire_failure = None
    session._transport_lost = False
    session._transport_close_started = True

    session._start_terminal_coordinator(session._close_future)
    repeated = asyncio.create_task(session.close())

    session._close_future.set_exception(
        GlowcapError(ERR_INVALID_ARGUMENT, "published close failure")
    )
    try:
        await repeated
    except GlowcapError as error:
        assert error.code == ERR_INVALID_ARGUMENT, error
    else:
        raise AssertionError("repeated close discarded the shared close failure")


async def _session_close_retains_every_terminal_failure() -> None:
    """The exact primary remains raised while later owned-barrier failures
    remain inspectable in deterministic observation order."""
    from glowcap._session import Session
    from glowcap._session.writer import Outbound

    primary = OSError("primary wire failure")
    close_result = RuntimeError("FFI close result failed")
    wait_closed = LookupError("transport wait_closed failed")
    serve_failure = ValueError("serve task failed")

    class HostStub:
        def _assert_owner(self) -> None:
            pass

        def _track_session_retirement_failure(self, _error) -> None:
            pass

    class TransportStub:
        def __init__(self) -> None:
            self.calls = 0

        async def wait_closed(self) -> None:
            self.calls += 1
            if self.calls == 1:
                raise wait_closed
            raise LookupError("duplicate wait_closed observation")

    async def rejected_result() -> None:
        raise close_result

    async def rejected_serve() -> None:
        raise serve_failure

    session = Session.__new__(Session)
    session._outbound = Outbound(session)
    session._host = HostStub()
    session._transport = TransportStub()
    session._released = True
    session._release_pending = False
    session._wire_failure = primary
    session._terminal_failures = []
    session._terminal_failure_count = 0
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = asyncio.create_task(rejected_serve())

    try:
        session._start_terminal_coordinator(rejected_result())
        await session._await_terminal()
    except BaseException as observed:
        assert observed is primary, "close replaced its exact first failure"
    else:
        raise AssertionError("close discarded its terminal failure chain")
    expected = (primary, close_result, wait_closed, serve_failure)
    assert session.terminal_failures == expected, session.terminal_failures
    assert session.terminal_failure_count == len(expected)

    try:
        await session._await_terminal()
    except BaseException as observed:
        assert observed is primary, "repeated close replaced its exact primary"
    else:
        raise AssertionError("repeated close discarded its terminal failure chain")
    assert session.terminal_failures == expected, (
        "repeated close duplicated or reordered retained failures"
    )
