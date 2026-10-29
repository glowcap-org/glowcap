"""A session's writer keeps write failures with that session, and a CLOSE
closes the transport only after the frames queued ahead of it. The Host
action drain only wakes the writer, so a slow write never holds the drain."""

from __future__ import annotations

import asyncio
import unittest
from typing import Optional

from glowcap import _constants as _abi
from glowcap._action import _Handlers
from glowcap._errors import GlowcapError
from glowcap._host_action_gen import Close, Flush
from glowcap._session.writer import Outbound


class _Owner:
    """The writer's Session seams, recording the order they were called in."""

    def __init__(self, failure: Optional[BaseException] = None) -> None:
        self.failure = failure
        self.gate: Optional[asyncio.Event] = None
        self.events: list[str] = []
        self.tasks: list[asyncio.Task[None]] = []

    async def flush_outbound(self) -> bool:
        self.events.append("flush")
        if self.gate is not None:
            await self.gate.wait()
        if self.failure is not None:
            self.events.append("retired")
            raise self.failure
        return True

    def close_transport(self) -> None:
        self.events.append("close_transport")

    def _finish_close(self, result: int) -> None:
        self.events.append(f"finish_close {result}")

    def _writer_wrote(self) -> None:
        self.events.append("kick")

    def _own_writer(self, task: "asyncio.Task[None]") -> None:
        self.tasks.append(task)


class _Session:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def request_flush(self) -> int:
        self.calls.append("request_flush")
        return 1

    def close_after_flush(self, result: int) -> None:
        self.calls.append(f"close_after_flush {result}")


class _Host:
    def __init__(self, session: _Session) -> None:
        self._session = session

    def get_session(self, _ptr: int) -> _Session:
        return self._session


class SessionWriterTest(unittest.TestCase):
    def test_the_drain_only_wakes_the_writer(self) -> None:
        session = _Session()
        handlers = _Handlers(_Host(session))
        asyncio.run(handlers.flush(Flush(session_ptr=7)))
        asyncio.run(handlers.close(Close(session_ptr=7, result=3)))
        self.assertEqual(session.calls, ["request_flush", "close_after_flush 3"])

    def test_a_write_failure_stays_with_the_session(self) -> None:
        async def run() -> None:
            owner = _Owner(OSError("write refused"))
            outbound = Outbound(owner)
            await outbound.written(outbound.request())
            await outbound.exited()
            # The failed pass retired the session, so later frames never leave.
            with self.assertRaises(GlowcapError) as caught:
                await outbound.written(outbound.request())
            self.assertEqual(caught.exception.code, _abi.ERR_CLOSED)
            self.assertEqual(owner.events, ["flush", "retired"])

        asyncio.run(run())

    def test_close_waits_for_the_frames_queued_ahead_of_it(self) -> None:
        async def run() -> None:
            owner = _Owner()
            owner.gate = asyncio.Event()
            outbound = Outbound(owner)
            outbound.request()
            await asyncio.sleep(0)
            # CLOSE lands while the first pass is writing.
            outbound.close_after_flush(0)
            self.assertTrue(outbound.close_delivered)
            owner.gate.set()
            await outbound.exited()
            self.assertEqual(
                owner.events,
                ["flush", "kick", "flush", "close_transport", "finish_close 0"],
            )

        asyncio.run(run())

    def test_close_after_a_retired_writer_still_settles(self) -> None:
        async def run() -> None:
            owner = _Owner(OSError("write refused"))
            outbound = Outbound(owner)
            outbound.request()
            await outbound.exited()
            outbound.close_after_flush(5)
            self.assertEqual(
                owner.events,
                ["flush", "retired", "close_transport", "finish_close 5"],
            )

        asyncio.run(run())

    def test_a_cancelled_writer_settles_its_waiters(self) -> None:
        async def run() -> None:
            owner = _Owner()
            owner.gate = asyncio.Event()
            outbound = Outbound(owner)
            outbound.request()
            outbound.close_after_flush(0)
            await asyncio.sleep(0)
            owner.tasks[0].cancel()
            await outbound.exited()
            with self.assertRaises(GlowcapError):
                await outbound.written(outbound.request())
            self.assertEqual(owner.events, ["flush", "finish_close 0"])

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()
