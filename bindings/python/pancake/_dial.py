"""Managed runtime and the byte-fed handoff dial seam.

``Runtime`` is the public composition boundary. It owns one Host and either a
native DriverLoop with installed providers or a byte-fed connector set. The
per-operation path only selects the already-retained authority for a locator;
transport configuration never re-enters the dial call.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import Optional, TYPE_CHECKING

from . import _constants as _abi
from ._abi_value import _DEFAULT_CODEC
from ._errors import PancakeError, _check_host, _retain_terminal_failure
from ._ffi_host import _host
from ._ffi_ocapn import _LocatorHintView, _LocatorView
from ._host import Host
from ._lifecycle import PendingWork, _UNSET, _close_options
from ._locator import Locator, _OwnedLocator
from ._transport import Connector, Provider

if TYPE_CHECKING:
    from ._loop import DriverLoop

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


def _validate_handshake_timeout(handshake_timeout_ms: Optional[int]) -> None:
    if handshake_timeout_ms is not None and (
        isinstance(handshake_timeout_ms, bool)
        or not isinstance(handshake_timeout_ms, int)
        or handshake_timeout_ms < 0
        or handshake_timeout_ms > ctypes.c_uint32(-1).value
    ):
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            "handshake_timeout_ms must be None or an unsigned 32-bit integer",
        )


def _composition(value, values, label):
    if value is not None and values is not None:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f"Runtime.open accepts either {label}= or {label}s=, not both",
        )
    if value is not None:
        result = (value,)
    elif values is not None:
        try:
            result = tuple(values)
        except TypeError:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"Runtime {label}s must be iterable") from None
    else:
        result = ()
    if not result:
        raise PancakeError(_ERR_INVALID_ARGUMENT, f"Runtime requires at least one {label}")
    return result


def _validate_composition(values, expected, label):
    for value in values:
        if not isinstance(value, expected):
            raise TypeError(f"Runtime {label}s must contain {expected.__name__} values")


class Runtime:
    """One managed Host and one long-lived transport composition.

    ``Runtime.open`` returns an awaitable async context manager. Both of these
    forms are supported::

        async with Runtime.open(provider=tcp.provider()) as runtime:
            session = await runtime.connect(tcp.locator("127.0.0.1", 9099))

        runtime = await Runtime.open(provider=tcp.provider())
        session = await runtime.connect(locator)
        await runtime.close()
    """

    def __init__(
        self,
        providers: tuple[Provider, ...],
        connectors: tuple[Connector, ...],
        *,
        adopt_host: Optional[Host],
        seed: Optional[bytes],
        codec: str,
        handshake_timeout_ms: Optional[int],
    ) -> None:
        self._providers = providers
        self._connectors = connectors
        self._adopt_host = adopt_host
        self._seed = seed
        self._codec = codec
        self._handshake_timeout_ms = handshake_timeout_ms
        self._host: Optional[Host] = None
        self._loop: Optional["DriverLoop"] = None
        self._opened = False
        self._opening: Optional[asyncio.Task[None]] = None
        self._closed = False
        self._terminal_failures: list[BaseException] = []
        self._terminal_failure_count = 0

    def _record_terminal_failure(self, error: BaseException) -> None:
        self._terminal_failure_count = _retain_terminal_failure(
            self._terminal_failures, self._terminal_failure_count, error
        )

    def _raise_terminal_failure(self) -> None:
        if self._terminal_failures:
            raise self._terminal_failures[0]

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        """Runtime-owned failures in observation order."""
        return tuple(self._terminal_failures)

    @property
    def terminal_failure_count(self) -> int:
        """Total distinct terminal occurrences, including bounded overflow."""
        return self._terminal_failure_count

    @classmethod
    def open(
        cls,
        *,
        provider: Optional[Provider] = None,
        providers=None,
        connector: Optional[Connector] = None,
        connectors=None,
        adopt_host: Optional[Host] = None,
        seed: Optional[bytes] = None,
        codec: Optional[str] = None,
        handshake_timeout_ms: Optional[int] = _abi.HANDSHAKE_TIMEOUT_MS,
    ) -> "Runtime":
        """Construct a runtime; native setup is completed on first await/use.

        Singular ``provider=`` and ``connector=`` are the idiomatic Python
        spelling. The plural aliases allow one runtime to compose several
        symbol-disjoint provider packages without introducing a Python-only
        wrapper type.
        """
        _validate_handshake_timeout(handshake_timeout_ms)
        selected_providers = (
            _composition(provider, providers, "provider") if (provider is not None or providers is not None) else ()
        )
        selected_connectors = (
            _composition(connector, connectors, "connector")
            if (connector is not None or connectors is not None)
            else ()
        )
        if bool(selected_providers) == bool(selected_connectors):
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "Runtime.open requires providers or connectors, but not both",
            )
        if selected_providers:
            _validate_composition(selected_providers, Provider, "provider")
        else:
            _validate_composition(selected_connectors, Connector, "connector")
        if adopt_host is not None and codec is not None and codec != adopt_host.codec:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                f'codec "{codec}" conflicts with the adopted host\'s "{adopt_host.codec}"',
            )
        return cls(
            selected_providers,
            selected_connectors,
            adopt_host=adopt_host,
            seed=seed,
            codec=codec if codec is not None else _DEFAULT_CODEC,
            handshake_timeout_ms=handshake_timeout_ms,
        )

    def __await__(self):
        return self._ensure_open().__await__()

    async def __aenter__(self) -> "Runtime":
        return await self._ensure_open()

    async def __aexit__(self, *exc) -> None:
        await self.close()

    async def _ensure_open(self) -> "Runtime":
        if self._closed:
            raise PancakeError(_abi.ERR_CLOSED, "Runtime is closed")
        if self._opened:
            return self
        if self._opening is None:
            self._opening = asyncio.ensure_future(self._open())
        await asyncio.shield(self._opening)
        return self

    async def _open(self) -> None:
        from ._loop import DriverLoop

        host = self._adopt_host
        created_host = host is None
        loop = None
        try:
            if host is None:
                host = Host(seed=self._seed, codec=self._codec)
            if self._providers:
                existing_loop = host.driver_loop is not None
                if existing_loop:
                    loop = host._driver_loop
                    assert loop is not None
                else:
                    loop = DriverLoop.take_host(
                        host,
                        handshake_ms=0 if self._handshake_timeout_ms is None else self._handshake_timeout_ms,
                    )
                    # A caller-supplied Host keeps this valid loop if later
                    # provider setup fails, so the caller can repair and retry.
                    loop.start()
                for provider in self._providers:
                    await provider.install(loop)
                managed_host = loop.wrapper_host()
                # The native provider registry is now the lifetime authority;
                # Runtime keeps no parallel provider table.
                self._host = managed_host
                self._loop = loop
                self._providers = ()
            else:
                if host.driver_loop is not None:
                    raise PancakeError(
                        _ERR_INVALID_ARGUMENT,
                        "a byte-fed Runtime cannot use a Host already owned by a driver loop",
                    )
                host.install_connectors(self._connectors)
                # Host._connectors is the one durable byte-fed authority used by
                # handoff redemption; Runtime only owns the Host and mode.
                self._host = host
                self._connectors = ()
            self._opened = True
        except BaseException as error:
            self._record_terminal_failure(error)
            if created_host:
                try:
                    if loop is not None:
                        loop.close()
                        await loop.wait_closed()
                    elif host is not None:
                        await host.close()
                except BaseException as cleanup_error:
                    self._record_terminal_failure(cleanup_error)
            raise

    @property
    def host(self) -> Host:
        """The Host owned by this runtime after setup."""
        if self._host is None or not self._opened:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "Runtime is not open")
        return self._host

    async def connect(
        self,
        partner: Locator,
        *,
        handshake_timeout_ms: Optional[int] = None,
    ):
        """Connect using the runtime's retained transport authority."""
        await self._ensure_open()
        if handshake_timeout_ms is not None:
            _validate_handshake_timeout(handshake_timeout_ms)
        timeout = self._handshake_timeout_ms if handshake_timeout_ms is None else handshake_timeout_ms
        if self._loop is not None:
            if handshake_timeout_ms is not None and timeout != self._handshake_timeout_ms:
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "native Runtime handshake_timeout_ms is configured at Runtime.open",
                )
            from ._loop import dial_shared_loop

            return await dial_shared_loop(self._loop, partner)
        connector = self.host._connector_for(partner.transport)
        if connector is None:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                f"Runtime has no connector for {partner.transport!r}",
            )
        return await connector.connect(self.host, partner, timeout)

    async def close(
        self,
        pending: PendingWork = PendingWork.CANCEL,
        *,
        grace: object = _UNSET,
    ) -> None:
        _close_options(pending, grace)
        if self._closed:
            self._raise_terminal_failure()
            return
        opening_error: Optional[BaseException] = None
        cancellation: Optional[asyncio.CancelledError] = None
        if self._opening is not None:
            try:
                await asyncio.shield(self._opening)
            except asyncio.CancelledError as error:
                # The setup task is Runtime-owned and shielded from arbitrary
                # waiters. A cancelled close must still join it and retire any
                # Host it publishes before returning cancellation to its owner.
                cancellation = error
                try:
                    await asyncio.shield(self._opening)
                except BaseException as settled_error:
                    opening_error = settled_error
            except BaseException as error:
                opening_error = error
        close_error: Optional[BaseException] = None
        if self._host is not None:
            try:
                await self._host.close(pending, grace=grace)
            except BaseException as error:
                self._record_terminal_failure(error)
                close_error = error
            finally:
                if self._host.released:
                    self._closed = True
        else:
            # A Runtime that never committed an open Host owns no provider,
            # connector task, or admitted operation after `_open` unwinds.
            self._closed = True
        if cancellation is not None:
            raise cancellation
        if opening_error is not None:
            raise opening_error
        if close_error is not None:
            raise close_error


async def dial_parsed_locator(
    locator: Locator,
    host: Host,
    *,
    connector: Connector,
    handshake_timeout_ms: Optional[int] = _abi.HANDSHAKE_TIMEOUT_MS,
):
    """Binding-internal byte-fed dial used by handoff redemption."""
    _validate_handshake_timeout(handshake_timeout_ms)
    return await connector.connect(host, locator, handshake_timeout_ms)


async def dial_exporter(
    locator: Locator,
    host: Host,
    handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS,
):
    """Redeem a DIAL action through the Host's retained connector authority."""
    connector = host._connector_for(locator.transport)
    if connector is None:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f"handoff redeem has no registered connector for {locator.transport!r}",
        )
    return await dial_parsed_locator(
        locator,
        host,
        connector=connector,
        handshake_timeout_ms=handshake_timeout_ms,
    )


async def run_dial_ticket(host: Host, ticket: int) -> None:
    """Ticket-only DIAL arm: clone the complete locator, dial, and report."""
    from ._ffi_ocapn import _byte_buf

    session = None
    try:
        if host.released:
            return
        view = _LocatorView()
        count = ctypes.c_size_t()
        hints = None
        rc = _host.pancake_host_pending_dial(
            host.raw,
            ticket,
            None,
            0,
            ctypes.byref(view),
            ctypes.byref(count),
        )
        if rc == _abi.ERR_BUFFER_TOO_SMALL:
            capacity = count.value
            hints = (_LocatorHintView * capacity)()
            view = _LocatorView()
            count = ctypes.c_size_t()
            rc = _host.pancake_host_pending_dial(
                host.raw,
                ticket,
                hints,
                capacity,
                ctypes.byref(view),
                ctypes.byref(count),
            )
        _check_host(rc)
        with _OwnedLocator.clone_view(ctypes.cast(ctypes.byref(view), ctypes.c_void_p)) as owned:
            locator = owned.value()
        session = await dial_exporter(locator, host)
        if host.released:
            session.close_transport()
            return
        _check_host(_host.pancake_host_dialed(host.raw, ticket, session.raw))
        # A reported dial retires close-relevant pending work; wake any parked
        # close driver.
        host.signal_close_activity()
        session.serve()
        session = None
    except asyncio.CancelledError:
        if session is not None:
            session.close_transport()
        raise
    except BaseException as error:
        if session is not None:
            session.close_transport()
        if host.released:
            return
        reason = (str(error) or type(error).__name__).encode()
        _buf, ptr = _byte_buf(reason)
        _check_host(_host.pancake_host_dial_failed(host.raw, ticket, ptr, len(reason)))
        host.signal_close_activity()
        if not isinstance(error, Exception):
            raise
