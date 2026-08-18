"""Failure and close-barrier proofs for the Python reference relay."""

from __future__ import annotations

import asyncio
import importlib.util
import os
from typing import Any, cast
import unittest

from pancake._ws import _WebSocketTransport, _WS_MESSAGE_HIGH_WATER

RELAY_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "relay.py"
)
RELAY_SPEC = importlib.util.spec_from_file_location(
    "pancake_reference_relay", RELAY_PATH
)
assert RELAY_SPEC is not None and RELAY_SPEC.loader is not None
relay = cast(Any, importlib.util.module_from_spec(RELAY_SPEC))
RELAY_SPEC.loader.exec_module(relay)


class _Request:
    path = "/?to=example.invalid:1"


class _WebSocket:
    request = _Request()

    def __init__(self, read_failure: BaseException, close_failure: BaseException):
        self._read_failure = read_failure
        self._close_failure = close_failure

    def __aiter__(self):
        return self

    async def __anext__(self):
        raise self._read_failure

    async def send(self, _chunk: bytes) -> None:
        raise AssertionError("a failed inbound leg must not send")

    async def close(self, *_args) -> None:
        raise self._close_failure


class _Channel:
    def __init__(self, close_failure: BaseException):
        self._close_failure = close_failure
        self._parked = asyncio.Event()

    async def read(self):
        await self._parked.wait()
        return None

    async def write(self, _chunk: bytes) -> None:
        raise AssertionError("a failed inbound leg must not write")

    def close(self) -> None:
        self._parked.set()
        raise self._close_failure


class RelayFailureTests(unittest.IsolatedAsyncioTestCase):
    async def test_websocket_write_borrows_ordinary_and_segmented_bytes(self) -> None:
        class ClientWebSocket:
            def __init__(self) -> None:
                self.sent = []

            async def send(self, chunk) -> None:
                self.sent.append(chunk)

        websocket = ClientWebSocket()
        transport = _WebSocketTransport(websocket)
        ordinary = b"ordinary"
        await transport.write(ordinary)
        self.assertIs(websocket.sent[0], ordinary)

        oversized = bytes(_WS_MESSAGE_HIGH_WATER + 7)
        await transport.write(oversized)
        chunks = websocket.sent[1:]
        self.assertEqual([len(chunk) for chunk in chunks], [_WS_MESSAGE_HIGH_WATER, 7])
        self.assertTrue(all(isinstance(chunk, memoryview) for chunk in chunks))
        self.assertTrue(all(chunk.obj is oversized for chunk in chunks))

    async def test_pump_preserves_primary_and_both_close_failures(self) -> None:
        primary = OSError("WebSocket read failed")
        channel_close = OSError("channel close failed")
        websocket_close = OSError("WebSocket close failed")
        channel = _Channel(channel_close)
        websocket = _WebSocket(primary, websocket_close)
        original_open = relay._open_channel

        async def open_channel(_to, _locator):
            return channel

        relay._open_channel = open_channel
        try:
            with self.assertRaises(OSError) as raised:
                await relay._pump(websocket)
        finally:
            relay._open_channel = original_open
        self.assertIs(raised.exception, primary)
        self.assertEqual(getattr(primary, "secondary_count"), 2)
        self.assertEqual(
            getattr(primary, "secondary"), (channel_close, websocket_close)
        )

    async def test_tcp_close_runs_and_joins_both_release_phases(self) -> None:
        request_failure = OSError("writer close failed")
        barrier_failure = OSError("writer wait_closed failed")

        class Writer:
            def close(self) -> None:
                raise request_failure

            async def wait_closed(self) -> None:
                raise barrier_failure

        channel = relay._TcpChannel(object(), Writer())
        with self.assertRaises(OSError) as raised:
            await relay._close_channel(channel)
        self.assertIs(raised.exception, request_failure)
        self.assertEqual(getattr(request_failure, "secondary_count"), 1)
        self.assertEqual(getattr(request_failure, "secondary"), (barrier_failure,))


if __name__ == "__main__":
    unittest.main()
