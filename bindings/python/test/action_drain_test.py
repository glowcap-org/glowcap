"""The Host action drain leaves a session's flush failure with that session
and lets its own cancellation through, on the flush arm and the close arm
alike."""

from __future__ import annotations

import asyncio
import unittest

from glowcap._action import _Handlers
from glowcap._host_action_gen import Close, Flush


class _Session:
    def __init__(self, failure: BaseException) -> None:
        self._failure = failure
        self.transport_closed = 0
        self.finished_with: list[int] = []

    async def flush_outbound(self) -> None:
        raise self._failure

    def close_transport(self) -> None:
        self.transport_closed += 1

    def _finish_close(self, result: int) -> None:
        self.finished_with.append(result)


class _Host:
    def __init__(self, session: _Session) -> None:
        self._session = session

    def get_session(self, _ptr: int) -> _Session:
        return self._session


class ActionDrainTest(unittest.TestCase):
    def test_flush_failure_stays_with_the_session(self) -> None:
        # Session.flush_outbound retained the cause and retired the stream;
        # the drain moves on to unrelated sessions.
        session = _Session(OSError("write refused"))
        asyncio.run(_Handlers(_Host(session)).flush(Flush(session_ptr=7)))

    def test_flush_cancellation_propagates(self) -> None:
        # A cancelled drain is the drain being stopped, not the session
        # failing: it must not keep draining past its cancellation.
        session = _Session(asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError):
            asyncio.run(_Handlers(_Host(session)).flush(Flush(session_ptr=7)))

    def test_close_arm_holds_the_same_line(self) -> None:
        session = _Session(asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError):
            asyncio.run(_Handlers(_Host(session)).close(Close(session_ptr=7, result=0)))
        self.assertEqual(session.transport_closed, 0)
        failing = _Session(OSError("write refused"))
        asyncio.run(_Handlers(_Host(failing)).close(Close(session_ptr=7, result=0)))
        self.assertEqual(failing.transport_closed, 1)
        self.assertEqual(failing.finished_with, [0])


if __name__ == "__main__":
    unittest.main()
