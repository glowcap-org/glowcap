"""FFI iroh endpoint, connection, and generic-provider ownership."""

from __future__ import annotations

import asyncio
import ctypes
from dataclasses import dataclass
import enum
import threading
from typing import Optional, Union

# The core binding owns the value vocabulary, the host/connection machinery, and
# the shared archives; the iroh transport plugs into that seam as the byte
# transport a `Session`'s serve loop reads. The raw iroh FFI loader behind
# ``_iroh()`` lives in the internal :mod:`glowcap._ffi_iroh`.
from . import _constants as _c
from ._constants import (
    ERR_CLOSED as _ERR_CLOSED,
    ERR_BUFFER_TOO_SMALL as _ERR_BUFFER_TOO_SMALL,
    ERR_INVALID_ARGUMENT as _ERR_INVALID_ARGUMENT,
    HINT_DIRECT_ADDRESSES,
    IROH_NODE_ID_BYTES,
    OK as _OK,
    TRANSPORT_IROH,
    WOULD_BLOCK as _WOULD_BLOCK,
)
from ._errors import GlowcapError
from ._ffi import FfiHandle, _FfiHandleOwner
from ._locator import Locator
from ._ffi_ocapn import _byte_buf, _read_last_error
from ._ffi_iroh import _iroh, _IrohConfig
from ._transport import (
    Provider,
    _rollback_failed_provider,
    _record_transport_cleanup_failure,
)


def locator(node_id: str, direct_addresses: Optional[str] = None) -> Locator:
    """Build an iroh locator, optionally carrying direct socket addresses."""
    return Locator(
        TRANSPORT_IROH,
        node_id,
        {} if direct_addresses is None else {HINT_DIRECT_ADDRESSES: direct_addresses},
        "boolean-false" if direct_addresses is None else "map",
    )


def _iroh_last_error() -> "Optional[str]":
    """The calling thread's last error message from the iroh transport archive
    (``libglowcap_net_transport_iroh``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so an iroh call's diagnostic is
    read here and never from the core family's :func:`glowcap.last_error`."""
    return _read_last_error(_iroh().glowcap_iroh_last_error)


def _check_iroh(code: int) -> None:
    # The iroh library carries its own thread-local last-error, so read this
    # archive's own slot rather than scraping libglowcap_ocapn's unrelated one.
    if code != _OK:
        raise GlowcapError(
            code, _iroh_last_error() or f"iroh transport call failed (code {code})"
        )


class Reachability(enum.IntEnum):
    """An iroh endpoint's addressing posture: how it dials partners and how it
    is dialed. Every iroh constructor requires it explicitly. There is **no
    default**, because the right posture is a deployment decision (relay-less vs
    relayed, discovery vs none) and a hidden one would silently route, or refuse
    to route, a partner's traffic.

    ``DIRECT``
        Dial by endpoint id plus direct-address hints. Relay-less, no discovery.
        A URI must carry ``direct-addresses``. This is the rooms demo's posture.
    ``DISCOVERY``
        Use the n0 relays and DNS discovery, so a partner is dialable by
        endpoint id alone.
    ``DISCOVERY_NO_RELAY``
        Use DNS discovery, but no relays.
    ``LOCAL_DISCOVERY``
        Use an in-process address book, for tests and same-process peers.
    """

    DIRECT = _c.IROH_REACH_DIRECT
    DISCOVERY = _c.IROH_REACH_DISCOVERY
    DISCOVERY_NO_RELAY = _c.IROH_REACH_DISCOVERY_NO_RELAY
    LOCAL_DISCOVERY = _c.IROH_REACH_LOCAL_DISCOVERY


_NETLAYER_CONSTRUCTION = object()


class IrohConnection(_FfiHandleOwner):
    """One iroh QUIC connection carrying one OCapN session, the iroh sibling of
    :class:`glowcap.tcp.TcpConnection`. It is driven by an :class:`_IrohLoop`, which
    frames the raw bytes :meth:`try_read_into` hands out the same way the TCP pump
    frames its socket bytes. No call here ever parks on the connection, so a
    release never races a read."""

    def __init__(self, raw: ctypes.c_void_p, netlayer: "IrohNetlayer") -> None:
        self._netlayer = netlayer
        self._ffi = FfiHandle(
            raw,
            _iroh().glowcap_iroh_conn_release,
            label="iroh connection",
            keepalive=netlayer,
        )
        if not netlayer._adopt_conn(self):
            self._ffi.close()
            raise RuntimeError("iroh netlayer is closed")

    def key(self) -> int:
        """This connection's stable readiness identity."""
        if self._ffi.closed:
            return 0
        with self._ffi.lease() as raw:
            return int(_iroh().glowcap_iroh_conn_id(raw))

    def remote_node_id(self) -> "str | None":
        """The far end's node id, as QUIC proved it: this connection completed
        only because the peer held the secret for this key. ``None`` when the
        connection is gone or the handshake proved nothing.

        This is the fact a session is otherwise missing. glowcap cannot see it
        -- it did not open this connection -- so whoever did passes it on with
        :meth:`Session.bind_verified_channel_key`, which the accept and dial
        paths below do for every session this module establishes."""
        if self._ffi.closed:
            return None
        cap = IROH_NODE_ID_BYTES
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t(0)
        with self._ffi.lease() as raw:
            code = _iroh().glowcap_iroh_conn_remote_node_id(
                raw,
                buf,
                cap,
                ctypes.byref(out_len),
            )
        if code != _OK:
            return None
        return buf.raw[: out_len.value].decode()

    def try_read_into(self, buf) -> int:
        """Non-blocking read of raw inbound bytes into the ctypes ``buf``: the
        byte count (>0), ``_WOULD_BLOCK`` when nothing is buffered yet,
        ``_ERR_CLOSED`` on a clean end of stream, or raises on a fault. The caller
        frames these bytes itself."""
        out = ctypes.c_size_t()
        with self._ffi.lease() as raw:
            rc = _iroh().glowcap_iroh_conn_try_read(
                raw, buf, len(buf), ctypes.byref(out)
            )
        if rc == _WOULD_BLOCK or rc == _ERR_CLOSED:
            return rc
        if rc != _OK:
            raise GlowcapError(
                rc, _iroh_last_error() or f"iroh conn try_read failed (code {rc})"
            )
        return out.value

    def try_write(self, frame: bytes, offset: int = 0) -> int:
        """Non-blocking write of ``frame``'s raw bytes: the count written
        (possibly a prefix), or ``_WOULD_BLOCK`` when the outbound buffer has no
        room. Raises on a fault."""
        if offset < 0 or offset > len(frame):
            raise ValueError("iroh write offset is outside the frame")
        # The C call borrows only until it returns. Keep this object live so a
        # partial write can advance by offset without copying the suffix.
        borrowed = ctypes.c_char_p(frame)
        base = ctypes.cast(borrowed, ctypes.c_void_p).value
        if base is None:
            raise GlowcapError(_ERR_CLOSED, "iroh conn try_write received no buffer")
        buf = ctypes.c_void_p(base + offset)
        remaining = len(frame) - offset
        out = ctypes.c_size_t()
        with self._ffi.lease() as raw:
            rc = _iroh().glowcap_iroh_conn_try_write(
                raw, buf, remaining, ctypes.byref(out)
            )
        if rc == _WOULD_BLOCK:
            return rc
        if rc != _OK:
            raise GlowcapError(
                rc, _iroh_last_error() or f"iroh conn try_write failed (code {rc})"
            )
        return out.value

    def __enter__(self) -> "IrohConnection":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        try:
            self._ffi.close()
        finally:
            self._netlayer._forget_conn(self)


@dataclass(frozen=True)
class IrohConfig:
    """One iroh endpoint's configuration, field-for-field with the header's
    ``GlowcapIrohConfig``, which documents what each setting means. ``None``
    for a timeout takes the transport's default.

    ``reachability`` is mandatory: enabling relays or a discovery service is
    always the caller's visible choice. ``connect_timeout_ms`` bounds getting a
    connection up, ``idle_timeout_ms`` bounds keeping one. Set
    ``idle_timeout_ms`` if you read a live session as presence, because it is
    what ends a connection whose peer was killed rather than closed.
    ``worker_threads`` sizes this endpoint's sidecar runtime. ``None`` takes
    glowcap's default.
    """

    reachability: "Union[int, Reachability]"
    connect_timeout_ms: "Optional[int]" = None
    idle_timeout_ms: "Optional[int]" = None
    worker_threads: "Optional[int]" = None


class IrohNetlayer(_FfiHandleOwner):
    """A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
    sibling of :class:`glowcap.tcp.TcpNetlayer`, and its own listener (there is no
    host:port, so :meth:`accept` lives here). It owns every :class:`IrohConnection` it
    mints and releases remaining children before its FFI endpoint.

    ``reachability`` (a :class:`Reachability`) is required, it sets the
    endpoint's addressing posture and has no default."""

    def __init__(
        self,
        config: IrohConfig,
        secret_seed: "Optional[bytes]" = None,
        *,
        _construction_token=None,
    ):
        if _construction_token is not _NETLAYER_CONSTRUCTION:
            raise RuntimeError("use 'await IrohNetlayer.open(...)' to bind an endpoint")
        seed = secret_seed or b""
        # Empty means "draw a fresh random key"; keep the NULL the header
        # documents for that arm.
        buf, ptr = _byte_buf(seed) if seed else (None, None)
        out = ctypes.c_void_p()
        # Zero-initialized by `ctypes.Structure`, and 0 means the built-in
        # default for every timeout: the header's zero-init contract.
        cfg = _IrohConfig(reachability=int(config.reachability))
        if config.connect_timeout_ms is not None:
            cfg.connect_timeout_ms = config.connect_timeout_ms
        if config.idle_timeout_ms is not None:
            cfg.idle_timeout_ms = config.idle_timeout_ms
        if config.worker_threads is not None:
            if config.worker_threads <= 0 or config.worker_threads > 0xFFFFFFFF:
                raise GlowcapError(
                    _ERR_INVALID_ARGUMENT,
                    "iroh worker_threads must be between 1 and 4294967295",
                )
            cfg.worker_threads = config.worker_threads
        _check_iroh(
            _iroh().glowcap_iroh_netlayer_new(
                ptr,
                len(seed),
                ctypes.byref(cfg),
                ctypes.byref(out),
                None,
                0,
                None,
            )
        )
        self._ffi = FfiHandle(
            out,
            lambda raw: _check_iroh(
                _iroh().glowcap_iroh_netlayer_release(raw, None, 0, None)
            ),
            _iroh().glowcap_iroh_netlayer_close,
            label="iroh netlayer",
        )
        self._children_lock = threading.Lock()
        self._children: "set[IrohConnection]" = set()
        self._close_started = False
        # One retained task owns the non-cancelable FFI release. Callers may
        # cancel their wait, but the task remains the join point for every later
        # close call.
        self._close_task: "Optional[asyncio.Task]" = None

    @classmethod
    async def open(
        cls,
        config: IrohConfig,
        secret_seed: "Optional[bytes]" = None,
    ) -> "IrohNetlayer":
        """Bind off-reactor, retaining ownership through caller cancellation.

        A worker thread cannot be canceled once FFI endpoint construction
        starts. Cancellation therefore joins that construction and explicitly
        releases the resulting endpoint before it propagates.
        """
        construction = asyncio.create_task(
            asyncio.to_thread(
                cls,
                config,
                secret_seed,
                _construction_token=_NETLAYER_CONSTRUCTION,
            )
        )
        try:
            return await asyncio.shield(construction)
        except asyncio.CancelledError:
            # Further cancel requests must not detach the non-cancelable worker
            # or its cleanup. Keep joining until each owned task is terminal.
            while not construction.done():
                try:
                    await asyncio.shield(construction)
                except asyncio.CancelledError:
                    continue
                except BaseException:
                    break
            if not construction.cancelled() and construction.exception() is not None:
                error = construction.exception()
                assert error is not None
                _record_transport_cleanup_failure(
                    "iroh-construction-after-cancel", error
                )
            elif not construction.cancelled():
                netlayer = construction.result()
                release = asyncio.create_task(netlayer.close())
                while not release.done():
                    try:
                        await asyncio.shield(release)
                    except asyncio.CancelledError:
                        continue
                    except BaseException:
                        break
                try:
                    release.result()
                except BaseException as error:
                    _record_transport_cleanup_failure(
                        "iroh-release-after-cancel", error
                    )
            raise

    def node_id(self) -> str:
        """This endpoint's id, its Ed25519 public key as lowercase hex, the
        dialable designator a keyed locator signs."""
        cap = IROH_NODE_ID_BYTES
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        with self._ffi.lease() as raw:
            _check_iroh(
                _iroh().glowcap_iroh_netlayer_node_id(raw, out, cap, ctypes.byref(n))
            )
        return ctypes.string_at(out, n.value).decode()

    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct socket addresses, the dialing
        hint a partner needs because the sidecar binds relay-less."""
        n = ctypes.c_size_t()
        with self._ffi.lease() as raw:
            rc = _iroh().glowcap_iroh_netlayer_direct_addrs(
                raw,
                None,
                0,
                ctypes.byref(n),
            )
        if rc != _ERR_BUFFER_TOO_SMALL:
            _check_iroh(rc)
            if n.value == 0:
                return ""
        cap = n.value
        while True:
            out = (ctypes.c_uint8 * cap)()
            n = ctypes.c_size_t()
            with self._ffi.lease() as raw:
                rc = _iroh().glowcap_iroh_netlayer_direct_addrs(
                    raw,
                    out,
                    cap,
                    ctypes.byref(n),
                )
            if rc == _ERR_BUFFER_TOO_SMALL and n.value > cap:
                cap = n.value
                continue
            _check_iroh(rc)
            return ctypes.string_at(out, n.value).decode()

    # ── The event-driven loop surface (ADR-0057) ────────────────────────────────
    # These back :class:`_IrohLoop`: the endpoint's one I/O model, serving many
    # connections from one readiness fd registered with the asyncio event loop.
    # The loop is armed when the netlayer is created, so these work immediately.

    def _transport_provider(self):
        """Borrow this endpoint's archive-owned provider package."""
        from ._ffi_driver import _TransportProvider

        package = _TransportProvider()
        with self._ffi.lease() as raw:
            rc = _iroh().glowcap_iroh_transport_provider(raw, ctypes.byref(package))
        if rc != _OK:
            raise GlowcapError(
                rc, _iroh_last_error() or f"iroh transport_provider failed (code {rc})"
            )
        return package

    def _relinquish_provider_reference(self) -> None:
        """Transfer endpoint lifetime to an already-retained provider lease."""
        with self._children_lock:
            if self._close_started or self._children:
                raise RuntimeError("iroh netlayer is not transferable")
            self._close_started = True
        self._ffi.drop_reference()

    def readiness_fd(self) -> int:
        """This endpoint's single readiness fd, register it with the event loop
        (``add_reader``) and call :meth:`drain_ready` when it signals. Owned by
        the netlayer. Never close it."""
        with self._ffi.lease() as raw:
            fd = _iroh().glowcap_iroh_netlayer_readiness_fd(raw)
        if fd < 0:
            raise GlowcapError(
                fd, _iroh_last_error() or f"iroh readiness_fd failed (code {fd})"
            )
        return fd

    def drain_ready(self, buf, cap: int) -> int:
        """Drain the pending readiness records into ``buf`` (a ``_IrohReadyEvent``
        array of ``cap`` entries) without blocking. Returns the record count (0
        when none). Raises on fault. Call it when :meth:`readiness_fd` signals,
        then again until it returns fewer than ``cap`` records."""
        out = ctypes.c_size_t()
        with self._ffi.lease() as raw:
            rc = _iroh().glowcap_iroh_netlayer_drain_ready(
                raw, buf, cap, ctypes.byref(out)
            )
        if rc != _OK:
            raise GlowcapError(
                rc, _iroh_last_error() or f"iroh drain_ready failed (code {rc})"
            )
        return out.value

    def try_accept(self) -> "Optional[IrohConnection]":
        """Claim one accepted non-blocking connection, or ``None`` when none is
        pending."""
        out = ctypes.c_void_p()
        with self._ffi.lease() as raw:
            code = _iroh().glowcap_iroh_netlayer_try_accept(raw, ctypes.byref(out))
        if code == _WOULD_BLOCK:
            return None
        _check_iroh(code)
        return IrohConnection(out, self)

    def start_connect(self, request_id: int, node_id: str, addr_hints: str) -> None:
        """Admit one dial without blocking. Completion arrives as EV_CONNECT."""
        id_b = node_id.encode()
        hints_b = addr_hints.encode()
        id_buf, id_ptr = _byte_buf(id_b)
        hints_buf, hints_ptr = _byte_buf(hints_b)
        with self._ffi.lease() as raw:
            _check_iroh(
                _iroh().glowcap_iroh_netlayer_start_connect(
                    raw,
                    request_id,
                    id_ptr,
                    len(id_b),
                    hints_ptr,
                    len(hints_b),
                )
            )
        _ = (id_buf, hints_buf)

    def finish_connect(self, request_id: int) -> IrohConnection:
        out = ctypes.c_void_p()
        with self._ffi.lease() as raw:
            _check_iroh(
                _iroh().glowcap_iroh_netlayer_finish_connect(
                    raw,
                    request_id,
                    ctypes.byref(out),
                )
            )
        return IrohConnection(out, self)

    def cancel_connect(self, request_id: int) -> None:
        with self._ffi.lease() as raw:
            _check_iroh(_iroh().glowcap_iroh_netlayer_cancel_connect(raw, request_id))

    def __enter__(self) -> "IrohNetlayer":
        return self

    def __exit__(self, *exc) -> None:
        self._release_blocking()

    def _release_blocking(self) -> None:
        for child in self._begin_close():
            child.close()
        self._ffi.close()

    async def __aenter__(self) -> "IrohNetlayer":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    def _adopt_conn(self, conn: IrohConnection) -> bool:
        with self._children_lock:
            if self._close_started:
                return False
            self._children.add(conn)
            return True

    def _forget_conn(self, conn: IrohConnection) -> None:
        with self._children_lock:
            self._children.discard(conn)

    def _begin_close(self) -> "list[IrohConnection]":
        with self._children_lock:
            self._close_started = True
            return list(self._children)

    def _start_close_task(self) -> "Optional[asyncio.Task]":
        """Start or return the one task that owns FFI endpoint release."""
        task = self._close_task
        if task is not None:
            return task
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            self._release_blocking()
            return None
        task = loop.create_task(asyncio.to_thread(self._release_blocking))
        self._close_task = task
        return task

    async def close(self) -> None:
        """Close, join operation leases, and release off the asyncio reactor.

        Cancellation is remembered and re-raised only after the retained task
        has completed, so canceling a caller cannot detach FFI teardown.
        """
        task = self._start_close_task()
        if task is None:
            return
        cancelled = False
        while True:
            try:
                await asyncio.shield(task)
                break
            except asyncio.CancelledError:
                cancelled = True
        if cancelled:
            raise asyncio.CancelledError


async def adopt_loop_provider(
    loop, config: IrohConfig, *, seed: "Optional[bytes]" = None
):
    """Install iroh through the generic provider seam and return its node id."""
    selected = seed if seed is not None else loop.wrapper_host().seed
    return await provider(config, seed=selected).install(loop)


def provider(
    config: IrohConfig,
    *,
    seed: "Optional[bytes]" = None,
) -> Provider:
    """Build the configured FFI iroh provider package."""

    async def install(loop):
        selected = seed if seed is not None else loop.wrapper_host().seed
        if len(selected) != 32:
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT, "iroh provider seed must be 32 bytes"
            )
        netlayer = await IrohNetlayer.open(config, bytes(selected))
        try:
            node_id = netlayer.node_id()
            loop._install_provider(
                lambda register: register(netlayer._transport_provider())
            )
            netlayer._relinquish_provider_reference()
            return node_id
        except BaseException as primary:
            _rollback_failed_provider(primary, netlayer._release_blocking)
            raise

    return Provider(install)
