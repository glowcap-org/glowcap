#!/usr/bin/env python3
"""A byte-transparent relay in Python: the second-runtime reference for the
ADR-0086 relay contract, proving the contract is language-neutral and not a
TypeScript shape with a doc wrapper.

It carries the raw bytes of a keyed CapTP session between a browser peer's
WebSocket and a native host, without parsing them, so the keyed handshake and
session authority run end to end and the relay holds no capability. This is the
same five-part shape ADR-0086 names, in Python: the WebSocket adapter is
`websockets`, the pump is `_pump`, the byte channel is a `_TcpChannel` or the
iroh binding's relay transport, the dial dispatcher is `_open_channel`, and the
config comes from generated binding policy. The embedding app would add the
target allow-list. This proof relays wherever the conformance test points it.

Two transports, dispatched by what the WebSocket names:
  - `?to=host:port`  a raw TCP socket (byte-level, kernel-backpressured, no
                     glowcap binding needed).
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

from glowcap import _constants_gen as _abi

# The bounded resource defaults come from generated binding policy. The
# conformance idle-timeout proof sets GLOWCAP_RELAY_IDLE_MS low; a production run
# leaves it unset.
IDLE_TIMEOUT_S = (
    float(
        os.environ.get(
            "GLOWCAP_RELAY_IDLE_MS",
            str(_abi.BINDING_RELAY_IDLE_TIMEOUT_MS),
        )
    )
    / 1000.0
)
MAX_BYTES_PER_SESSION = _abi.BINDING_RELAY_MAX_BYTES_PER_SESSION
READ_CHUNK = _abi.BINDING_RELAY_READ_CHUNK_BYTES
CLOSE_TIMEOUT_S = _abi.BINDING_WEBSOCKET_CLOSE_TIMEOUT_MS / 1000.0


def _retain(primary: BaseException | None, error: BaseException) -> BaseException:
    if primary is None:
        return error
    # Keep the reference relay's TCP-only startup dependency-light; the binding
    # helper loads only when a second failure needs attachment.
    from glowcap._errors import _retain_cleanup_failure

    return _retain_cleanup_failure(primary, error)


class _TcpChannel:
    """A raw TCP byte channel over an asyncio stream: read/write/close, the same
    shape the iroh relay transport exposes so the pump is transport-agnostic."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self._reader = reader
        self._writer = writer
        self._close_requested = False

    async def read(self):
        chunk = await self._reader.read(READ_CHUNK)
        return chunk if chunk else None

    async def write(self, data: bytes) -> None:
        self._writer.write(data)
        await self._writer.drain()  # TCP-leg backpressure

    def close(self) -> None:
        if self._close_requested:
            return
        self._close_requested = True
        self._writer.close()

    async def wait_closed(self) -> None:
        if not self._close_requested:
            self.close()
        await self._writer.wait_closed()


async def _close_channel(channel) -> None:
    """Request one channel close and join its optional managed barrier."""
    primary = None
    try:
        result = channel.close()
        if result is not None:
            await result
    except BaseException as error:
        primary = error
    wait_closed = getattr(channel, "wait_closed", None)
    if wait_closed is not None:
        try:
            await asyncio.wait_for(wait_closed(), CLOSE_TIMEOUT_S)
        except BaseException as error:
            primary = _retain(primary, error)
    if primary is not None:
        raise primary


async def _close_pair(channel, websocket) -> tuple[BaseException, ...]:
    outcomes = await asyncio.gather(
        _close_channel(channel),
        asyncio.wait_for(websocket.close(), CLOSE_TIMEOUT_S),
        return_exceptions=True,
    )
    return tuple(outcome for outcome in outcomes if isinstance(outcome, BaseException))


async def _open_channel(target_to, target_locator):
    """Dial classifier: a `host:port` opens a raw socket, an iroh `ocapn://`
    locator opens the iroh relay channel. One of the two must be present."""
    if target_locator is not None:
        from glowcap.iroh import Reachability, dial_locator_for_relay

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
    target_to_values = query.get("to")
    target_locator_values = query.get("locator")
    target_to = target_to_values[0] if target_to_values else None
    target_locator = target_locator_values[0] if target_locator_values else None
    if target_locator is None and (not target_to or ":" not in target_to):
        await asyncio.wait_for(
            websocket.close(1008, "relay requires ?to=host:port or ?locator=<uri>"),
            CLOSE_TIMEOUT_S,
        )
        return

    try:
        channel = await _open_channel(target_to, target_locator)
    except BaseException as error:
        print(
            f"relay: dial failed: {type(error).__name__}: {error}",
            file=sys.stderr,
            flush=True,
        )
        # 1011 tells the browser the relay leg failed, not the session.
        try:
            await asyncio.wait_for(
                websocket.close(1011, "relay dial failed"), CLOSE_TIMEOUT_S
            )
        except BaseException as cleanup:
            _retain(error, cleanup)
        raise error

    transferred = 0
    loop = asyncio.get_running_loop()
    last_activity = loop.time()

    def touch() -> None:
        # Any chunk in either direction re-arms the idle timeout.
        nonlocal last_activity
        last_activity = loop.time()

    async def ws_to_channel() -> None:
        nonlocal transferred
        async for message in websocket:
            if isinstance(message, str):
                raise TypeError("WebSocket sent text to the byte relay")
            touch()
            transferred += len(message)
            if transferred > MAX_BYTES_PER_SESSION:
                return
            await channel.write(message)

    async def channel_to_ws() -> None:
        nonlocal transferred
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
    primary: BaseException | None = None
    try:
        done, _ = await asyncio.wait(set(legs), return_when=asyncio.FIRST_COMPLETED)
        # A scheduler may make more than one outcome observable before the wait
        # resumes. Preserve that observation in stable leg order.
        for leg in legs:
            if leg not in done:
                continue
            try:
                leg.result()
            except BaseException as error:
                primary = _retain(primary, error)
    except BaseException as error:
        primary = _retain(primary, error)
    finally:
        for consequence in await _close_pair(channel, websocket):
            primary = _retain(primary, consequence)
        for leg in legs:
            if not leg.done():
                leg.cancel()
        await asyncio.gather(*legs, return_exceptions=True)
    if primary is not None:
        raise primary


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
