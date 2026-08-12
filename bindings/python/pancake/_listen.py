"""Native listener surfaces for TCP, keyed-TCP, and noise-TCP.

The driver owns sockets, admission, handshakes, events, and session release.
The binding only chooses the provider locator and exposes the driver's accepted
sessions. A supplied :class:`Host` is transferred into that same driver, so its
identity and authority remain the object the caller supplied.
"""

from __future__ import annotations

import asyncio
import ipaddress
import secrets
from typing import Optional, TYPE_CHECKING

from . import _constants as _abi
from ._errors import PancakeError
from ._host import Host
from ._locator import Locator, designator_host_port, format_peer_uri, socket_addr_designator

if TYPE_CHECKING:
    from ._loop import DriverLoop
    from ._session import Session

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


def _wildcard(host: str) -> bool:
    bare = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    try:
        return ipaddress.ip_address(bare).is_unspecified
    except ValueError:
        return False


def _advertise_loop_listener(
    loop: "DriverLoop", listener: int, parsed: Locator, advertised_host: Optional[str], who: str
) -> tuple[str, str]:
    direct = parsed.hints.get(_abi.HINT_DIRECT_ADDRESSES, parsed.designator)
    if not isinstance(direct, str):
        raise PancakeError(_ERR_INVALID_ARGUMENT, f"{who} listener has a non-string address")
    if ":" not in direct:
        raise PancakeError(_ERR_INVALID_ARGUMENT, f"{who} listener has no address")
    bound_host, bound_port = designator_host_port(direct)
    if _wildcard(bound_host) and advertised_host is None:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            "a wildcard bind has no dialable address; provide advertised_host",
        )
    if advertised_host is None:
        advertised = direct
    else:
        bare = (
            advertised_host[1:-1]
            if advertised_host.startswith("[") and advertised_host.endswith("]")
            else advertised_host
        )
        advertised = socket_addr_designator((bare, bound_port))
    if advertised != direct or parsed.transport == _abi.TRANSPORT_TCP:
        advertised_locator = Locator(
            parsed.transport,
            advertised if parsed.transport == _abi.TRANSPORT_TCP else parsed.designator,
            {} if parsed.transport == _abi.TRANSPORT_TCP else {_abi.HINT_DIRECT_ADDRESSES: advertised},
        )
        loop.advertise_listener(listener, advertised_locator)
    loop.select_listener(listener)
    return parsed.designator, advertised


class Server:
    """A driver-owned TCP listener and its accepted sessions."""

    def __init__(
        self,
        driver_loop: "DriverLoop",
        listener,
        designator: str,
        *,
        owns_loop: bool,
    ):
        self._driver_loop = driver_loop
        self._listener = listener
        self._designator = designator
        self._owns_loop = owns_loop
        self._closed = False

    @property
    def port(self) -> int:
        return int(self._designator.rsplit(":", 1)[1])

    @property
    def host(self) -> Host:
        return self._driver_loop.wrapper_host()

    def close(self) -> "list[asyncio.Task]":
        if self._closed:
            return []
        self._closed = True
        self._listener.close()
        if self._owns_loop:
            self._driver_loop.request_close()
        return []

    async def close_async(self) -> None:
        self.close()
        if self._owns_loop:
            await self._driver_loop.wait_closed()

    def __aiter__(self) -> "Server":
        return self

    async def __anext__(self) -> "Session":
        try:
            return await self._driver_loop.accept_session(self._listener)
        except PancakeError as err:
            if err.code == _abi.ERR_CLOSED:
                raise StopAsyncIteration from None
            raise

    async def __aenter__(self) -> "Server":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close_async()


class KeyedTcpServer(Server):
    """A driver-owned keyed-TCP listener."""

    def __init__(
        self,
        driver_loop: "DriverLoop",
        listener: int,
        designator: str,
        direct_address: str,
        *,
        owns_loop: bool,
    ):
        super().__init__(
            driver_loop,
            listener,
            direct_address,
            owns_loop=owns_loop,
        )
        self._key_designator = designator
        self._direct_address = direct_address

    @property
    def designator(self) -> str:
        return self._key_designator

    def uri(self) -> str:
        host, port = designator_host_port(self._direct_address)
        from ._locator import keyed_tcp_locator

        return keyed_tcp_locator(self._key_designator, host, port)


class NoiseTcpServer(Server):
    """A driver-owned noise-TCP listener."""

    def __init__(
        self,
        driver_loop: "DriverLoop",
        listener: int,
        designator: str,
        direct_address: str,
        *,
        owns_loop: bool,
    ):
        super().__init__(
            driver_loop,
            listener,
            direct_address,
            owns_loop=owns_loop,
        )
        self._key_designator = designator
        self._direct_address = direct_address

    @property
    def designator(self) -> str:
        return self._key_designator

    def uri(self) -> str:
        host, port = designator_host_port(self._direct_address)
        from ._locator import noise_tcp_locator

        return noise_tcp_locator(self._key_designator, host, port)


def _loop_for_host(
    host: Optional[Host], codec: str, *, seed: Optional[bytes] = None
) -> "tuple[DriverLoop, bool]":
    from ._loop import DriverLoop

    if host is not None:
        if codec != host.codec:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                f'codec "{codec}" conflicts with the host\'s "{host.codec}"',
            )
        if getattr(host, "_loop_mode", False):
            return host._driver_loop, False
        return DriverLoop.take_host(host), True
    if seed is None:
        return DriverLoop.open(codec=codec, handshake_ms=_abi.HANDSHAKE_TIMEOUT_MS), True
    return DriverLoop.open(
        seed=seed + secrets.token_bytes(32),
        codec=codec,
        handshake_ms=_abi.HANDSHAKE_TIMEOUT_MS,
    ), True


async def _listen_tcp(
    bind_host: str,
    port: int,
    host: Optional[Host],
    codec: Optional[str],
    advertised_host: Optional[str],
) -> Server:
    selected_codec = codec if codec is not None else (host.codec if host else "syrup")
    loop, owns_loop = _loop_for_host(host, selected_codec)
    listener = None
    try:
        from .tcp import install_provider

        install_provider(loop)
        listener = loop.listen(_abi.TRANSPORT_TCP, f"{bind_host}:{port}")
        designator = loop.listener_locator(listener).designator
        bound_host, bound_port = designator_host_port(designator)
        if _wildcard(bound_host) and advertised_host is None:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "a wildcard bind has no dialable address; provide advertised_host",
            )
        public = designator
        if advertised_host is not None:
            bare = (
                advertised_host[1:-1]
                if advertised_host.startswith("[") and advertised_host.endswith("]")
                else advertised_host
            )
            public = socket_addr_designator((bare, bound_port))
            loop.advertise_listener(
                listener, format_peer_uri(_abi.TRANSPORT_TCP, public)
            )
        loop.select_listener(listener)
        if owns_loop:
            await loop.start()
        return Server(loop, listener, public, owns_loop=host is None)
    except BaseException:
        if listener is not None:
            listener.close()
        if owns_loop:
            loop.close()
        raise


async def listen(
    bind_host: str,
    port: int = 0,
    host: Optional[Host] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
) -> Server:
    """Bind a driver-owned TCP listener, optionally adopting ``host``."""
    return await _listen_tcp(bind_host, port, host, codec, advertised_host)


async def listen_keyed_tcp(
    bind_host: str,
    port: int = 0,
    seed: Optional[bytes] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
    host: Optional[Host] = None,
) -> KeyedTcpServer:
    """Bind a driver-owned keyed-TCP listener, optionally adopting ``host``."""
    if seed is not None and len(seed) != 32:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "listen_keyed_tcp: seed must be 32 bytes")
    if host is not None and seed is not None and host.seed != seed:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "seed conflicts with supplied host")
    durable = host.seed if host is not None else (seed or secrets.token_bytes(32))
    selected_codec = codec if codec is not None else (host.codec if host else "syrup")
    loop, owns_loop = _loop_for_host(host, selected_codec, seed=durable)
    listener = None
    try:
        from .tcp import install_provider

        install_provider(loop)
        listener = loop.listen(_abi.TRANSPORT_KEYED_TCP, f"{bind_host}:{port}")
        designator, direct = _advertise_loop_listener(
            loop,
            listener,
            loop.listener_locator(listener),
            advertised_host,
            _abi.TRANSPORT_KEYED_TCP,
        )
        if owns_loop:
            await loop.start()
        return KeyedTcpServer(
            loop,
            listener,
            designator,
            direct,
            owns_loop=host is None,
        )
    except BaseException:
        if listener is not None:
            listener.close()
        if owns_loop:
            loop.close()
        raise


async def listen_noise_tcp(
    bind_host: str,
    port: int = 0,
    *,
    seed: Optional[bytes] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
    host: Optional[Host] = None,
) -> NoiseTcpServer:
    """Bind a driver-owned noise-TCP listener, optionally adopting ``host``."""
    if seed is not None and len(seed) != 32:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "listen_noise_tcp: seed must be 32 bytes")
    if host is not None and seed is not None and host.seed != seed:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "seed conflicts with supplied host")
    durable = host.seed if host is not None else (seed or secrets.token_bytes(32))
    selected_codec = codec if codec is not None else (host.codec if host else "syrup")
    loop, owns_loop = _loop_for_host(host, selected_codec, seed=durable)
    listener = None
    try:
        from .tcp import install_provider

        install_provider(loop)
        listener = loop.listen(_abi.TRANSPORT_NOISE_TCP, f"{bind_host}:{port}")
        designator, direct = _advertise_loop_listener(
            loop,
            listener,
            loop.listener_locator(listener),
            advertised_host,
            _abi.TRANSPORT_NOISE_TCP,
        )
        if owns_loop:
            await loop.start()
        return NoiseTcpServer(
            loop,
            listener,
            designator,
            direct,
            owns_loop=host is None,
        )
    except BaseException:
        if listener is not None:
            listener.close()
        if owns_loop:
            loop.close()
        raise
