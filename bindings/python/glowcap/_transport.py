"""Generic transport composition values.

The binding core knows only these two seams. Transport modules construct
providers for the FFI driver or connectors for an embedder-owned byte
channel. This module never names a concrete transport.
"""

from __future__ import annotations

import inspect
from dataclasses import dataclass
from typing import TYPE_CHECKING, Awaitable, Callable, Optional

from ._errors import _retain_cleanup_failure
from ._failure import FailureLayer, _record_runtime_failure

if TYPE_CHECKING:
    from ._host import Host
    from ._locator import Locator
    from ._loop import DriverLoop
    from ._session import Session


def _record_transport_cleanup_failure(source: str, error: BaseException) -> None:
    _record_runtime_failure(FailureLayer.TRANSPORT, source, error)


async def _await_maybe(value):
    if inspect.isawaitable(value):
        return await value
    return value


async def _rollback_failed_transport(primary: BaseException, transport) -> None:
    """Join connector rollback and attach it to the failed establishment."""
    try:
        transport.close()
        wait_closed = getattr(transport, "wait_closed", None)
        if wait_closed is not None:
            await _await_maybe(wait_closed())
    except BaseException as cleanup_error:
        _retain_cleanup_failure(primary, cleanup_error)


def _rollback_failed_provider(
    primary: BaseException, cleanup: Callable[[], None]
) -> None:
    """Retire rejected provider state and attach any cleanup consequence."""
    try:
        cleanup()
    except BaseException as cleanup_error:
        _retain_cleanup_failure(primary, cleanup_error)


@dataclass(frozen=True, slots=True)
class Provider:
    """One explicitly composed FFI provider package.

    ``installer`` owns archive loading, configuration, registration, and
    resident lifetime. The driver registry is the sole transport-symbol
    authority.
    """

    installer: Callable[["DriverLoop"], Awaitable[object] | object]

    def __post_init__(self) -> None:
        if not callable(self.installer):
            raise TypeError("provider installer must be callable")

    async def install(self, loop: "DriverLoop"):
        """Install this configured package exactly once on ``loop``."""
        return await _await_maybe(self.installer(loop))


@dataclass(frozen=True, slots=True)
class Connector:
    """One explicit byte-fed transport realization.

    The callback is transport-owned and receives the shared Host, the complete
    locator, and the handshake budget. It returns an established Session. The
    generic dialer does not inspect or reinterpret the locator.
    """

    transports: tuple[str, ...]
    realize: Callable[
        ["Host", "Locator", Optional[int]], Awaitable["Session"]
    ]

    def __post_init__(self) -> None:
        symbols = tuple(self.transports)
        if not symbols or any(not isinstance(symbol, str) or not symbol for symbol in symbols):
            raise ValueError("connector must advertise at least one transport symbol")
        if len(set(symbols)) != len(symbols):
            raise ValueError("connector transport symbols must be unique")
        object.__setattr__(self, "transports", symbols)
        if not callable(self.realize):
            raise TypeError("connector realizer must be callable")

    def handles(self, transport: str) -> bool:
        return transport in self.transports

    async def connect(
        self,
        host: "Host",
        locator: "Locator",
        handshake_timeout_ms: Optional[int],
    ) -> "Session":
        if not self.handles(locator.transport):
            raise ValueError(
                f"connector does not advertise locator transport {locator.transport!r}"
            )
        return await self.realize(host, locator, handshake_timeout_ms)
