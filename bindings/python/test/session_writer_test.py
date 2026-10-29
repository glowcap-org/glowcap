"""A session's writer keeps write failures with that session, and a CLOSE
closes the transport only after the frames queued ahead of it. The Host
action drain only wakes the writer, so a slow write never holds the drain."""

from __future__ import annotations

import asyncio
import unittest
from typing import Optional
from unittest.mock import patch

from glowcap import Host, Locator, PendingWork, tcp
from glowcap import _constants as _abi
from glowcap import _pump
from glowcap._action import _Handlers
from glowcap._errors import GlowcapError
from glowcap._host_action_gen import Close, Flush
from glowcap._session.writer import Outbound
from glowcap._session import Session


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


class _SilentTransport:
    designator_scheme = _abi.DESIGNATOR_SCHEME_ADDRESS

    async def read(self):
        await asyncio.Future()

    async def write(self, data):
        pass

    def close(self):
        pass


class SessionWriterTest(unittest.TestCase):
    def test_finish_preserves_a_new_sealed_channel_failure(self) -> None:
        async def run() -> None:
            host, remote = Host(), Host()
            host.set_advertised_locator(Locator(
                _abi.TRANSPORT_NOISE_TCP, host.designator(), {}, "boolean-false"
            ))
            session = Session._open_dialed_locator(
                host,
                Locator(_abi.TRANSPORT_NOISE_TCP, remote.designator(), {}, "boolean-false"),
                _SilentTransport(),
            )
            await host.kick_actions()
            await session.written(session.request_flush())
            closing = asyncio.create_task(session.close(pending=PendingWork.FINISH, grace=None))
            try:
                await asyncio.sleep(0)
                self.assertTrue(session.is_closing)
                # An all-zero responder handshake has an invalid identity element.
                with self.assertRaises(GlowcapError) as caught:
                    await _pump._feed(session, bytes(144))
                refusal = caught.exception
                self.assertEqual(refusal.code, _abi.ERR_CLOSED)
                self.assertIn("IdentityElement", str(refusal))
                for observe in (closing, session.closed()):
                    with self.assertRaises(GlowcapError) as observed:
                        await asyncio.wait_for(observe, 3)
                    self.assertIs(observed.exception, refusal)
            finally:
                session.close_transport()
                await asyncio.gather(closing, host.close(), remote.close(), return_exceptions=True)

        asyncio.run(run())

    def test_local_cancellation_does_not_become_a_wire_failure(self) -> None:
        async def run(resume: bool) -> None:
            host = Host()
            session = Session._open_dialed_locator(
                host,
                Locator(
                    _abi.TRANSPORT_TCP,
                    tcp.address_designator("127.0.0.1", 1),
                    {},
                    "boolean-false",
                ),
                _SilentTransport(),
            )
            closing = asyncio.create_task(session.close())
            try:
                # Start cancellation before the reader, while its close driver
                # and writer remain queued on the next event-loop turn.
                await asyncio.sleep(0)
                self.assertTrue(session.is_closing)
                if resume:
                    await _pump._resume_feed(session)
                else:
                    await _pump._feed(session, b"late bytes")
                await asyncio.wait_for(closing, 3)
                await asyncio.wait_for(session.closed(), 3)
                self.assertEqual(session.terminal_failures, ())
            finally:
                session.close_transport()
                await asyncio.gather(closing, host.close(), return_exceptions=True)

        for resume in (False, True):
            with self.subTest(resume=resume):
                asyncio.run(run(resume))

    def test_feed_refusal_precedes_abort_delivery_failure(self) -> None:
        async def run(
            chunk: bytes, code: int, fail_write: bool, fail_diagnostic: bool
        ) -> None:
            write_failure = OSError("abort delivery failed")
            diagnostic_failure = RuntimeError("abort diagnostic failed")

            class Transport:
                designator_scheme = _abi.DESIGNATOR_SCHEME_ADDRESS
                reading = False

                async def read(self):
                    self.reading = True
                    return chunk

                async def write(self, data):
                    if self.reading and fail_write:
                        raise write_failure

                def close(self):
                    pass

            host = Host()
            session = Session._open_dialed_locator(
                host,
                Locator(
                    _abi.TRANSPORT_TCP,
                    tcp.address_designator("127.0.0.1", 1),
                    {},
                    "boolean-false",
                ),
                Transport(),
            )
            try:
                # The hello succeeds. Only the refusal's final drain may fail.
                await host.kick_actions()
                await session.written(session.request_flush())
                with patch.object(_pump, "last_abort", wraps=_pump.last_abort) as last_abort:
                    if fail_diagnostic:
                        last_abort.side_effect = diagnostic_failure
                    with self.assertRaises(GlowcapError) as caught:
                        await asyncio.wait_for(session.serve(), 3)
                refusal = caught.exception
                self.assertEqual(refusal.code, code)
                if fail_diagnostic:
                    self.assertEqual(refusal.secondary, (diagnostic_failure,))
                elif code == _abi.ERR_CODEC:
                    self.assertIsNotNone(refusal.abort)
                    self.assertEqual(refusal.abort.error_name, "MalformedFrame")
                for observe in (session.closed, session.close, session.closed):
                    with self.assertRaises(GlowcapError) as observed:
                        await asyncio.wait_for(observe(), 3)
                    self.assertIs(observed.exception, refusal)
                expected = (refusal,)
                if fail_diagnostic:
                    expected += (diagnostic_failure,)
                if fail_write:
                    expected += (write_failure,)
                self.assertEqual(session.terminal_failures, expected)
            finally:
                session.close_transport()
                # Cleanup may observe the failure under test too. It must not
                # replace a failing assertion with a second teardown exception.
                await asyncio.gather(host.close(), return_exceptions=True)

        for chunk, code in (
            (b"this is not a frame", _abi.ERR_CODEC),
            (b"2000000:", _abi.ERR_FRAME_TOO_LARGE),
        ):
            for fail_write in (False, True):
                for fail_diagnostic in (False, True):
                    with self.subTest(
                        code=code, fail_write=fail_write, fail_diagnostic=fail_diagnostic
                    ):
                        asyncio.run(run(chunk, code, fail_write, fail_diagnostic))

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
