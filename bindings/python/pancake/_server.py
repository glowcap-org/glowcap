"""Shared high-level lifecycle for generic driver listeners."""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from typing import cast, TYPE_CHECKING, Optional, Self

from . import _constants as _c
from ._errors import PancakeError, _retain_cleanup_failure
from ._host import Host
from ._locator import Locator, format_locator_uri

if TYPE_CHECKING:
    from ._listener import ListenerOwner
    from ._loop import DriverLoop
    from ._session import Session


class DriverServer:
    """One driver listener yielding application-facing CapTP sessions."""

    def __init__(
        self,
        driver_loop: "DriverLoop",
        listener: "ListenerOwner",
        *,
        retire_loop: bool,
    ) -> None:
        self._driver_loop = driver_loop
        self._listener = listener
        self._retire_loop = retire_loop
        self._closed = False

    @property
    def locator(self) -> Locator:
        """The complete canonical locator currently advertised by the driver."""
        return self._driver_loop.listener_locator(self._listener)

    @property
    def uri(self) -> str:
        """The complete canonical locator currently advertised by the driver."""
        return format_locator_uri(self.locator)

    @property
    def designator(self) -> str:
        """The locator designator currently advertised by the driver."""
        return self.locator.designator

    @property
    def host(self) -> Host:
        return self._driver_loop.wrapper_host()

    def _request_close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._listener.close()
        if self._retire_loop:
            self._driver_loop.request_close()

    async def close(self) -> None:
        """Stop admission and preserve sessions already returned.

        A server that minted its own loop requests that loop's retirement.
        Native release runs once those application-owned sessions close; this
        method does not wait for them, so a finally block can still close the
        sessions it holds. An idle owned loop releases synchronously.
        """
        self._request_close()

    def __aiter__(self) -> Self:
        return self

    async def __anext__(self) -> "Session":
        try:
            return await self._driver_loop.accept_session(self._listener)
        except PancakeError as error:
            if error.code == _c.ERR_CLOSED:
                raise StopAsyncIteration from None
            raise

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()


@dataclass(frozen=True)
class _PreparedDriverLoop:
    loop: "DriverLoop"
    owns_loop: bool


def _rollback_listener_construction(
    primary: BaseException,
    loop: "DriverLoop",
    listener: "Optional[ListenerOwner]",
    owns_loop: bool,
) -> BaseException:
    """Retire every admitted owner while preserving construction as primary."""
    cleanups = []
    if listener is not None:
        cleanups.append(listener.close)
    if owns_loop:
        cleanups.append(loop.close)
    for cleanup in cleanups:
        try:
            cleanup()
        except BaseException as cleanup_error:
            _retain_cleanup_failure(primary, cleanup_error)
    return primary


def prepare_driver_loop(
    host: Optional[Host],
    codec: str,
    *,
    seed: Optional[bytes] = None,
) -> _PreparedDriverLoop:
    """Prepare a loop without conflating startup with ownership."""
    from ._loop import DriverLoop

    if host is not None:
        if codec != host.codec:
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT,
                f'codec "{codec}" conflicts with the host\'s "{host.codec}"',
            )
        if host.driver_loop is not None:
            return _PreparedDriverLoop(cast("DriverLoop", host._driver_loop), False)
        return _PreparedDriverLoop(DriverLoop.take_host(host), False)
    if seed is None:
        loop = DriverLoop.open(codec=codec, handshake_ms=_c.HANDSHAKE_TIMEOUT_MS)
    else:
        loop = DriverLoop.open(
            seed=seed + secrets.token_bytes(32),
            codec=codec,
            handshake_ms=_c.HANDSHAKE_TIMEOUT_MS,
        )
    return _PreparedDriverLoop(loop, True)
