"""Failure-injection proofs for Session's retained close coordinator."""

from __future__ import annotations

import asyncio
import gc


class _HostStub:
    def _assert_owner(self) -> None:
        pass

    def _track_session_retirement_failure(self, _error) -> None:
        pass


def _stub_session(transport, *, released: bool, wire_failure=None):
    """A Session over a stub Host and transport, before any close began."""
    from glowcap._session import Session

    session = Session.__new__(Session)
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
