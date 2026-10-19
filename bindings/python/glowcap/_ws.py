"""The WebSocket byte transport for the keyed-relay rendezvous dial (ADR-0034).

A ``keyed-relay`` peer holds an inbound socket at a relay under its key
designator. The dialer opens the relay's rendezvous leg and the keyed OCapN
handshake runs end to end over it. This module adapts one client WebSocket to
the three-verb transport record the byte-fed pump reads (see
``_dial._StreamTransport``): each binary message is one inbound chunk, and the
host's stream delimiter owns framing, exactly as over TCP.

The ``websockets`` package is an optional extra, the core binding keeps its
stdlib-ctypes-only promise, so the import happens here, at dial time, and a
missing package is a typed refusal naming the fix rather than an ImportError
at module load.
"""

from __future__ import annotations

import asyncio
import contextlib
from typing import Optional

from . import _constants as _abi
from ._constants import ERR_INVALID_ARGUMENT
from ._errors import GlowcapError


# A WebSocket message is a transport chunk and may coalesce several CapTP
# frames. Keep this independent from DEFAULT_FRAME_CAP; `websockets` enforces
# it before retaining an untrusted message for the binding.
_WS_MESSAGE_HIGH_WATER = _abi.BINDING_WEBSOCKET_MESSAGE_CAP_BYTES


async def connect_websocket(url: str) -> "_WebSocketTransport":
    """Open a WebSocket to ``url`` and adapt it to the byte-transport record.
    Refuses with a typed error when the optional ``websockets`` package is not
    installed (``pip install glowcap[rendezvous]``)."""
    try:
        import websockets
    except ImportError as exc:
        raise GlowcapError(
            ERR_INVALID_ARGUMENT,
            "keyed-relay dial needs the optional websockets package: "
            "pip install glowcap[rendezvous]",
        ) from exc
    ws = await websockets.connect(url, max_size=_WS_MESSAGE_HIGH_WATER)
    return _WebSocketTransport(ws)


class _WebSocketTransport:
    """One client WebSocket as the byte-transport record. ``read`` returns one
    message's bytes (``None`` at a clean close), ``write`` sends one binary
    message and awaits the library's backpressure, and ``close`` schedules the
    close handshake without blocking the caller (the record's ``close`` is
    synchronous, as over TCP)."""

    designator_scheme = _abi.DESIGNATOR_SCHEME_KEY

    def __init__(self, ws) -> None:
        self._ws = ws
        self._close_task: Optional[asyncio.Task[None]] = None

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
        if not isinstance(message, bytes):
            await self._ws.close(code=1003, reason="binary messages required")
            raise GlowcapError(
                ERR_INVALID_ARGUMENT,
                "keyed-relay WebSocket received a text message",
            )
        return message

    async def write(self, data: bytes) -> None:
        if len(data) <= _WS_MESSAGE_HIGH_WATER:
            await self._ws.send(data)
            return
        # Keep each WebSocket message within the same transport bound enforced
        # on receive. Message boundaries carry no CapTP meaning, so splitting
        # here is byte-transparent and lets large frames traverse the relay.
        # A memoryview keeps segmentation from making a second Python bytes
        # copy. The WebSocket runtime still owns the one framing/masking copy
        # required after this await boundary.
        view = memoryview(data)
        for offset in range(0, len(view), _WS_MESSAGE_HIGH_WATER):
            await self._ws.send(view[offset : offset + _WS_MESSAGE_HIGH_WATER])

    def close(self) -> None:
        if self._close_task is not None:
            return
        with contextlib.suppress(RuntimeError):
            loop = asyncio.get_running_loop()
            # Session's generic transport barrier calls `wait_closed`, which
            # joins this exact task and propagates its result. Retaining it here
            # also keeps an implicit close alive until the adapter is released.
            self._close_task = loop.create_task(self._ws.close())

    async def wait_closed(self) -> None:
        self.close()
        task = self._close_task
        if task is None:
            raise GlowcapError(
                _abi.ERR_INTERNAL,
                "keyed-relay WebSocket close requires a running event loop",
            )
        await asyncio.shield(task)
