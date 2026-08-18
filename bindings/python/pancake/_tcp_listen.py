"""One native listener surface across the TCP provider's profiles.

The driver owns sockets, admission, handshakes, events, session release, and
canonical locator metadata. A supplied :class:`Host` is transferred into that
same driver, preserving the caller's identity and authority.
"""

from __future__ import annotations

import ipaddress
import secrets
from typing import Optional, TYPE_CHECKING

from . import _constants as _abi
from ._errors import PancakeError
from ._host import Host
from ._locator import Locator, designator_host_port
from ._socket_address import address_designator
from ._server import DriverServer, prepare_driver_loop, _rollback_listener_construction

if TYPE_CHECKING:
    from ._listener import ListenerOwner
    from ._loop import DriverLoop
    from .tcp import Config

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_IDENTITY_PROFILES = {_abi.TRANSPORT_KEYED_TCP, _abi.TRANSPORT_NOISE_TCP}


def _wildcard(host: str) -> bool:
    bare = host[1:-1] if host.startswith("[") and host.endswith("]") else host
    try:
        return ipaddress.ip_address(bare).is_unspecified
    except ValueError:
        return False


def _direct_address(locator: Locator, who: str) -> str:
    direct = locator.hints.get(_abi.HINT_DIRECT_ADDRESSES, locator.designator)
    if not isinstance(direct, str):
        raise PancakeError(
            _ERR_INVALID_ARGUMENT, f"{who} listener has a non-string address"
        )
    return direct


def _advertise_loop_listener(
    loop: "DriverLoop",
    listener: "ListenerOwner",
    locator: Locator,
    advertised_host: Optional[str],
    who: str,
) -> None:
    direct = _direct_address(locator, who)
    bound_host, bound_port = designator_host_port(direct)
    if _wildcard(bound_host) and advertised_host is None:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            "a wildcard bind has no dialable address; provide advertised_host",
        )
    if advertised_host is not None and _wildcard(advertised_host):
        raise PancakeError(
            _ERR_INVALID_ARGUMENT, "an advertised host must be dialable"
        )
    if advertised_host is None:
        advertised = direct
    else:
        bare = (
            advertised_host[1:-1]
            if advertised_host.startswith("[") and advertised_host.endswith("]")
            else advertised_host
        )
        advertised = address_designator(bare, bound_port)
    if advertised != direct:
        loop.advertise_listener(
            listener,
            Locator(
                locator.transport,
                advertised
                if locator.transport == _abi.TRANSPORT_TCP
                else locator.designator,
                {}
                if locator.transport == _abi.TRANSPORT_TCP
                else {_abi.HINT_DIRECT_ADDRESSES: advertised},
            ),
        )
    loop.select_listener(listener)


class Server(DriverServer):
    """A driver-owned TCP-provider listener and its accepted sessions."""

    @property
    def port(self) -> int:
        _host, port = designator_host_port(_direct_address(self.locator, "server"))
        return port


async def _listen_tcp_profile(
    transport: str,
    bind_host: str,
    port: int,
    seed: Optional[bytes],
    codec: Optional[str],
    advertised_host: Optional[str],
    host: Optional[Host],
    config: "Optional[Config]",
) -> Server:
    who = f"listen_{transport.replace('-', '_')}"
    if seed is not None and len(seed) != 32:
        raise PancakeError(_ERR_INVALID_ARGUMENT, f"{who}: seed must be 32 bytes")
    if host is not None and seed is not None and host.seed != seed:
        raise PancakeError(_ERR_INVALID_ARGUMENT, "seed conflicts with supplied host")
    durable = None
    if transport in _IDENTITY_PROFILES:
        durable = host.seed if host is not None else (seed or secrets.token_bytes(32))
    selected_codec = codec if codec is not None else (host.codec if host else "syrup")
    prepared = prepare_driver_loop(host, selected_codec, seed=durable)
    loop = prepared.loop
    listener = None
    try:
        from .tcp import Config, provider

        await provider(config or Config()).install(loop)
        listener = loop.listen(transport, f"{bind_host}:{port}")
        loop.start()
        await loop.wait_listener(listener)
        _advertise_loop_listener(
            loop,
            listener,
            loop.listener_locator(listener),
            advertised_host,
            who,
        )
        return Server(loop, listener, retire_loop=prepared.owns_loop)
    except BaseException as error:
        _rollback_listener_construction(error, loop, listener, prepared.owns_loop)
        raise


async def listen(
    bind_host: str,
    port: int = 0,
    *,
    host: Optional[Host] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
    config: "Optional[Config]" = None,
) -> Server:
    """Bind a driver-owned TCP listener, optionally adopting ``host``."""
    return await _listen_tcp_profile(
        _abi.TRANSPORT_TCP,
        bind_host,
        port,
        None,
        codec,
        advertised_host,
        host,
        config,
    )


async def listen_keyed(
    bind_host: str,
    port: int = 0,
    *,
    seed: Optional[bytes] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
    host: Optional[Host] = None,
    config: "Optional[Config]" = None,
) -> Server:
    """Bind a driver-owned keyed-TCP listener, optionally adopting ``host``."""
    return await _listen_tcp_profile(
        _abi.TRANSPORT_KEYED_TCP,
        bind_host,
        port,
        seed,
        codec,
        advertised_host,
        host,
        config,
    )


async def listen_noise(
    bind_host: str,
    port: int = 0,
    *,
    seed: Optional[bytes] = None,
    codec: Optional[str] = None,
    advertised_host: Optional[str] = None,
    host: Optional[Host] = None,
    config: "Optional[Config]" = None,
) -> Server:
    """Bind a driver-owned noise-TCP listener, optionally adopting ``host``."""
    return await _listen_tcp_profile(
        _abi.TRANSPORT_NOISE_TCP,
        bind_host,
        port,
        seed,
        codec,
        advertised_host,
        host,
        config,
    )
