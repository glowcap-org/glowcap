"""Native relay provider composition for the asyncio driver loop.

One ``RelayRuntime`` installs one archive-owned package advertising both
``keyed-relay`` and ``noise-relay``. The driver selects the profile and owns
all connection, listener, readiness, and session lifetime after registration.
"""

from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import ctypes

from . import _constants as _c
from ._errors import PancakeError
from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _str_buf, _read_last_error
from ._ffi_relay import _RelayConfig, _relay_lib
from ._native import NativeHandle

__all__ = ["RelayConfig", "RelayRuntime", "install_provider"]

_RENDEZVOUS_RELAY_HINT = "rendezvous-relay"


def _route_from_locator(locator) -> str | None:
    value = locator.hints.get(_RENDEZVOUS_RELAY_HINT)
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise PancakeError(
            _c.ERR_INVALID_ARGUMENT,
            "rendezvous-relay must be a non-empty string hint",
        )
    return value


def _dial_url(route: str, designator: str) -> str:
    parts = urlsplit(route)
    query = parse_qsl(parts.query, keep_blank_values=True)
    query.append(("rendezvous", designator))
    return urlunsplit(
        (parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)
    )


def _relay_last_error() -> str | None:
    return _read_last_error(_relay_lib.pancake_relay_last_error)


def _check_relay(code: int) -> None:
    if code != _c.OK:
        raise PancakeError(code, _relay_last_error())


@dataclass(frozen=True, slots=True)
class RelayConfig:
    """The copied URLs used by one native relay provider runtime."""

    relay_url: str
    register_url: str = ""

    @classmethod
    def dial_only(cls, relay_url: str) -> "RelayConfig":
        return cls(relay_url)


def _release_runtime(raw) -> None:
    _relay_lib.pancake_relay_runtime_release(raw)


class RelayRuntime:
    """Owns the relay archive runtime until its provider is installed."""

    def __init__(self, config: RelayConfig):
        relay_buf, relay_len = _str_buf(config.relay_url)
        register_buf, register_len = _str_buf(config.register_url)
        c_config = _RelayConfig(
            ctypes.cast(relay_buf, ctypes.c_void_p),
            relay_len,
            ctypes.cast(register_buf, ctypes.c_void_p),
            register_len,
        )
        out = ctypes.c_void_p()
        _check_relay(
            _relay_lib.pancake_relay_runtime_new(
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
                _relay_lib.pancake_relay_transport_provider(raw, ctypes.byref(package))
            )
        return package

    def _relinquish_provider_reference(self) -> None:
        self._native.drop_reference()


def install_provider(loop, config: RelayConfig | str, register_url: str = "") -> None:
    """Install one shared keyed-relay/noise-relay package into ``loop``.

    ``register_url`` is used only for listeners. Passing a string is a compact
    dial-only form; use :class:`RelayConfig` when hosting too.
    """
    if loop._has_transport(_c.TRANSPORT_KEYED_RELAY.encode()):
        return
    if isinstance(config, str):
        config = RelayConfig(config, register_url)
    runtime = RelayRuntime(config)
    try:
        loop._install_provider(
            lambda register: register(runtime._transport_provider())
        )
    except BaseException:
        runtime.release()
        raise
    runtime._relinquish_provider_reference()
