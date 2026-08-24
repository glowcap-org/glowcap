"""Failure-injection proofs for Session's retained close coordinator."""

from __future__ import annotations

import asyncio
import gc


async def cancelled_close_waiter_preserves_transport_coordinator() -> None:
    """Caller cancellation cannot orphan the physical transport barrier."""
    from pancake._session import Session

    primary = OSError("exact preexisting wire failure")
    cleanup = LookupError("transport retirement failed")
    started = asyncio.Event()
    finish = asyncio.Event()

    class HostStub:
        def _assert_owner(self) -> None:
            pass

        def _track_session_retirement_failure(self, _error) -> None:
            pass

    class TransportStub:
        calls = 0

        async def wait_closed(self) -> None:
            self.calls += 1
            started.set()
            await finish.wait()
            raise cleanup

    session = Session.__new__(Session)
    session._host = HostStub()
    session._transport = TransportStub()
    session._released = True
    session._release_pending = False
    session._close_future = None
    session._close_task = None
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = None
    session._wire_failure = primary
    session._terminal_failures = []
    session._terminal_failure_count = 0
    session._transport_lost = False
    session._transport_close_started = True

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
    from pancake._session import Session

    primary = RuntimeError("loop close failed")
    cleanup = LookupError("loop transport retirement failed")
    started = asyncio.Event()
    finish = asyncio.Event()
    session = Session.__new__(Session)

    class HostStub:
        def _assert_owner(self) -> None:
            pass

        def _track_session_retirement_failure(self, _error) -> None:
            pass

    class LoopStub:
        calls = 0

        async def close_session(self, _ptr, _options) -> None:
            self.calls += 1
            started.set()
            await finish.wait()
            session._native_owner_did_release()
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

    session._host = HostStub()
    session._transport = TransportStub()
    session._ptr = object()
    session._released = False
    session._release_pending = False
    session._closing = False
    session._close_future = None
    session._close_task = None
    session._terminal_task = None
    session._loop_close_tasks = set()
    session._serve_task = None
    session._wire_failure = None
    session._terminal_failures = []
    session._terminal_failure_count = 0
    session._transport_lost = False
    session._transport_close_started = False

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
