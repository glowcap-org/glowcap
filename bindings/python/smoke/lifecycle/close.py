"""Session, Host, and driver-loop close-barrier scenarios."""

from __future__ import annotations

import asyncio
import socket

from glowcap import (
    tcp,
    Host,
    Locator,
    GlowcapError,
    PendingWork,
    Runtime,
    Symbol,
)
from glowcap._constants import (
    DESIGNATOR_SCHEME_ADDRESS,
    ERR_TIMEOUT,
    TRANSPORT_TCP,
)


async def _session_wire_failure_is_exact_and_retired() -> None:
    """A session-scoped FLUSH fault reaches every public observer only after
    the byte channel has crossed its retirement barrier."""
    from glowcap._session import Session

    class MemoryChannel:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS

        def __init__(self, hold_close: bool = False) -> None:
            self.inbound: asyncio.Queue[bytes | None] = asyncio.Queue()
            self.peer: "MemoryChannel | None" = None
            self.failure: BaseException | None = None
            self.closed = False
            self.close_done = asyncio.Event()
            self.close_started = asyncio.Event()
            self.hold_close = hold_close

        async def read(self) -> bytes | None:
            return await self.inbound.get()

        async def write(self, data: bytes) -> None:
            if self.failure is not None:
                raise self.failure
            if self.closed or self.peer is None or self.peer.closed:
                raise BrokenPipeError("memory channel is closed")
            await self.peer.inbound.put(bytes(data))

        def close(self) -> None:
            if self.closed:
                return
            self.close_started.set()
            self.closed = True
            self.inbound.put_nowait(None)
            if self.peer is not None:
                self.peer.inbound.put_nowait(None)
            if not self.hold_close:
                self.close_done.set()

        async def wait_closed(self) -> None:
            await self.close_done.wait()

    client_channel = MemoryChannel(hold_close=True)
    server_channel = MemoryChannel()
    client_channel.peer = server_channel
    server_channel.peer = client_channel
    client_host = Host()
    server_host = Host()
    designator = tcp.address_designator("127.0.0.1", 1)
    accepted = Session.establish_accepted(
        server_host,
        TRANSPORT_TCP,
        designator,
        server_channel,
    )
    dialed = Session.establish_dialed_locator(
        client_host,
        Locator(TRANSPORT_TCP, designator, {}, "boolean-false"),
        client_channel,
    )
    server_session, session = await asyncio.gather(accepted, dialed)
    server_session.publish("svc", lambda _verb, _args: Symbol("alive"))
    server_serving = server_session.serve()
    client_serving = session.serve()
    svc = await session.fetch("svc")

    first_failure = OSError("injected exact FLUSH failure")
    client_channel.failure = first_failure
    # tell returns once the deliver is queued, before the writer meets the
    # failure. The session keeps that exact failure for serve and every later
    # operation.
    await session.tell(svc, "ping", [])
    try:
        await client_serving
    except BaseException as error:
        assert error is first_failure, "serve lost the exact FLUSH failure"
    else:
        raise AssertionError("serve resolved after a failed FLUSH")
    try:
        await session.tell(svc, "ping", [])
    except BaseException as error:
        assert error is first_failure, "tell lost the exact FLUSH failure"
    else:
        raise AssertionError("tell accepted a session whose FLUSH failed")

    closing = asyncio.create_task(session.close())
    await client_channel.close_started.wait()
    assert not closing.done(), "close reported failure before transport retirement"
    client_channel.close_done.set()
    try:
        await closing
    except BaseException as error:
        assert error is first_failure, "close lost the exact FLUSH failure"
    else:
        raise AssertionError("close resolved after a failed FLUSH")

    await server_serving
    await asyncio.gather(client_host.close(), server_host.close())


async def _host_close_joins_session_transport_failure(
    *, asynchronous: bool = False, retired: bool = False
) -> None:
    """Host close owns physical channel retirement after consuming sessions."""
    from glowcap._session import Session

    class MemoryChannel:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS

        def __init__(self) -> None:
            self.inbound: asyncio.Queue[bytes | None] = asyncio.Queue()
            self.peer: "MemoryChannel | None" = None
            self.closed = False
            self.close_failure: BaseException | None = None
            self.wait_started = asyncio.Event()
            self.wait_finish = asyncio.Event()

        async def read(self) -> bytes | None:
            return await self.inbound.get()

        async def write(self, data: bytes) -> None:
            assert self.peer is not None
            await self.peer.inbound.put(bytes(data))

        def close(self) -> None:
            if self.closed:
                return
            self.closed = True
            self.inbound.put_nowait(None)
            if self.peer is not None:
                self.peer.inbound.put_nowait(None)
            if self.close_failure is not None and not asynchronous:
                raise self.close_failure

        async def wait_closed(self) -> None:
            self.wait_started.set()
            if asynchronous and self.close_failure is not None:
                await self.wait_finish.wait()
                raise self.close_failure

    client_channel = MemoryChannel()
    server_channel = MemoryChannel()
    client_channel.peer = server_channel
    server_channel.peer = client_channel
    client_host = Host()
    server_host = Host()
    designator = tcp.address_designator("127.0.0.1", 1)
    accepted = Session.establish_accepted(
        server_host,
        TRANSPORT_TCP,
        designator,
        server_channel,
    )
    dialed = Session.establish_dialed_locator(
        client_host,
        Locator(TRANSPORT_TCP, designator, {}, "boolean-false"),
        client_channel,
    )
    _, client_session = await asyncio.gather(accepted, dialed)
    close_failure = OSError("injected Host transport-close failure")
    client_channel.close_failure = close_failure
    if retired:
        client_session.close_transport()
    closing = asyncio.create_task(client_host.close())
    if asynchronous:
        await asyncio.wait_for(client_channel.wait_started.wait(), timeout=1)
        assert not closing.done(), "Host close completed before channel retirement"
        closing.cancel()
        try:
            await closing
        except asyncio.CancelledError:
            pass
        else:
            raise AssertionError("Host close waiter cancellation was not preserved")
        client_channel.wait_finish.set()
    try:
        if asynchronous:
            await client_host.close()
        else:
            await closing
    except BaseException as error:
        assert error is close_failure, "Host close lost its session transport failure"
    else:
        raise AssertionError("Host close swallowed its session transport failure")
    try:
        await client_host.close()
    except BaseException as error:
        assert error is close_failure, "repeated Host close replaced the exact failure"
    else:
        raise AssertionError("repeated Host close discarded its failure")
    await server_host.close()


async def _loop_close_joins_session_retirement(*, through_host: bool) -> None:
    """Driver and adopted Host observers join cleanup after native release."""
    from smoke.runtime import tcp_connect

    host = Host()
    server = await tcp.listen("127.0.0.1", 0, host=host)
    accepting = asyncio.create_task(server.__anext__())
    client = await tcp_connect(tcp.locator("127.0.0.1", server.port))
    session = await asyncio.wait_for(accepting, timeout=5)
    driver = host.driver_loop
    assert driver is not None
    started, finish = asyncio.Event(), asyncio.Event()
    cleanup = OSError("adopted Host asynchronous channel retirement failed")
    original_wait = session.transport.wait_closed

    async def wait_closed() -> None:
        started.set()
        await finish.wait()
        await original_wait()
        raise cleanup

    session.transport.wait_closed = wait_closed
    if not through_host:
        driver.close()
    observe = host.close if through_host else driver.wait_closed
    closing = asyncio.create_task(observe())
    await asyncio.wait_for(started.wait(), timeout=1)
    assert not closing.done(), "adopted close skipped physical retirement"
    closing.cancel()
    try:
        await closing
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("adopted close waiter cancellation was not preserved")
    finish.set()
    for _ in range(2):
        try:
            await asyncio.wait_for(observe(), timeout=1)
        except BaseException as error:
            assert error is cleanup, "adopted close replaced its exact cleanup failure"
        else:
            raise AssertionError("adopted close discarded its cleanup failure")
    assert not host._session_retirements, "completed retirement stayed Host-owned"
    assert asyncio.CancelledError not in tuple(type(e) for e in host.terminal_failures)
    await client.close()
    await server.close()


async def _cancelled_session_close_waiter_does_not_stop_driver() -> None:
    """A finite session finish keeps progressing after its first waiter leaves."""
    from glowcap._session import Session

    class PendingTransport:
        async def read(self) -> bytes:
            await asyncio.Future()

        async def write(self, _data: bytes) -> None:
            pass

        def close(self) -> None:
            pass

    close_admitted = asyncio.Event()

    class ObservedHost(Host):
        def signal_close_activity(self) -> None:
            close_admitted.set()
            super().signal_close_activity()

    host = ObservedHost()
    session = Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, "pending-session", {}, "boolean-false"),
        PendingTransport(),
    )

    first = asyncio.create_task(
        session.close(pending=PendingWork.FINISH, grace=0.02)
    )
    await close_admitted.wait()
    terminal = session._terminal_task
    assert terminal is not None, "close admission did not publish its coordinator"
    first.cancel()
    try:
        await first
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled Session.close waiter did not preserve cancellation")

    try:
        await asyncio.wait_for(asyncio.shield(terminal), timeout=1)
    except GlowcapError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("the shared finite finish discarded its timeout")
    assert session._released, "the finite close coordinator did not retire the Session"
    try:
        await session.close(pending=PendingWork.FINISH, grace=None)
    except GlowcapError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("the shared finite finish discarded its timeout")

    await host.close()


async def _repeated_host_close_observes_recorded_timeout() -> None:
    """A Host close that exhausted its finish grace keeps its outcome: a later
    close raises the recorded timeout instead of silently succeeding."""
    from glowcap._session import Session

    class PendingTransport:
        async def read(self) -> bytes:
            await asyncio.Future()

        async def write(self, _data: bytes) -> None:
            pass

        def close(self) -> None:
            pass

    host = Host()
    # The wrapper stays referenced so only Host.close drives the teardown.
    pending_session = Session._open_dialed_locator(
        host,
        Locator(TRANSPORT_TCP, "pending-session", {}, "boolean-false"),
        PendingTransport(),
    )

    try:
        await host.close(PendingWork.FINISH, grace=0.02)
    except GlowcapError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("a negotiating session let the finite finish settle in time")

    assert host.released, "the timed-out finish close did not reach its terminal release"
    try:
        await host.close()
    except GlowcapError as error:
        assert error.code == ERR_TIMEOUT, error
    else:
        raise AssertionError("repeated Host.close discarded the recorded timeout")
    del pending_session


async def _loop_finish_close_reports_finite_grace_timeout() -> None:
    """The same spent-grace outcome through the loop front (ADR-0024): the
    pending work is a Runtime dial whose partner accepted the socket and says
    nothing. After close begins nothing arrives on the wire and no verb runs,
    so the close driver's park over ``glowcap_driver_step_wait_ms`` is what
    spans the expiry, and its waking step escalates and reports the timeout."""
    silent = socket.socket()
    accepted = None
    try:
        silent.bind(("127.0.0.1", 0))
        silent.listen(1)
        silent.setblocking(False)
        port = silent.getsockname()[1]
        runtime = await Runtime.open(provider=tcp.provider(), handshake_timeout_ms=10_000)
        negotiating = asyncio.create_task(runtime.connect(tcp.locator("127.0.0.1", port)))
        driver_loop = runtime._loop
        assert driver_loop is not None, "a provider Runtime did not open on the loop tier"
        accepted, _ = await asyncio.wait_for(
            asyncio.get_running_loop().sock_accept(silent), timeout=1
        )
        assert driver_loop._pending_dials, "the dial never admitted its pending open"
        try:
            await asyncio.wait_for(runtime.close(PendingWork.FINISH, grace=0.02), 5)
        except GlowcapError as error:
            assert error.code == ERR_TIMEOUT, error
        else:
            raise AssertionError("a negotiating dial let the finite finish settle in time")
        try:
            await negotiating
        except (GlowcapError, asyncio.CancelledError):
            pass
    finally:
        if accepted is not None:
            accepted.close()
        silent.close()


async def _silent_loop_dial_reaches_ffi_handshake_deadline() -> None:
    """An ordinary dial has no close driver to wake it. The loop's one
    asyncio progress clock must therefore step when glowcap's handshake
    deadline expires, even though the accepted socket produces no fd edge."""
    listener = socket.socket()
    listener.setblocking(False)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    runtime = await Runtime.open(
        provider=tcp.provider(),
        handshake_timeout_ms=50,
    )
    accepted: socket.socket | None = None
    try:
        port = listener.getsockname()[1]
        dial = asyncio.create_task(
            runtime.connect(tcp.locator("127.0.0.1", port))
        )
        accepted, _address = await asyncio.wait_for(
            asyncio.get_running_loop().sock_accept(listener),
            timeout=1,
        )
        try:
            await asyncio.wait_for(dial, timeout=1)
        except GlowcapError as error:
            assert error.code == ERR_TIMEOUT, error
        else:
            raise AssertionError("a silent partner opened a session")
    finally:
        if accepted is not None:
            accepted.close()
        listener.close()
        await runtime.close()


async def _host_close_shuts_a_still_open_listener() -> None:
    """``await host.close()`` with a listener still open completes the barrier
    and shuts the listener down itself, ending its accept stream."""
    supplied = Host()
    server = await tcp.listen("127.0.0.1", 0, host=supplied)
    pending_accept = asyncio.ensure_future(server.__anext__())
    try:
        await asyncio.wait_for(supplied.close(), timeout=5)
        assert supplied.released, "Host close did not complete over the open listener"
        try:
            await asyncio.wait_for(pending_accept, timeout=1)
        except StopAsyncIteration:
            pass
        else:
            raise AssertionError("Host close did not end the open listener's accept stream")
    finally:
        if not pending_accept.done():
            pending_accept.cancel()
        await server.close()
        if not supplied.released:
            await supplied.close()


async def _observe_session_retirement_without_serve_or_close() -> None:
    """``Session.closed()`` waits for retirement without requesting close or
    starting inbound delivery. Independent and late observers share the
    terminal result. Cancelling one waiter leaves the session live."""
    from glowcap._session import Session

    class MemoryChannel:
        designator_scheme = DESIGNATOR_SCHEME_ADDRESS

        def __init__(self) -> None:
            self.inbound: asyncio.Queue[bytes | None] = asyncio.Queue()
            self.peer: MemoryChannel | None = None
            self.closed = False
            self.close_done = asyncio.Event()

        async def read(self) -> bytes | None:
            return await self.inbound.get()

        async def write(self, data: bytes) -> None:
            assert self.peer is not None
            await self.peer.inbound.put(bytes(data))

        def close(self) -> None:
            if self.closed:
                return
            self.closed = True
            self.inbound.put_nowait(None)
            if self.peer is not None:
                self.peer.inbound.put_nowait(None)
            self.close_done.set()

        async def wait_closed(self) -> None:
            await self.close_done.wait()

    client_channel = MemoryChannel()
    server_channel = MemoryChannel()
    client_channel.peer = server_channel
    server_channel.peer = client_channel
    client_host = Host()
    server_host = Host()
    designator = tcp.address_designator("127.0.0.1", 1)
    accepted = Session.establish_accepted(
        server_host,
        TRANSPORT_TCP,
        designator,
        server_channel,
    )
    dialed = Session.establish_dialed_locator(
        client_host,
        Locator(TRANSPORT_TCP, designator, {}, "boolean-false"),
        client_channel,
    )
    server_session, session = await asyncio.gather(accepted, dialed)
    first = asyncio.create_task(session.closed())
    second = asyncio.create_task(session.closed())
    await asyncio.sleep(0)
    assert session._serve_task is None, "watching retirement started inbound delivery"
    assert session.session_open, "watching retirement closed the session"
    first.cancel()
    try:
        await first
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancelled closed() waiter must surface cancellation")
    assert session.session_open, "cancelling a closed() waiter closed the session"
    assert not second.done(), "one observer's cancellation settled another"
    closer = asyncio.create_task(session.close())
    second_error: BaseException | None = None
    try:
        await second
    except BaseException as error:
        second_error = error
    close_error: BaseException | None = None
    try:
        await closer
    except BaseException as error:
        close_error = error
    assert second_error is close_error, (
        "independent observers must share the terminal result"
    )
    late_error: BaseException | None = None
    try:
        await session.closed()
    except BaseException as error:
        late_error = error
    assert late_error is close_error, "a late observer must share the terminal result"
    await server_session.close()
    await asyncio.gather(client_host.close(), server_host.close())
