"""Application-owned CapTP Session state and construction.

The package root owns the public class identity, every mutable field, and the
dial/accept handshake. :mod:`.lifecycle` owns terminal transition effects;
:mod:`.verbs` owns capability, identity, and GC operations. The leaves have no
initializer, finalizer, or runtime edge back to this root.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import Optional

from .. import _constants as _abi
from .. import _pump
from .._errors import PancakeError, _check_host
from .._ffi_host import _host
from .._ffi_ocapn import _byte_buf, _ManagedFrame
from .._host import Host
from .._locator import _OwnedLocator, Locator
from .lifecycle import _LifecycleMixin
from .profile import SessionProfile, read_session_profile, read_session_transport_name
from .verbs import PartnerIdentity, SendRedeemingResult, _VerbsMixin

_ERR_CLOSED = _abi.ERR_CLOSED
_ERR_TIMEOUT = _abi.ERR_TIMEOUT
_HANDSHAKE_TIMEOUT_MS = _abi.HANDSHAKE_TIMEOUT_MS


class _OutboundScratch:
    """One Session's reusable C descriptors, serialized by ``write_lock``."""

    __slots__ = ("frame", "prefix", "prefix_len")

    def __init__(self) -> None:
        self.frame = _ManagedFrame()
        self.prefix = (ctypes.c_ubyte * _abi.HOST_OUTBOUND_PREFIX_CAP)()
        self.prefix_len = ctypes.c_size_t()


class Session(_LifecycleMixin, _VerbsMixin):
    """A live CapTP session with one OCapN partner.

    The root is the sole storage and construction owner. The two private bases
    partition methods only: they define no initializer, finalizer, fields,
    cooperative ``super`` chain, or overlapping operation.
    """

    def __init__(self, ptr: ctypes.c_void_p, host: Host, transport):
        self._ptr: ctypes.c_void_p | None = ptr
        self._key = ptr.value or 0
        self._host = host
        self._transport = transport
        host._bind_running_loop()
        self._serve_task: Optional[asyncio.Task] = None
        self._closing = False
        self._released = False
        self._release_pending = False
        self._close_future: Optional[asyncio.Future[None]] = None
        self._wire_failure: Optional[BaseException] = None
        self._terminal_failures: list[BaseException] = []
        self._terminal_failure_count = 0
        # Every close caller shields this one effect owner. It remains strongly
        # held after completion so repeated close observes the exact outcome.
        self._terminal_task: Optional[asyncio.Task[None]] = None
        # Loop-backed repeats can escalate pending-work policy while the first
        # close is in flight. The terminal coordinator drains every request.
        self._loop_close_tasks: set[asyncio.Task[None]] = set()
        self._close_request_signature: Optional[tuple[int, int, int]] = None
        self._transport_lost = False
        self._transport_close_started = False
        # Native byte-fed progress is a child effect of the terminal
        # coordinator and must outlive cancellation of any one close waiter.
        self._close_task: Optional[asyncio.Task[None]] = None
        self._write_lock = asyncio.Lock()
        # Reused only under _write_lock. Payload bytes are still copied before
        # await because Python cannot retain the native frame across it.
        self._outbound_scratch = _OutboundScratch()
        self._hosted = host._hosted
        self._gc_enabled = False
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = (
                asyncio.get_running_loop()
            )
        except RuntimeError:
            self._loop = None
        host.register_session(self._key, self)

    # ── Construction: establish, dial, accept ───────────────────────────────

    @classmethod
    def _open_dialed_locator(
        cls,
        host: Host,
        locator: Locator,
        transport,
    ) -> "Session":
        """Mint a dialing half without driving the signed handshake."""
        out = ctypes.c_void_p()
        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.pancake_host_session_open_dialed_locator(
                    host.raw,
                    owned.borrow_view(),
                    ctypes.byref(out),
                )
            )
        return cls(out, host, transport)

    @classmethod
    async def establish_dialed_locator(
        cls,
        host: Host,
        locator: Locator,
        transport,
        handshake_timeout_ms: "Optional[int]" = _HANDSHAKE_TIMEOUT_MS,
        verified_channel_key: "Optional[str]" = None,
    ) -> "Session":
        """Mint and establish the dialing half over an owned byte channel."""
        session = cls._open_dialed_locator(host, locator, transport)
        return await session._bind_channel_proof_and_establish(
            verified_channel_key, handshake_timeout_ms
        )

    @classmethod
    async def establish_accepted(
        cls,
        host: Host,
        transport_name: str,
        server_designator: str,
        transport,
        accepted_local_addr: str = "",
        handshake_timeout_ms: "Optional[int]" = _HANDSHAKE_TIMEOUT_MS,
        verified_channel_key: "Optional[str]" = None,
    ) -> "Session":
        """Mint and establish an accepted byte channel from a listener."""
        transport_raw = transport_name.encode()
        server_raw = server_designator.encode()
        local_raw = accepted_local_addr.encode()
        transport_buf, transport_ptr = _byte_buf(transport_raw)
        server_buf, server_ptr = _byte_buf(server_raw)
        local_buf, local_ptr = _byte_buf(local_raw)
        designator_scheme = getattr(transport, "designator_scheme", None)
        if designator_scheme is None:
            transport.close()
            raise PancakeError(
                _abi.ERR_INVALID_ARGUMENT,
                "accepted byte-channel provider must declare its designator scheme",
            )
        out = ctypes.c_void_p()
        _check_host(
            _host.pancake_host_session_open_accepted(
                host.raw,
                transport_ptr,
                len(transport_raw),
                designator_scheme,
                server_ptr,
                len(server_raw),
                local_ptr,
                len(local_raw),
                ctypes.byref(out),
            )
        )
        del transport_buf, server_buf, local_buf
        session = cls(out, host, transport)
        return await session._bind_channel_proof_and_establish(
            verified_channel_key, handshake_timeout_ms
        )

    async def _bind_channel_proof_and_establish(
        self,
        verified_channel_key: "Optional[str]",
        handshake_timeout_ms: "Optional[int]",
    ) -> "Session":
        """Consume post-mint setup under this Session's transport ownership."""
        try:
            if verified_channel_key:
                self.bind_verified_channel_key(verified_channel_key)
            return await self._establish(handshake_timeout_ms)
        except BaseException:
            self.close_transport()
            raise

    async def _establish(
        self,
        handshake_timeout_ms: "Optional[int]" = _HANDSHAKE_TIMEOUT_MS,
    ) -> "Session":
        """Drive the bounded signed handshake and abandon on every failure."""
        try:
            if handshake_timeout_ms:
                await asyncio.wait_for(
                    _pump._run_handshake(self),
                    handshake_timeout_ms / 1000,
                )
            else:
                await _pump._run_handshake(self)
            return self
        except asyncio.TimeoutError:
            self.close_transport()
            raise PancakeError(
                _ERR_TIMEOUT,
                f"the partner did not finish the OCapN handshake within {handshake_timeout_ms}ms",
            ) from None
        except BaseException:
            self.close_transport()
            raise

    # ── Binding-internal state seam ─────────────────────────────────────────

    @property
    def raw(self) -> ctypes.c_void_p:
        self._host._assert_owner()
        if self._ptr is None:
            raise PancakeError(_ERR_CLOSED, "the session has been released")
        return self._ptr

    @property
    def host(self) -> Host:
        """The Host shared by this session and all sibling sessions."""
        return self._host

    @property
    def released(self) -> bool:
        return self._released

    @property
    def closing_flag(self) -> bool:
        return self._closing

    @closing_flag.setter
    def closing_flag(self, value: bool) -> None:
        self._closing = value

    @property
    def is_closing(self) -> bool:
        return self._closing or self._released

    @property
    def session_open(self) -> bool:
        self._host._assert_owner()
        return not self._released and _host.pancake_host_session_is_open(self._ptr) == 1

    @property
    def profile(self) -> SessionProfile:
        """The settled version, codec, and mutually supported feature bits."""
        return read_session_profile(self.raw)

    @property
    def transport_name(self) -> str:
        """The exact netlayer symbol this connection was opened through."""
        return read_session_transport_name(self.raw)

    @property
    def write_lock(self) -> asyncio.Lock:
        return self._write_lock

    @property
    def outbound_scratch(self) -> _OutboundScratch:
        return self._outbound_scratch

    @property
    def transport(self):
        return self._transport

    @property
    def gc(self):
        return self._host.gc

    @property
    def gc_enabled(self) -> bool:
        return self._gc_enabled

    @property
    def hosted(self) -> "dict[int, int]":
        return self._hosted

    def schedule_on_loop(self, run) -> None:
        """Hop a finalizer drain onto the Session's owning event loop."""
        loop = self._loop
        if loop is None:
            return
        try:
            loop.call_soon_threadsafe(run)
        except RuntimeError:
            pass  # closed-loop Host teardown reclaims the partner export

    def guard_open(self) -> None:
        """Refuse an operation after terminal teardown has begun."""
        self._host._assert_owner()
        if self._closing or self._released:
            self.raise_wire_failure()
            raise PancakeError(_ERR_CLOSED, "connection closed")


__all__ = ["PartnerIdentity", "SendRedeemingResult", "Session"]
