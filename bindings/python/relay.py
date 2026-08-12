#!/usr/bin/env python3
"""A byte-transparent relay in Python — the second-runtime reference for the
ADR-0086 relay contract, proving the contract is language-neutral and not a
TypeScript shape with a doc wrapper.

It carries the raw bytes of a keyed CapTP session between a browser peer's
WebSocket and a native host, without parsing them, so the keyed handshake and
session authority run end to end and the relay holds no capability. This is the
same five-part shape ADR-0086 names, in Python: the WebSocket adapter is
`websockets`, the pump is `_pump`, the byte channel is a `_TcpChannel` or the
iroh binding's relay transport, the dial dispatcher is `_open_channel`, and the
config is the two constants below. The embedding app would add the target
allow-list; this proof relays wherever the conformance test points it.

Two transports, dispatched by what the WebSocket names:
  - `?to=host:port`  a raw TCP socket (byte-level, kernel-backpressured; no
                     pancake binding needed).
  - `?locator=<ocapn-uri>`  an iroh byte channel dialed through the Python iroh
                     binding's `dial_locator_for_relay`, the same C-ABI conn and
                     readiness primitives every binding drives.

Run with a WebSocket server provided hermetically by uv:
    uv run --project bindings/python --extra rendezvous --locked \
        python3 bindings/python/relay.py <listen-port>
Prints `PYTHON-RELAY-READY <port>` on stdout once listening.
"""

from __future__ import annotations

import asyncio
import os
import sys
from urllib.parse import parse_qs, urlparse

import websockets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The two bounded-resources knobs ADR-0086's contract names, matching the
# @pancake/relay gold standard. The idle timeout reclaims a stalled pair; the
# per-session byte total is a runaway backstop over the session's life, not a
# memory bound (instantaneous memory is bounded by the backpressure on both
# legs). Both sit far above any real chat session. The conformance idle-timeout
# proof sets PANCAKE_RELAY_IDLE_MS low; a production run leaves it unset.
IDLE_TIMEOUT_S = float(os.environ.get("PANCAKE_RELAY_IDLE_MS", "60000")) / 1000.0
MAX_BYTES_PER_SESSION = 1 << 30  # 1 GiB
READ_CHUNK = 1 << 16  # 64 KiB


class _TcpChannel:
    """A raw TCP byte channel over an asyncio stream: read/write/close, the same
    shape the iroh relay transport exposes so the pump is transport-agnostic."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self._reader = reader
        self._writer = writer

    async def read(self):
        chunk = await self._reader.read(READ_CHUNK)
        return chunk if chunk else None

    async def write(self, data: bytes) -> None:
        self._writer.write(data)
        await self._writer.drain()  # TCP-leg backpressure

    def close(self) -> None:
        try:
            self._writer.close()
        except OSError:
            pass  # already closed


async def _open_channel(target_to, target_locator):
    """Dial classifier: a `host:port` opens a raw socket, an iroh `ocapn://`
    locator opens the iroh relay channel. One of the two must be present."""
    if target_locator is not None:
        from pancake.iroh import Reachability, dial_locator_for_relay

        # The conformance host advertises loopback direct addresses, so the relay
        # reaches it directly; a deployment relay resolves node ids by discovery.
        return await dial_locator_for_relay(target_locator, Reachability.DIRECT)
    host, _, port_text = (target_to or "").rpartition(":")
    reader, writer = await asyncio.open_connection(host, int(port_text))
    return _TcpChannel(reader, writer)


async def _pump(websocket) -> None:
    """Relay one accepted WebSocket to the channel its query names, both
    directions, until either leg ends. Teardown is pair-atomic."""
    query = parse_qs(urlparse(websocket.request.path).query)
    target_to = (query.get("to") or [None])[0]
    target_locator = (query.get("locator") or [None])[0]
    if target_locator is None and (not target_to or ":" not in target_to):
        await websocket.close(1008, "relay requires ?to=host:port or ?locator=<uri>")
        return

    try:
        channel = await _open_channel(target_to, target_locator)
    except Exception as e:
        print(f"relay: dial failed: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        # 1011 tells the browser the relay leg failed, not the session.
        await websocket.close(1011, "relay dial failed")
        return

    transferred = 0
    loop = asyncio.get_running_loop()
    last_activity = loop.time()

    def touch() -> None:
        # Any chunk in either direction re-arms the idle timeout.
        nonlocal last_activity
        last_activity = loop.time()

    async def close_both() -> None:
        try:
            channel.close()
        except Exception:
            pass  # already closed
        try:
            await websocket.close()
        except websockets.WebSocketException:
            pass  # already closed

    async def ws_to_channel() -> None:
        nonlocal transferred
        try:
            async for message in websocket:
                if isinstance(message, str):
                    message = message.encode()
                touch()
                transferred += len(message)
                if transferred > MAX_BYTES_PER_SESSION:
                    return
                await channel.write(message)
        except (websockets.WebSocketException, OSError):
            pass  # leg ended

    async def channel_to_ws() -> None:
        nonlocal transferred
        try:
            while True:
                chunk = await channel.read()
                if chunk is None:
                    return
                touch()
                transferred += len(chunk)
                if transferred > MAX_BYTES_PER_SESSION:
                    return
                # `websockets.send` awaits its write buffer draining, which is the
                # browser-bound leg's backpressure the contract mandates.
                await websocket.send(chunk)
        except (websockets.WebSocketException, OSError):
            pass  # leg ended

    async def idle_watchdog() -> None:
        # Reclaim a stalled pair: return once neither leg has moved a chunk for
        # IDLE_TIMEOUT_S, which completes the wait below and tears both legs down.
        while True:
            idle_for = loop.time() - last_activity
            if idle_for >= IDLE_TIMEOUT_S:
                return
            await asyncio.sleep(IDLE_TIMEOUT_S - idle_for)

    legs = (
        asyncio.create_task(ws_to_channel()),
        asyncio.create_task(channel_to_ws()),
        asyncio.create_task(idle_watchdog()),
    )
    try:
        await asyncio.wait(set(legs), return_when=asyncio.FIRST_COMPLETED)
    finally:
        await close_both()
        for leg in legs:
            leg.cancel()
        await asyncio.gather(*legs, return_exceptions=True)


async def _main() -> None:
    listen_port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    async with websockets.serve(_pump, "127.0.0.1", listen_port) as server:
        port = server.sockets[0].getsockname()[1]
        print(f"PYTHON-RELAY-READY {port}", flush=True)
        await asyncio.Future()  # serve until killed


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        pass
