"""WebRTC signaling adapter: callback routing without the WebRTC archive."""

from __future__ import annotations

import asyncio
import ctypes
import unittest
from unittest import mock

from glowcap import _constants as _c
from glowcap import webrtc
from glowcap._errors import GlowcapError

DESIGNATOR = "cd" * 32


class FakeHost:
    def __init__(self) -> None:
        self.failures: "list[tuple[str, BaseException]]" = []

    def _record_callerless_failure(self, operation: str, error: BaseException) -> None:
        self.failures.append((operation, error))


class Signaling:
    def __init__(
        self,
        *,
        candidate_error: "BaseException | None" = None,
        answer_error: "BaseException | None" = None,
    ) -> None:
        self.candidates: "list[tuple[int, str]]" = []
        self.offers: "list[tuple[int, webrtc.Target]]" = []
        self.answers: "list[tuple[int, webrtc.Target, str]]" = []
        self._answer_error = answer_error
        self.disposed = 0
        self.subscribed: "list[tuple[int, webrtc.Target]]" = []
        self._candidate_error = candidate_error

    async def offer(self, exchange: int, target: webrtc.Target, sdp: str) -> str:
        self.offers.append((exchange, target))
        await asyncio.sleep(3600)
        return sdp

    def answer(self, exchange: int, target: webrtc.Target, sdp: str) -> None:
        if self._answer_error is not None:
            raise self._answer_error
        self.answers.append((exchange, target, sdp))

    def candidate(self, exchange: int, ice: str) -> None:
        if self._candidate_error is not None:
            raise self._candidate_error
        self.candidates.append((exchange, ice))

    def on_candidate(self, exchange: int, target: webrtc.Target, sink):
        self.subscribed.append((exchange, target))

        def dispose() -> None:
            self.disposed += 1

        return dispose


def _bytes(text: str):
    data = text.encode()
    buffer = ctypes.create_string_buffer(data, len(data))
    return buffer, ctypes.cast(buffer, ctypes.POINTER(ctypes.c_uint8)), len(data)


class SignalerCase(unittest.IsolatedAsyncioTestCase):
    def _signaler(self, signaling: Signaling):
        host = FakeHost()
        signaler = webrtc._Signaler(
            signaling, asyncio.get_running_loop(), host, lambda: None
        )
        return signaler, host


class WebrtcSignalerTests(SignalerCase):

    async def test_exchange_routes_candidates_and_done_disposes(self) -> None:
        signaling = Signaling()
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        keep_i, ice, ilen = _bytes('{"candidate":"x"}')
        self.assertEqual(
            signaler.send_offer(None, 7, designator, dlen, None, 0, sdp, slen), _c.OK
        )
        self.assertEqual(signaling.subscribed, [(7, webrtc.Target(DESIGNATOR, None))])
        self.assertEqual(signaler.send_candidate(None, 7, ice, ilen), _c.OK)
        self.assertEqual(signaling.candidates, [(7, '{"candidate":"x"}')])
        signaler.done(None, 7)
        self.assertEqual(signaling.disposed, 1)
        signaler.done(None, 7)
        self.assertEqual(signaling.disposed, 1)
        self.assertEqual(host.failures, [])
        del keep_d, keep_s, keep_i

    async def test_an_introducer_reaches_every_signaling_call(self) -> None:
        signaling = Signaling()
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_n, introducer, nlen = _bytes("introducer-key")
        keep_s, sdp, slen = _bytes("v=0")
        keep_i, ice, ilen = _bytes("{}")
        target = webrtc.Target(DESIGNATOR, "introducer-key")
        self.assertEqual(
            signaler.send_offer(None, 3, designator, dlen, introducer, nlen, sdp, slen),
            _c.OK,
        )
        self.assertEqual(signaler.send_candidate(None, 3, ice, ilen), _c.OK)
        await asyncio.sleep(0)
        self.assertEqual(signaling.subscribed, [(3, target)])
        self.assertEqual(signaling.offers, [(3, target)])
        self.assertEqual(signaling.candidates, [(3, "{}")])
        signaler.done(None, 3)
        self.assertEqual(host.failures, [])
        del keep_d, keep_n, keep_s, keep_i

    async def test_two_exchanges_with_one_target_route_candidates_by_id(self) -> None:
        signaling = Signaling()
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        keep_i, ice, ilen = _bytes("{}")
        target = webrtc.Target(DESIGNATOR, None)
        self.assertEqual(
            signaler.send_offer(None, 1, designator, dlen, None, 0, sdp, slen), _c.OK
        )
        self.assertEqual(
            signaler.send_answer(None, 2, designator, dlen, sdp, slen), _c.OK
        )
        self.assertEqual(signaling.subscribed, [(1, target), (2, target)])
        self.assertEqual(signaler.send_candidate(None, 2, ice, ilen), _c.OK)
        self.assertEqual(signaler.send_candidate(None, 1, ice, ilen), _c.OK)
        self.assertEqual(signaling.candidates, [(2, "{}"), (1, "{}")])
        signaler.done(None, 1)
        self.assertEqual(signaling.disposed, 1)
        signaler.done(None, 2)
        self.assertEqual(signaling.disposed, 2)
        self.assertEqual(host.failures, [])
        del keep_d, keep_s, keep_i

    async def test_a_raising_candidate_refuses_the_dial_and_is_retained(self) -> None:
        boom = RuntimeError("signaling channel closed")
        signaler, host = self._signaler(Signaling(candidate_error=boom))
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        keep_i, ice, ilen = _bytes("{}")
        signaler.send_offer(None, 1, designator, dlen, None, 0, sdp, slen)
        self.assertEqual(signaler.send_candidate(None, 1, ice, ilen), _c.ERR_IO)
        self.assertEqual(host.failures, [("webrtc.send_candidate", boom)])
        signaler.done(None, 1)
        del keep_d, keep_s, keep_i


    async def test_a_failing_offer_gives_the_dial_up(self) -> None:
        boom = RuntimeError("peer offline")

        class Failing(Signaling):
            async def offer(self, exchange: int, target: webrtc.Target, sdp: str) -> str:
                raise boom

        failed: "list[int]" = []

        class FakeLibrary:
            def glowcap_webrtc_netlayer_fail_exchange(self, netlayer, exchange: int) -> int:
                failed.append(exchange)
                return _c.OK

        signaler, host = self._signaler(Failing())
        signaler.netlayer = ctypes.c_void_p(1)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        with mock.patch.object(webrtc, "_webrtc", lambda: FakeLibrary()):
            self.assertEqual(
                signaler.send_offer(None, 5, designator, dlen, None, 0, sdp, slen), _c.OK
            )
            for _ in range(4):
                await asyncio.sleep(0)
        self.assertEqual(host.failures, [("webrtc.offer", boom)])
        self.assertEqual(failed, [5])
        signaler.done(None, 5)
        del keep_d, keep_s


class FakeLibrary:
    """The archive verbs an accept reaches, recording each call."""

    def __init__(self, *, fail_code: int = _c.OK) -> None:
        self.calls: "list[tuple[str, int]]" = []
        self._fail_code = fail_code

    def glowcap_webrtc_netlayer_provide_offer(
        self, netlayer, peer, peer_len, sdp, sdp_len, out
    ) -> int:
        self.calls.append(("provide_offer", peer_len))
        out._obj.value = 9
        return self._fail_code

    def glowcap_webrtc_netlayer_fail_exchange(self, netlayer, exchange: int) -> int:
        self.calls.append(("fail_exchange", exchange))
        return self._fail_code


class WebrtcAcceptTests(SignalerCase):
    async def test_an_answer_registers_the_accept_and_done_disposes_it(self) -> None:
        signaling = Signaling()
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        keep_i, ice, ilen = _bytes("{}")
        target = webrtc.Target(DESIGNATOR, None)
        self.assertEqual(
            signaler.send_answer(None, 4, designator, dlen, sdp, slen), _c.OK
        )
        self.assertEqual(signaling.subscribed, [(4, target)])
        self.assertEqual(signaling.answers, [(4, target, "v=0")])
        self.assertEqual(signaler.send_candidate(None, 4, ice, ilen), _c.OK)
        self.assertEqual(signaling.candidates, [(4, "{}")])
        signaler.done(None, 4)
        self.assertEqual(signaling.disposed, 1)
        signaler.done(None, 4)
        self.assertEqual(signaling.disposed, 1)
        self.assertEqual(host.failures, [])
        del keep_d, keep_s, keep_i

    async def test_a_raising_answer_refuses_the_offer_and_undoes_the_accept(self) -> None:
        boom = RuntimeError("offerer left")
        signaling = Signaling(answer_error=boom)
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        self.assertEqual(
            signaler.send_answer(None, 4, designator, dlen, sdp, slen), _c.ERR_IO
        )
        self.assertEqual(host.failures, [("webrtc.send_answer", boom)])
        self.assertEqual(signaling.disposed, 1)
        keep_i, ice, ilen = _bytes("{}")
        self.assertEqual(signaler.send_candidate(None, 4, ice, ilen), _c.OK)
        self.assertEqual(signaling.candidates, [])
        del keep_d, keep_s, keep_i

    async def test_a_failing_subscription_refuses_the_offer(self) -> None:
        boom = RuntimeError("no subscription")

        class Unsubscribable(Signaling):
            def on_candidate(self, exchange: int, target: webrtc.Target, sink):
                raise boom

        signaling = Unsubscribable()
        signaler, host = self._signaler(signaling)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        self.assertEqual(
            signaler.send_answer(None, 4, designator, dlen, sdp, slen), _c.ERR_IO
        )
        self.assertEqual(host.failures, [("webrtc.send_answer", boom)])
        self.assertEqual(signaling.answers, [])
        del keep_d, keep_s

    async def test_provide_offer_returns_the_exchange_the_library_names(self) -> None:
        signaler, _host = self._signaler(Signaling())
        signaler.netlayer = ctypes.c_void_p(1)
        library = FakeLibrary()
        with mock.patch.object(webrtc, "_webrtc", lambda: library):
            self.assertEqual(signaler.provide_offer(DESIGNATOR, "v=0"), 9)
        self.assertEqual(library.calls, [("provide_offer", len(DESIGNATOR))])

    async def test_a_library_refusal_raises_and_starts_no_exchange(self) -> None:
        signaler, _host = self._signaler(Signaling())
        signaler.netlayer = ctypes.c_void_p(1)
        library = FakeLibrary(fail_code=_c.ERR_INVALID_ARGUMENT)
        with mock.patch.object(webrtc, "_webrtc", lambda: library), mock.patch.object(
            webrtc, "_webrtc_last_error", lambda: "names no key"
        ):
            with self.assertRaises(GlowcapError) as refused:
                signaler.provide_offer("zz", "v=0")
        self.assertEqual(refused.exception.code, _c.ERR_INVALID_ARGUMENT)
        self.assertEqual(signaler._exchanges, {})

    async def test_failing_an_unknown_exchange_raises_and_changes_nothing(self) -> None:
        signaling = Signaling()
        signaler, host = self._signaler(signaling)
        signaler.netlayer = ctypes.c_void_p(1)
        keep_d, designator, dlen = _bytes(DESIGNATOR)
        keep_s, sdp, slen = _bytes("v=0")
        signaler.send_answer(None, 4, designator, dlen, sdp, slen)
        library = FakeLibrary(fail_code=_c.ERR_INVALID_ARGUMENT)
        with mock.patch.object(webrtc, "_webrtc", lambda: library), mock.patch.object(
            webrtc, "_webrtc_last_error", lambda: "no such exchange"
        ):
            with self.assertRaises(GlowcapError) as refused:
                signaler.fail_exchange(77)
        self.assertEqual(refused.exception.code, _c.ERR_INVALID_ARGUMENT)
        self.assertEqual(library.calls, [("fail_exchange", 77)])
        self.assertEqual(list(signaler._exchanges), [4])
        self.assertEqual(signaling.disposed, 0)
        self.assertEqual(host.failures, [])
        signaler.done(None, 4)
        del keep_d, keep_s


class WebrtcSurfaceTests(unittest.TestCase):
    def test_locator_names_the_webrtc_transport(self) -> None:
        found = webrtc.locator(DESIGNATOR)
        self.assertEqual(found.transport, "webrtc")
        self.assertEqual(found.designator, DESIGNATOR)
        self.assertEqual(found.hints, {})

    def test_ice_records_borrow_the_configured_text(self) -> None:
        keep: list = []
        server = webrtc.IceServer(("stun:a.example.test:3478",), "user", "secret")
        records = webrtc._ice_records((server,), keep)
        self.assertEqual(records[0].url_count, 1)
        self.assertEqual(records[0].username.len, 4)
        self.assertEqual(records[0].credential.len, 6)


if __name__ == "__main__":
    unittest.main()
