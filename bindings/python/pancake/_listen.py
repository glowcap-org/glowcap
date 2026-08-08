"""The listen / accept surface (binding spine Pass 3d): :class:`Server`,
:class:`KeyedTcpServer`, and the top-level :func:`listen` /
:func:`listen_keyed_tcp` hosters. Session owns mint/handshake
(``establish_accepted``); this module owns the listening socket, accept loop,
and self-designator bind. iroh hosting lives in :mod:`pancake.iroh`, not here.
"""

from __future__ import annotations

import asyncio
from typing import Optional, TYPE_CHECKING

from . import _constants as _abi
from ._dial import _StreamTransport
from ._errors import PancakeError
from ._host import Host
from ._locator import encode_peer_locator, keyed_tcp_locator, socket_addr_designator

if TYPE_CHECKING:
    from ._session import Session

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


async def _accept(reader, writer, host: Host) -> "Session":
    """Wrap an accepted stream and complete the keyed handshake from the
    responder side. Resolves once the session is open."""
    from ._session import Session

    sock = writer.get_extra_info("sockname")
    transport = _StreamTransport(reader, writer)
    try:
        return await Session.establish_accepted(
            host, _abi.TRANSPORT_TCP, "", transport, socket_addr_designator(sock),
        )
    except BaseException:
        transport.close()
        raise


class Server:
    """A listening server, one object an app holds. Async-iterable (``async
    for conn in server``), and ``.port`` surfaces the bound port so binding an
    ephemeral port (``port=0``) and telling a partner where to connect works
    the same as the other bindings."""

    def __init__(self, server: "asyncio.Server", queue: "asyncio.Queue", host: Host):
        self._server = server
        self._queue = queue
        self._host = host

    @property
    def port(self) -> int:
        """The kernel-chosen bound port (read it back after binding ``port=0``)."""
        return self._server.sockets[0].getsockname()[1]

    @property
    def host(self) -> Host:
        """The server's shared Host: one retained identity and handoff router
        across every accepted session. Pass it to :func:`connect` so a
        fetched capability and the recipient session share one Host, the
        gifter side of a three-party handoff.
        Publish a host-giftable on it with :meth:`Host.publish_giftable`."""
        return self._host

    def close(self) -> None:
        """Stop accepting new partners. This closes the listening socket only;
        sessions already accepted are unaffected."""
        self._server.close()

    async def __aenter__(self) -> "Server":
        return self

    async def __aexit__(self, *exc) -> None:
        self.close()

    def __aiter__(self) -> "Server":
        return self

    async def __anext__(self) -> "Session":
        # A partner that fails its handshake — a rude probe that connects and
        # hangs up — is that connection's failure, never the listener's: skip
        # it and keep accepting, so one port scan cannot take a long-lived
        # server down. (`_accept` already closed the transport.)
        while True:
            reader, writer = await self._queue.get()
            try:
                return await _accept(reader, writer, self._host)
            except (PancakeError, OSError):
                # PancakeError: the handshake failed (EOF mid-handshake), or a
                # partner that connected and said nothing overran
                # `HANDSHAKE_TIMEOUT_MS` — the silent case nothing else catches.
                # OSError: the probe reset the socket under the teardown.
                continue


class KeyedTcpServer:
    """A keyed-tcp listening server: TCP sockets under a durable key designator
    (ADR-0075). The Host's Ed25519 identity *is* the locator designator and the
    session signing key — one seed, not a second minted identity. Build one
    with :func:`listen_keyed_tcp`."""

    def __init__(self, server: "asyncio.Server", queue: "asyncio.Queue",
                 host: Host, designator: str):
        self._server = server
        self._queue = queue
        self._host = host
        self._designator = designator

    @property
    def port(self) -> int:
        """The kernel-chosen bound port (read it back after binding ``port=0``)."""
        return self._server.sockets[0].getsockname()[1]

    @property
    def host(self) -> Host:
        """This server's Host — one retained identity and session directory. The
        identity seed is the keyed-tcp designator."""
        return self._host

    @property
    def designator(self) -> str:
        """The key designator this server signs (64 lowercase hex digits)."""
        return self._designator

    def uri(self) -> str:
        """The ``ocapn://<key>.keyed-tcp?direct-addresses=<bound>`` URI a partner dials."""
        sock = self._server.sockets[0].getsockname()
        return keyed_tcp_locator(self._designator, sock[0], sock[1])

    def close(self) -> None:
        """Stop accepting new partners."""
        self._server.close()

    async def __aenter__(self) -> "KeyedTcpServer":
        return self

    async def __aexit__(self, *exc) -> None:
        self.close()

    def __aiter__(self) -> "KeyedTcpServer":
        return self

    async def __anext__(self) -> "Session":
        from ._session import Session

        while True:
            reader, writer = await self._queue.get()
            try:
                sock = writer.get_extra_info("sockname")
                hint = socket_addr_designator(sock)
                transport = _StreamTransport(reader, writer)
                try:
                    return await Session.establish_accepted(
                        self._host, _abi.TRANSPORT_KEYED_TCP, self._designator, transport, hint,
                    )
                except BaseException:
                    transport.close()
                    raise
            except (PancakeError, OSError):
                # Same isolation as `Server.__anext__`: a failed, reset, or
                # silent partner (one that overran `HANDSHAKE_TIMEOUT_MS`) is
                # that connection's failure, never the listener's.
                continue


async def listen_keyed_tcp(bind_host: str, port: int = 0, seed: Optional[bytes] = None,
                           codec: Optional[str] = None) -> KeyedTcpServer:
    """Bind a keyed-tcp listener whose designator is the public half of
    ``seed`` (or a fresh random seed when omitted). The Host identity, the
    locator designator, and the session signing key are one value — pass the
    same seed after a restart to keep the designator stable (ADR-0075)."""
    if seed is not None and len(seed) != 32:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "listen_keyed_tcp: seed must be 32 bytes")
    host = Host(seed=seed, codec=codec if codec is not None else "syrup")
    designator = host.designator()
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), bind_host, port,
    )
    host.set_self_designator(designator)
    bound = socket_addr_designator(server.sockets[0].getsockname())
    host.set_advertised_locator(encode_peer_locator(
        _abi.TRANSPORT_KEYED_TCP, designator, bound,
    ))
    return KeyedTcpServer(server, queue, host, designator)


async def listen(bind_host: str, port: int = 0, host: Optional[Host] = None,
                 codec: Optional[str] = None) -> Server:
    """Bind a listening :class:`Server`. ``async for conn in await listen(bind_host,
    0)`` accepts each partner; ``server.port`` reads the bound ephemeral port.
    Each yielded :class:`Session` is one accepted partner: publish
    capabilities on it and call :meth:`Session.serve`. ``codec`` picks the
    wire grammar for a server built on a fresh Host; a supplied ``host``
    already carries one, and a conflicting explicit codec is refused rather
    than silently ignored."""
    if host is not None and codec is not None and codec != host.codec:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'codec "{codec}" conflicts with the host\'s "{host.codec}"; mint the host with it instead',
        )
    host = host if host is not None else Host(
        codec=codec if codec is not None else "syrup"
    )
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), bind_host, port,
    )
    # This Host also dials (the gifter side of a handoff), and its dials sign
    # the listener's own address so a partner's crossed-hellos table can
    # recognize it.
    designator = socket_addr_designator(server.sockets[0].getsockname())
    host.set_self_designator(designator)
    host.set_advertised_locator(encode_peer_locator(_abi.TRANSPORT_TCP, designator))
    return Server(server, queue, host)
