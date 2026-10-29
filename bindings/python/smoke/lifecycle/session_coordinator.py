"""Failure-injection proofs for Session's retained close coordinator."""

from __future__ import annotations

import asyncio
import gc


class _HostStub:
    def _assert_owner(self) -> None:
        pass

    def _track_session_retirement_failure(self, _error) -> None:
        pass

    def _own_session_writer(self, _task) -> None:
        pass

    def _own_session_retirement(self, _session) -> None:
        pass


def _stub_session(transport, *, released: bool, wire_failure=None):
    """A Session over a stub Host and transport, before any close began."""
    from glowcap._session import Session
    from glowcap._session.writer import Outbound

    session = Session.__new__(Session)
    session._outbound = Outbound(session)
    session._host = _HostStub()
    session._transport = transport
    session._ptr = None if released else object()
    session._released = released
    session._release_pending = False
    session._closing = False
    session._close_future = None
    session._close_task = None
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = None
    session._wire_failure = wire_failure
    session._terminal_failures = []
    session._terminal_failure_count = 0
    session._transport_lost = False
    session._transport_close_started = released
    return session


async def cancelled_close_waiter_preserves_transport_coordinator() -> None:
    """Caller cancellation cannot orphan the physical transport barrier."""
    primary = OSError("exact preexisting wire failure")
    cleanup = LookupError("transport retirement failed")
    started = asyncio.Event()
    finish = asyncio.Event()

    class TransportStub:
        calls = 0

        async def wait_closed(self) -> None:
            self.calls += 1
            started.set()
            await finish.wait()
            raise cleanup

    session = _stub_session(TransportStub(), released=True, wire_failure=primary)

    waiter = asyncio.create_task(session.close())
    await asyncio.wait_for(started.wait(), timeout=1)
    terminal = session._terminal_task
    assert terminal is not None
    waiter.cancel()
    try:
        await waiter
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("close waiter cancellation was not preserved")
    gc.collect()
    assert not terminal.done(), "caller cancellation abandoned the coordinator"
    assert session._transport.calls == 1

    finish.set()
    try:
        await session.close()
    except BaseException as observed:
        assert observed is primary
    else:
        raise AssertionError("repeated close discarded the exact wire failure")
    assert session.terminal_failures == (primary, cleanup)
    assert session._transport.calls == 1, "wait_closed ran more than once"


async def cancelled_loop_close_waiter_preserves_terminal_chain() -> None:
    """The Session coordinator strongly owns a loop-backed close coroutine."""
    primary = RuntimeError("loop close failed")
    cleanup = LookupError("loop transport retirement failed")
    started = asyncio.Event()
    finish = asyncio.Event()

    class LoopStub:
        calls = 0

        async def close_session(self, _ptr, _options) -> None:
            self.calls += 1
            started.set()
            await finish.wait()
            session._ffi_owner_did_release()
            raise primary

    class TransportStub:
        def __init__(self) -> None:
            self._driver_loop = LoopStub()
            self.wait_calls = 0

        def close(self) -> None:
            pass

        async def wait_closed(self) -> None:
            self.wait_calls += 1
            raise cleanup

    session = _stub_session(TransportStub(), released=False)

    waiter = asyncio.create_task(session.close())
    await asyncio.wait_for(started.wait(), timeout=1)
    terminal = session._terminal_task
    assert terminal is not None
    waiter.cancel()
    try:
        await waiter
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("loop close waiter cancellation was not preserved")
    gc.collect()
    assert not terminal.done(), "loop close coroutine lost its strong owner"

    finish.set()
    try:
        await session.close()
    except BaseException as observed:
        assert observed is primary
    else:
        raise AssertionError("loop close discarded its exact primary")
    assert session.terminal_failures == (primary, cleanup)
    assert session._transport._driver_loop.calls == 1
    assert session._transport.wait_calls == 1


async def partner_release_keeps_a_freed_handle_from_loop_close() -> None:
    """A loop close scheduled before the partner's close released the handle
    never passes the freed handle to the FFI, and close still completes."""

    class LoopStub:
        calls = 0

        async def close_session(self, _ptr, _options) -> None:
            self.calls += 1

    class TransportStub:
        def __init__(self) -> None:
            self._driver_loop = LoopStub()

        def close(self) -> None:
            pass

        async def wait_closed(self) -> None:
            pass

    session = _stub_session(TransportStub(), released=False)
    waiter = asyncio.create_task(session.close())
    # asyncio runs ready callbacks in order: `close` schedules its loop
    # request, then this resumes, then the request runs. The partner's
    # release lands in that gap.
    await asyncio.sleep(0)
    assert session._terminal_task is not None, "close did not schedule its request"
    session._ffi_owner_did_release()
    await asyncio.wait_for(waiter, timeout=1)
    assert session._transport._driver_loop.calls == 0, "a released handle reached the FFI"
    assert session.terminal_failures == ()


async def passive_observers_join_physical_retirement(*, pending_writer=False) -> None:
    """An unsolicited retirement has the same barrier as explicit close."""
    started, finish, retired = asyncio.Event(), asyncio.Event(), asyncio.Event()
    cleanup = LookupError("passive transport retirement failed")

    class TransportStub:
        calls = 0

        def close(self) -> None:
            pass

        async def wait_closed(self) -> None:
            self.calls += 1
            started.set()
            await finish.wait()
            retired.set()
            raise cleanup

    session = _stub_session(TransportStub(), released=False)
    writer_started, writer_finish = asyncio.Event(), asyncio.Event()

    async def flush() -> bool:
        writer_started.set()
        await writer_finish.wait()
        return False

    if pending_writer:
        session.flush_outbound = flush
        session.request_flush()
        await asyncio.wait_for(writer_started.wait(), timeout=1)
    first = asyncio.create_task(session.closed())
    second = asyncio.create_task(session.closed())
    await asyncio.sleep(0)
    session._ffi_owner_did_release()
    await asyncio.wait_for(started.wait(), timeout=1)
    assert not second.done(), "closed() completed before physical retirement"
    first.cancel()
    try:
        await first
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("passive observer cancellation was not preserved")
    assert not second.done(), "one cancelled observer retired the shared barrier"
    finish.set()
    if pending_writer:
        await asyncio.wait_for(retired.wait(), timeout=1)
        assert not session._terminal_task.done(), "physical close left an active writer unjoined"
        writer_finish.set()
    for observe in (lambda: second, session.closed, session.close):
        try:
            await observe()
        except BaseException as error:
            assert error is cleanup, "passive retirement lost its exact failure"
        else:
            raise AssertionError("passive retirement discarded the cleanup failure")
    assert session._transport.calls == 1, "retirement ran once per observer"
