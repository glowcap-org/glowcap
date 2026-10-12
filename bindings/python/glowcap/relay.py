"""Native relay provider composition for the asyncio driver loop.

One ``RelayRuntime`` installs one archive-owned package advertising both
``keyed-relay`` and ``noise-relay``. The driver selects the profile and owns
all connection, listener, readiness, and session lifetime after registration.
"""

from __future__ import annotations

from dataclasses import dataclass
import ipaddress
import secrets
from typing import Never, Optional, TYPE_CHECKING
from urllib.parse import urlsplit

import ctypes

from . import _constants as _c
from ._errors import GlowcapError
from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _str_buf, _read_last_error
from ._ffi_relay import _RelayConfig, _relay_lib
from ._locator import Locator
from ._native import NativeHandle, _NativeHandleOwner
from ._transport import (
    Connector,
    Provider,
    _rollback_failed_provider,
    _rollback_failed_transport,
)

if TYPE_CHECKING:
    from ._host import Host
    from ._server import DriverServer

__all__ = [
    "RelayConfig",
    "RelayRuntime",
    "provider",
    "connector",
    "keyed",
    "noise",
]

_RENDEZVOUS_RELAY_HINT = "rendezvous-relay"
_RENDEZVOUS_QUERY = "rendezvous"
_REGISTER_QUERY = "id"
_MAX_RENDEZVOUS_RELAY_HINT_BYTES = _c.RELAY_MAX_RENDEZVOUS_RELAY_HINT_BYTES


def _invalid(message: str) -> Never:
    raise GlowcapError(_c.ERR_INVALID_ARGUMENT, message)


def _validate_designator(designator: str) -> None:
    if len(designator) != 64 or any(ch not in "0123456789abcdef" for ch in designator):
        _invalid("relay designator must be 64 lowercase hexadecimal characters")


def _decoded_query_name(field: str) -> str:
    name = field.partition("=")[0]
    out: list[str] = []
    at = 0
    while at < len(name):
        if name[at] != "%":
            out.append(name[at])
            at += 1
            continue
        out.append(chr(int(name[at + 1 : at + 3], 16)))
        at += 3
    return "".join(out)


def _relay_route(value: object) -> str:
    if not isinstance(value, str) or not value:
        _invalid("rendezvous-relay must be a non-empty string hint")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        _invalid("rendezvous-relay must contain visible ASCII URI bytes")
    if len(encoded) > _MAX_RENDEZVOUS_RELAY_HINT_BYTES:
        _invalid(
            f"rendezvous-relay exceeds {_MAX_RENDEZVOUS_RELAY_HINT_BYTES} UTF-8 bytes"
        )
    if any(byte < 0x21 or byte > 0x7E for byte in encoded):
        _invalid("rendezvous-relay must contain visible ASCII URI bytes")
    at = 0
    while at < len(value):
        if value[at] != "%":
            at += 1
            continue
        if (
            at + 2 >= len(value)
            or value[at + 1] not in "0123456789abcdefABCDEF"
            or value[at + 2] not in "0123456789abcdefABCDEF"
        ):
            _invalid("rendezvous-relay carries malformed percent encoding")
        at += 3
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
    except ValueError:
        _invalid("rendezvous-relay must be an absolute WebSocket URL")
    if parts.scheme not in ("ws", "wss") or host is None:
        _invalid("rendezvous-relay must use ws or wss")
    if parts.username is not None or parts.password is not None or parts.fragment:
        _invalid("rendezvous-relay cannot carry credentials or a fragment")
    if port == 0:
        _invalid("rendezvous-relay carries an invalid port")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        labels = host.split(".")
        if any(
            not label
            or len(label) > 63
            or not label[0].isalnum()
            or not label[-1].isalnum()
            or any(not (ch.isalnum() or ch == "-") for ch in label)
            for label in labels
        ):
            _invalid("rendezvous-relay carries an invalid host name")
    for field in parts.query.split("&") if parts.query else ():
        name = _decoded_query_name(field)
        if name in (_RENDEZVOUS_QUERY, _REGISTER_QUERY):
            _invalid(f"rendezvous-relay reserves the {name} query parameter")
    return value


class _Profile:
    __slots__ = ("_transport",)

    def __init__(self, transport: str) -> None:
        self._transport = transport

    def locator(self, designator: str, relay_url: str) -> Locator:
        """Build this relay profile's routed typed locator."""
        _validate_designator(designator)
        return Locator(
            self._transport,
            designator,
            {_RENDEZVOUS_RELAY_HINT: _relay_route(relay_url)},
            "map",
        )

    async def listen(
        self,
        relay_url: str,
        register_url: str,
        *,
        seed: "Optional[bytes]" = None,
        trust_pem: "Optional[bytes]" = None,
        host: "Optional[Host]" = None,
    ) -> "DriverServer":
        """Register this profile's durable key at the relay and accept sessions.

        The native relay provider holds the registration socket open and the
        driver owns admission, handshakes, and session lifetime. Iterate the
        returned server for each accepted :class:`glowcap.Session`. ``seed``
        is a 32-byte secret kept across restarts so the advertised locator
        survives them, or ``None`` for a fresh identity shared with the Host.
        Pass ``host`` instead of ``seed`` to share an existing Host identity
        and loop. The driver's provider registry holds one relay configuration
        per loop: a second listen naming the same ``relay_url`` and
        ``register_url`` rides the installed provider, and one naming different
        routes is refused.
        """
        from ._abi_value import _DEFAULT_CODEC
        from ._server import (
            DriverServer,
            prepare_driver_loop,
            _rollback_listener_construction,
        )

        if seed is not None and len(seed) != 32:
            raise GlowcapError(_c.ERR_INVALID_ARGUMENT, "listen: seed must be 32 bytes")
        if host is not None and seed is not None:
            raise GlowcapError(
                _c.ERR_INVALID_ARGUMENT,
                "listen: seed and host are alternative identity sources",
            )
        config = RelayConfig(relay_url, register_url, trust_pem)
        selected_seed = (
            seed
            if seed is not None
            else (host.seed if host is not None else secrets.token_bytes(32))
        )
        selected_codec = host.codec if host is not None else _DEFAULT_CODEC
        prepared = prepare_driver_loop(host, selected_codec, seed=selected_seed)
        loop = prepared.loop
        listener = None
        try:
            await provider(config).install(loop)
            listener = loop.listen(self._transport, "")
            loop.start()
            await loop.wait_listener(listener)
            loop.select_listener(listener)
            return DriverServer(loop, listener, retire_loop=prepared.owns_loop)
        except BaseException as error:
            _rollback_listener_construction(error, loop, listener, prepared.owns_loop)
            raise



keyed = _Profile(_c.TRANSPORT_KEYED_RELAY)
noise = _Profile(_c.TRANSPORT_NOISE_RELAY)


def _route_from_locator(locator) -> str | None:
    value = locator.hints.get(_RENDEZVOUS_RELAY_HINT)
    if value is None:
        return None
    return _relay_route(value)


def _dial_url(route: str, designator: str) -> str:
    _validate_designator(designator)
    admitted = _relay_route(route)
    return f"{admitted}{'&' if '?' in admitted else '?'}{_RENDEZVOUS_QUERY}={designator}"


def _relay_last_error() -> str | None:
    return _read_last_error(_relay_lib.glowcap_relay_last_error)


def _check_relay(code: int) -> None:
    if code != _c.OK:
        raise GlowcapError(code, _relay_last_error())


@dataclass(frozen=True, slots=True)
class RelayConfig:
    """The copied URLs and immutable trust used by one native relay runtime."""

    relay_url: str
    register_url: str = ""
    trust_pem: bytes | None = None
    # Redirect this exact advertised dial route to relay_url. Both must reach
    # the same registry. Other peer hints retain their routes.
    relay_alias_url: str = ""

    @classmethod
    def dial_only(cls, relay_url: str) -> "RelayConfig":
        return cls(relay_url)


def _release_runtime(raw) -> None:
    _check_relay(_relay_lib.glowcap_relay_runtime_release(raw, None, 0, None))


class RelayRuntime(_NativeHandleOwner):
    """Owns the relay archive runtime until its provider is installed."""

    def __init__(self, config: RelayConfig):
        relay_buf, relay_len = _str_buf(config.relay_url)
        register_buf, register_len = _str_buf(config.register_url)
        alias_buf, alias_len = _str_buf(config.relay_alias_url)
        trust_pem = config.trust_pem
        trust_buf = (
            ctypes.create_string_buffer(trust_pem, len(trust_pem))
            if trust_pem
            else None
        )
        c_config = _RelayConfig(
            _c.RELAY_CONFIG_ABI_VERSION,
            ctypes.sizeof(_RelayConfig),
            ctypes.cast(relay_buf, ctypes.c_void_p),
            relay_len,
            ctypes.cast(register_buf, ctypes.c_void_p),
            register_len,
            _c.RELAY_TRUST_SYSTEM if trust_pem is None else _c.RELAY_TRUST_COPIED_PEM,
            ctypes.cast(trust_buf, ctypes.c_void_p) if trust_buf else None,
            len(trust_pem) if trust_pem else 0,
            ctypes.cast(alias_buf, ctypes.c_void_p),
            alias_len,
        )
        out = ctypes.c_void_p()
        _check_relay(
            _relay_lib.glowcap_relay_runtime_new(
                ctypes.byref(c_config), ctypes.byref(out)
            )
        )
        self._native = NativeHandle(out, _release_runtime, label="relay runtime")

    def release(self) -> None:
        self._native.close()

    def _transport_provider(self) -> _TransportProvider:
        package = _TransportProvider()
        with self._native.lease() as raw:
            _check_relay(
                _relay_lib.glowcap_relay_transport_provider(raw, ctypes.byref(package))
            )
        return package

    def _relinquish_provider_reference(self) -> None:
        self._native.drop_reference()


def provider(config: RelayConfig | str, register_url: str = "") -> Provider:
    """Build the configured native keyed-relay/noise-relay package."""
    if isinstance(config, str):
        config = RelayConfig(config, register_url)

    async def install(loop) -> None:
        runtime = RelayRuntime(config)
        try:
            loop._install_provider(
                lambda register: register(runtime._transport_provider())
            )
        except BaseException as primary:
            _rollback_failed_provider(primary, runtime.release)
            raise
        runtime._relinquish_provider_reference()

    return Provider(install)


def connector(config: RelayConfig | str) -> Connector:
    """Build the byte-fed connector for either relay security profile.

    The WebSocket remains a byte channel.  For ``noise-relay`` the shared Host
    applies end-to-end sealing after the channel is established.
    """
    if isinstance(config, str):
        config = RelayConfig(config)
    if config.relay_alias_url:
        raise GlowcapError(
            _c.ERR_INVALID_ARGUMENT,
            "relay aliases require the native relay provider",
        )

    async def realize(host, locator, handshake_timeout_ms):
        route = _route_from_locator(locator) or config.relay_url
        if not route:
            raise GlowcapError(
                _c.ERR_INVALID_ARGUMENT,
                "relay connector requires a rendezvous route in the locator or config",
            )
        from ._session import Session
        from ._ws import connect_websocket

        channel = await connect_websocket(_dial_url(route, locator.designator))
        try:
            return await Session.establish_dialed_locator(
                host,
                locator,
                channel,
                handshake_timeout_ms,
            )
        except BaseException as primary:
            await _rollback_failed_transport(primary, channel)
            raise

    return Connector(
        (_c.TRANSPORT_KEYED_RELAY, _c.TRANSPORT_NOISE_RELAY),
        realize,
    )
