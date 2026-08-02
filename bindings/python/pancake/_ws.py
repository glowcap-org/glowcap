"""The WebSocket byte transport for the keyed-relay rendezvous dial (ADR-0088).

A ``keyed-relay`` peer holds an inbound socket at a relay under its key
designator; the dialer opens the relay's rendezvous leg and the keyed OCapN
handshake runs end to end over it. This module adapts one client WebSocket to
the three-verb transport record the byte-fed pump reads (see
``_dial._StreamTransport``): each binary message is one inbound chunk, and the
host's stream delimiter owns framing, exactly as over TCP.

The ``websockets`` package is an optional extra — the core binding keeps its
stdlib-ctypes-only promise — so the import happens here, at dial time, and a
missing package is a typed refusal naming the fix rather than an ImportError
at module load.
"""

from __future__ import annotations

import asyncio
import contextlib
from typing import Optional

from ._constants import ERR_INVALID_ARGUMENT
from ._errors import PancakeError


async def connect_websocket(url: str) -> "_WebSocketTransport":
    """Open a WebSocket to ``url`` and adapt it to the byte-transport record.
    Refuses with a typed error when the optional ``websockets`` package is not
    installed (``pip install pancake[rendezvous]``, or
    ``uv run --with websockets``)."""
    try:
        import websockets
    except ImportError as exc:
        raise PancakeError(
            ERR_INVALID_ARGUMENT,
            "keyed-relay dial needs the optional websockets package: "
            "pip install pancake[rendezvous], or uv run --with websockets",
        ) from exc
    ws = await websockets.connect(url, max_size=None)
    return _WebSocketTransport(ws)


class _WebSocketTransport:
    """One client WebSocket as the byte-transport record. ``read`` returns one
    message's bytes (``None`` at a clean close), ``write`` sends one binary
    message and awaits the library's backpressure, and ``close`` schedules the
    close handshake without blocking the caller (the record's ``close`` is
    synchronous, as over TCP)."""

    def __init__(self, ws) -> None:
        self._ws = ws

    async def read(self) -> Optional[bytes]:
        import websockets

        try:
            message = await self._ws.recv()
        except websockets.exceptions.ConnectionClosedOK:
            return None
        except websockets.exceptions.ConnectionClosed:
            # A dropped socket is a transport error, not a graceful end of
            # stream; the serve loop's teardown classifies it.
            raise
        return message if isinstance(message, bytes) else message.encode()

    async def write(self, data: bytes) -> None:
        await self._ws.send(data)

    def close(self) -> None:
        with contextlib.suppress(RuntimeError):
            loop = asyncio.get_running_loop()
            task = loop.create_task(self._ws.close())
            # The close handshake owns its own lifetime; the reference keeps the
            # task from being collected mid-flight.
            task.add_done_callback(lambda _t: None)
