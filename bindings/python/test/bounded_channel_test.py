"""Two peers over a channel smaller than one frame. Each must keep reading
while its own write waits, or each waits for the other to read."""

from __future__ import annotations

import asyncio
import unittest
from typing import Optional

from glowcap import Host, Session, tcp
from glowcap import _constants as _abi


class _Pipe:
    """One direction of an in-memory stream that holds at most ``capacity``
    bytes, so a writer waits until the reader takes what is buffered."""

    def __init__(self, capacity: int) -> None:
        self._capacity = capacity
        self._chunks: list[bytes] = []
        self._size = 0
        self._closed = False
        self._changed = asyncio.Condition()

    async def write(self, data: bytes) -> None:
        data = bytes(data)
        offset = 0
        async with self._changed:
            while offset < len(data):
                if self._closed:
                    raise OSError("pipe closed")
                room = self._capacity - self._size
                if room == 0:
                    await self._changed.wait()
                    continue
                end = min(len(data), offset + room)
                self._chunks.append(data[offset:end])
                self._size += end - offset
                offset = end
                self._changed.notify_all()

    async def read(self) -> Optional[bytes]:
        async with self._changed:
            while True:
                if self._chunks:
                    chunk = self._chunks.pop(0)
                    self._size -= len(chunk)
                    self._changed.notify_all()
                    return chunk
                if self._closed:
                    return None
                await self._changed.wait()

    def close(self) -> None:
        self._closed = True
        asyncio.get_running_loop().create_task(self._wake())

    async def _wake(self) -> None:
        async with self._changed:
            self._changed.notify_all()


class _End:
    designator_scheme = _abi.DESIGNATOR_SCHEME_ADDRESS

    def __init__(self, inbound: _Pipe, outbound: _Pipe) -> None:
        self._inbound = inbound
        self._outbound = outbound

    async def read(self) -> Optional[bytes]:
        return await self._inbound.read()

    async def write(self, data: bytes) -> None:
        await self._outbound.write(data)

    def close(self) -> None:
        self._inbound.close()
        self._outbound.close()


async def _exchange(capacity: int) -> None:
    exporter = Host()
    dialer = Host()
    serving: list[asyncio.Task[None]] = []
    try:
        exporter.publish("echo", lambda _verb, args: args[0])
        forward = _Pipe(capacity)
        backward = _Pipe(capacity)
        accepted, dialed = await asyncio.gather(
            Session.establish_accepted(
                exporter, "tcp", "127.0.0.1:9011", _End(forward, backward),
                handshake_timeout_ms=5_000,
            ),
            Session.establish_dialed_locator(
                dialer, tcp.locator("127.0.0.1", 9011), _End(backward, forward),
                handshake_timeout_ms=5_000,
            ),
        )
        serving += [accepted.serve(), dialed.serve()]
        echo = await dialed.fetch("echo")

        async def one(index: int) -> None:
            payload = bytes([index]) * 4096
            reply = await dialed.send(echo, "echo", [payload])
            assert reply == payload, f"echo {index} returned other bytes"

        await asyncio.wait_for(asyncio.gather(*(one(i) for i in range(4))), 10)
    finally:
        await dialer.close()
        await exporter.close()
        await asyncio.gather(*serving, return_exceptions=True)


class BoundedChannelTest(unittest.TestCase):
    def test_a_pipe_smaller_than_a_frame_carries_both_directions_at_once(self) -> None:
        asyncio.run(_exchange(64))


if __name__ == "__main__":
    unittest.main()
