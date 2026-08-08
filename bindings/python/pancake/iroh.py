"""Idiomatic Python API for ``libpancake_net_transport_iroh``, pancake's optional
encrypted-QUIC (iroh) transport, the companion to the core :mod:`pancake` module.

The split mirrors the artifacts: ``pancake`` rides ``libpancake_ocapn`` (the
pure-Zig codec-neutral CapTP core, all you need for TCP) and this module rides
``libpancake_net_transport_iroh`` (a *companion* library that links a Rust iroh sidecar; it
exports only the ``pancake_iroh_*`` family and shares no core symbol, so this
module loads it *alongside* ``libpancake_ocapn`` rather than instead of it). A
consumer that never speaks iroh imports only :mod:`pancake`; one that hosts or
explicitly dials over iroh adds this module. The transport-neutral dialer
:func:`pancake.connect` bridges them: it lives in the core and reaches in
here only when it parses an ``iroh`` locator, so the core never hard-depends on
the iroh artifact.

    server = listen_iroh(IrohConfig(Reachability.DIRECT))
    print(server.uri)                       # hand this to a partner
    async for conn in server:
        conn.serve()

The byte unit is identical to TCP's — the core's stream delimiter
(``pancake_host_session_feed_bytes``) owns framing — so the same byte-fed
:class:`pancake.Session` serve loop drives a session over it; only the
addressing differs, an endpoint id plus direct-address hints, no host:port.
The sidecar's loop surface (ADR-0057) is the netlayer's one I/O model:
:class:`_IrohLoop` registers the endpoint's single readiness fd with the
asyncio event loop (``add_reader``) and drains readiness records when it signals,
so one endpoint serves many connections at scale with no per-connection thread —
the parity with the Zig resident and the Deno binding that
``zig build python-iroh-loop`` proves."""

from __future__ import annotations

import asyncio
import contextlib
import ctypes
from dataclasses import dataclass
import enum
import secrets
from typing import Optional, Union

# The core binding owns the value vocabulary, the host/connection machinery, and
# the shared archives; the iroh transport plugs into that seam as the byte
# transport a `Session`'s serve loop reads. The raw iroh FFI loader behind
# ``_iroh()`` lives in the internal :mod:`pancake._ffi_iroh`.
from ._session import Session
from . import _constants as _c
from ._constants import ERR_CLOSED as _ERR_CLOSED, ERR_INVALID_ARGUMENT as _ERR_INVALID_ARGUMENT, HINT_DIRECT_ADDRESSES, OK as _OK, TRANSPORT_IROH, WOULD_BLOCK as _WOULD_BLOCK
from ._errors import PancakeError
from ._host import Host
from ._locator import encode_peer_locator, format_peer_uri
from ._ffi_ocapn import _byte_buf, _read_last_error
from ._ffi_iroh import _iroh, _IrohConfig, _IrohReadyEvent

# Readiness event bits (the header's PANCAKE_IROH_EV_*), carried by a
# `_IrohReadyEvent`; a record may carry several at once. Read from the generated
# constants directly rather than through the FFI loader, which only forwarded
# them.
# The discovery-posture dial retry budget (ADR-0082) is lockstep with
# ``PANCAKE_DISCOVERY_DIAL_*`` / ``driver.ResilientClient``.
from ._constants_gen import DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS
from ._constants_gen import (
    IROH_EV_ACCEPT as _IROH_EV_ACCEPT,
    IROH_EV_CLOSED as _IROH_EV_CLOSED,
    IROH_EV_CONNECT as _IROH_EV_CONNECT,
    IROH_EV_READABLE as _IROH_EV_READABLE,
    IROH_EV_WRITABLE as _IROH_EV_WRITABLE,
)

__all__ = [
    "Reachability",
    "IrohServer",
    "IrohNetlayer",
    "IrohConfig",
    "IrohConn",
    "listen_iroh",
    "dial_locator_for_relay",
]


def _iroh_last_error() -> "Optional[str]":
    """The calling thread's last error message from the iroh transport archive
    (``libpancake_net_transport_iroh``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so an iroh call's diagnostic is
    read here and never from the core family's :func:`pancake.last_error`."""
    return _read_last_error(_iroh().pancake_iroh_last_error)


def _check_iroh(code: int) -> None:
    # The iroh library carries its own thread-local last-error, so read this
    # archive's own slot rather than scraping libpancake_ocapn's unrelated one.
    if code != _OK:
        raise PancakeError(code, _iroh_last_error() or f"iroh transport call failed (code {code})")


class Reachability(enum.IntEnum):
    """An iroh endpoint's addressing posture — how it dials partners and how it
    is dialed. Every iroh constructor requires it explicitly; there is **no
    default**, because the right posture is a deployment decision (relay-less vs
    relayed, discovery vs none) and a hidden one would silently route — or refuse
    to route — a partner's traffic.

    ``DIRECT``
        Dial by endpoint id plus direct-address hints; relay-less, no discovery.
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


class IrohConn:
    """One iroh QUIC connection carrying one OCapN session, the iroh sibling of
    :class:`pancake.tcp.TcpEndpoint`. It is driven by an :class:`_IrohLoop`, which
    frames the raw bytes :meth:`try_read_into` hands out the same way the TCP pump
    frames its socket bytes. No call here ever parks on the connection, so a
    release never races a read."""

    def __init__(self, raw: ctypes.c_void_p) -> None:
        self._raw: ctypes.c_void_p | None = raw

    def key(self) -> int:
        """This connection's stable readiness identity."""
        return int(_iroh().pancake_iroh_conn_id(self._raw)) if self._raw else 0

    def remote_node_id(self) -> "str | None":
        """The far end's node id, as QUIC proved it: this connection completed
        only because the peer held the secret for this key. ``None`` when the
        connection is gone or the handshake proved nothing.

        This is the fact a session is otherwise missing. pancake cannot see it
        -- it did not open this connection -- so whoever did passes it on with
        :meth:`Session.bind_verified_channel_key`, which the accept and dial
        paths below do for every session this module establishes."""
        if not self._raw:
            return None
        cap = 64
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t(0)
        code = _iroh().pancake_iroh_conn_remote_node_id(
            self._raw, buf, cap, ctypes.byref(out_len),
        )
        if code != _OK:
            return None
        return buf.raw[:out_len.value].decode()

    def try_read_into(self, buf) -> int:
        """Non-blocking read of raw inbound bytes into the ctypes ``buf``: the
        byte count (>0), ``_WOULD_BLOCK`` when nothing is buffered yet,
        ``_ERR_CLOSED`` on a clean end of stream, or raises on a fault. The caller
        frames these bytes itself."""
        out = ctypes.c_size_t()
        rc = _iroh().pancake_iroh_conn_try_read(self._raw, buf, len(buf), ctypes.byref(out))
        if rc == _WOULD_BLOCK or rc == _ERR_CLOSED:
            return rc
        if rc != _OK:
            raise PancakeError(rc, _iroh_last_error() or f"iroh conn try_read failed (code {rc})")
        return out.value

    def try_write(self, frame: bytes) -> int:
        """Non-blocking write of ``frame``'s raw bytes: the count written (the
        whole slice, all-or-nothing), or ``_WOULD_BLOCK`` when the outbound buffer
        is at its bound (retry the same bytes after the next writable record).
        Raises on a fault."""
        buf = (ctypes.c_uint8 * len(frame)).from_buffer_copy(frame) if frame else (ctypes.c_uint8 * 0)()
        out = ctypes.c_size_t()
        rc = _iroh().pancake_iroh_conn_try_write(self._raw, buf, len(frame), ctypes.byref(out))
        if rc == _WOULD_BLOCK:
            return rc
        if rc != _OK:
            raise PancakeError(rc, _iroh_last_error() or f"iroh conn try_write failed (code {rc})")
        return out.value

    def __enter__(self) -> "IrohConn":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_conn_release(self._raw)
            self._raw = None


@dataclass(frozen=True)
class IrohConfig:
    """One iroh endpoint's configuration, field-for-field with the header's
    ``PancakeIrohConfig``, which documents what each setting means. ``None``
    for a timeout takes the transport's default.

    ``reachability`` is mandatory: enabling relays or a discovery service is
    always the caller's visible choice. ``connect_timeout_ms`` bounds getting a
    connection up, ``idle_timeout_ms`` bounds keeping one. Set
    ``idle_timeout_ms`` if you read a live session as presence, because it is
    what ends a connection whose peer was killed rather than closed.
    """

    reachability: "Union[int, Reachability]"
    connect_timeout_ms: "Optional[int]" = None
    idle_timeout_ms: "Optional[int]" = None


class IrohNetlayer:
    """A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
    sibling of :class:`pancake.tcp.TcpNetlayer`, and its own listener (there is no
    host:port, so :meth:`accept` lives here). Release every :class:`IrohConn` it
    mints before releasing it.

    ``reachability`` (a :class:`Reachability`) is required, it sets the
    endpoint's addressing posture and has no default."""

    def __init__(self, config: IrohConfig, secret_seed: "Optional[bytes]" = None):
        seed = secret_seed or b""
        # Empty means "draw a fresh random key"; keep the NULL the header
        # documents for that arm.
        buf, ptr = _byte_buf(seed) if seed else (None, None)
        out = ctypes.c_void_p()
        # Zero-initialized by `ctypes.Structure`, and 0 means the built-in
        # default for every timeout — the header's zero-init contract.
        cfg = _IrohConfig(reachability=int(config.reachability))
        if config.connect_timeout_ms is not None:
            cfg.connect_timeout_ms = config.connect_timeout_ms
        if config.idle_timeout_ms is not None:
            cfg.idle_timeout_ms = config.idle_timeout_ms
        _check_iroh(_iroh().pancake_iroh_netlayer_new(
            ptr, len(seed), ctypes.byref(cfg), ctypes.byref(out),
        ))
        self._raw: ctypes.c_void_p | None = out

    def node_id(self) -> str:
        """This endpoint's id, its Ed25519 public key as lowercase hex, the
        dialable designator a keyed locator signs."""
        cap = 64
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_node_id(self._raw, out, cap, ctypes.byref(n)))
        return ctypes.string_at(out, n.value).decode()

    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct socket addresses, the dialing
        hint a partner needs because the sidecar binds relay-less."""
        cap = 1024
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_direct_addrs(self._raw, out, cap, ctypes.byref(n)))
        return ctypes.string_at(out, n.value).decode()

    # ── The event-driven loop surface (ADR-0057) ────────────────────────────────
    # These back :class:`_IrohLoop`: the endpoint's one I/O model, serving many
    # connections from one readiness fd registered with the asyncio event loop.
    # The loop is armed when the netlayer is created, so these work immediately.

    def readiness_fd(self) -> int:
        """This endpoint's single readiness fd, register it with the event loop
        (``add_reader``) and call :meth:`drain_ready` when it signals. Owned by
        the netlayer; never close it."""
        fd = _iroh().pancake_iroh_netlayer_readiness_fd(self._raw)
        if fd < 0:
            raise PancakeError(fd, _iroh_last_error() or f"iroh readiness_fd failed (code {fd})")
        return fd

    def drain_ready(self, buf, cap: int) -> int:
        """Drain the pending readiness records into ``buf`` (a ``_IrohReadyEvent``
        array of ``cap`` entries) without blocking. Returns the record count (0
        when none); raises on fault. Call it when :meth:`readiness_fd` signals,
        then again until it returns fewer than ``cap`` records."""
        out = ctypes.c_size_t()
        rc = _iroh().pancake_iroh_netlayer_drain_ready(self._raw, buf, cap, ctypes.byref(out))
        if rc != _OK:
            raise PancakeError(rc, _iroh_last_error() or f"iroh drain_ready failed (code {rc})")
        return out.value

    def try_accept(self) -> "Optional[IrohConn]":
        """Claim one accepted non-blocking connection, or ``None`` when none is
        pending."""
        out = ctypes.c_void_p()
        code = _iroh().pancake_iroh_netlayer_try_accept(self._raw, ctypes.byref(out))
        if code == _WOULD_BLOCK:
            return None
        _check_iroh(code)
        return IrohConn(out)

    def start_connect(self, request_id: int, node_id: str, addr_hints: str) -> None:
        """Admit one dial without blocking; completion arrives as EV_CONNECT."""
        id_b = node_id.encode()
        hints_b = addr_hints.encode()
        id_buf, id_ptr = _byte_buf(id_b)
        hints_buf, hints_ptr = _byte_buf(hints_b)
        _check_iroh(_iroh().pancake_iroh_netlayer_start_connect(
            self._raw,
            request_id,
            id_ptr, len(id_b),
            hints_ptr, len(hints_b),
        ))
        _ = (id_buf, hints_buf)

    def finish_connect(self, request_id: int) -> IrohConn:
        out = ctypes.c_void_p()
        _check_iroh(_iroh().pancake_iroh_netlayer_finish_connect(
            self._raw, request_id,
            ctypes.byref(out),
        ))
        return IrohConn(out)

    def cancel_connect(self, request_id: int) -> None:
        _check_iroh(_iroh().pancake_iroh_netlayer_cancel_connect(self._raw, request_id))

    def __enter__(self) -> "IrohNetlayer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def close(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_netlayer_close(self._raw)

    def release(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_netlayer_release(self._raw)
            self._raw = None


# ── The iroh readiness dispatcher (ADR-0057) ────────────────────────────────

# How many readiness records one `drain_ready` call pulls. When the fd signals,
# the loop drains in a batch and re-drains until a short count, so a queue deeper
# than the cap is never stranded.
_DRAIN_READY_CAP = 64


class _ConnWaiters:
    """Per-connection readiness state. A loop connection is single-owner (one task
    drives it), so at most one task waits for readable and one for writable; a
    ``*_pending`` flag holds an edge that arrived before its waiter so no wakeup
    is lost."""

    __slots__ = ("conn", "readable", "writable", "readable_pending", "writable_pending", "closed")

    def __init__(self, conn: "IrohConn") -> None:
        self.conn = conn
        self.readable: "Optional[asyncio.Future]" = None
        self.writable: "Optional[asyncio.Future]" = None
        self.readable_pending = False
        self.writable_pending = False
        self.closed = False


class _IrohLoop:
    """The per-netlayer readiness dispatcher for the iroh loop surface (ADR-0057).

    It registers the netlayer's single readiness fd with the asyncio event loop
    (:meth:`asyncio.loop.add_reader`) and, when the fd signals, drains the pending
    readiness records and fans each out to the connection (or accept) waiting on
    it. Everything runs on the one event-loop thread — no dedicated thread, no
    cross-thread posting — and because the drain touches only the endpoint, never
    a per-connection buffer, a connection can be released at any time without
    racing a read. ``close`` removes the fd reader and wakes every waiter, so the
    caller can then free the netlayer with no callback still touching it.

    This is the Python sibling of the Deno binding's ``IrohLoop`` and Zig's
    ``completion.Loop(iroh.Backend)`` + ``driver.Bridge`` + ``driver_core.Host``:
    one reactor multiplexes many connections."""

    def __init__(self, netlayer: IrohNetlayer):
        self._netlayer = netlayer
        self._conns: "dict[int, _ConnWaiters]" = {}
        self._dials: "dict[int, asyncio.Future]" = {}
        self._next_request = 1
        self._accept_waiter: "Optional[asyncio.Future]" = None
        self._accept_pending = 0
        self._closed = False
        self._fd = -1
        self._aio_loop: "Optional[asyncio.AbstractEventLoop]" = None
        # Reused across `drain_ready` calls; owned by the event-loop thread.
        self._buf = (_IrohReadyEvent * _DRAIN_READY_CAP)()

    def start(self) -> None:
        """Register the readiness fd with the running event loop (idempotent)."""
        if self._aio_loop is None:
            self._aio_loop = asyncio.get_running_loop()
            self._fd = self._netlayer.readiness_fd()
            self._aio_loop.add_reader(self._fd, self._on_ready)

    def register(self, conn: IrohConn) -> None:
        self._conns[conn.key()] = _ConnWaiters(conn)

    async def dial(self, node_id: str, addr_hints: str) -> IrohConn:
        request_id = self._next_request
        self._next_request += 1
        fut = asyncio.get_running_loop().create_future()
        self._dials[request_id] = fut
        try:
            self._netlayer.start_connect(request_id, node_id, addr_hints)
        except BaseException:
            self._dials.pop(request_id, None)
            raise
        try:
            return await fut
        except asyncio.CancelledError:
            self._netlayer.cancel_connect(request_id)
            raise

    def unregister(self, conn: IrohConn) -> None:
        w = self._conns.pop(conn.key(), None)
        if w is not None:
            self._wake_closed(w)

    def wait_readable(self, conn: IrohConn) -> "asyncio.Future":
        """A future resolving ``True`` when this connection is readable, ``False``
        if it closed."""
        fut = asyncio.get_running_loop().create_future()
        w = self._conns.get(conn.key())
        if w is None or w.closed:
            fut.set_result(False)
        elif w.readable_pending:
            w.readable_pending = False
            fut.set_result(True)
        else:
            w.readable = fut
        return fut

    def wait_writable(self, conn: IrohConn) -> "asyncio.Future":
        """A future resolving ``True`` when this connection is writable, ``False``
        if it closed."""
        fut = asyncio.get_running_loop().create_future()
        w = self._conns.get(conn.key())
        if w is None or w.closed:
            fut.set_result(False)
        elif w.writable_pending:
            w.writable_pending = False
            fut.set_result(True)
        else:
            w.writable = fut
        return fut

    def next_accept(self) -> "asyncio.Future":
        """A future resolving ``True`` when an accepted connection may be claimed,
        ``False`` on close."""
        fut = asyncio.get_running_loop().create_future()
        if self._closed:
            fut.set_result(False)
        elif self._accept_pending > 0:
            self._accept_pending -= 1
            fut.set_result(True)
        else:
            self._accept_waiter = fut
        return fut

    def close(self) -> None:
        """Remove the fd reader, wake every waiter, and release every connection
        still registered here (TS ``IrohLoop.close`` parity). The caller releases
        the netlayer after this; each conn's own ``release`` is idempotent."""
        if self._closed:
            return
        self._closed = True
        if self._aio_loop is not None and self._fd >= 0:
            self._aio_loop.remove_reader(self._fd)
            self._fd = -1
        for w in list(self._conns.values()):
            self._wake_closed(w)
            w.conn.release()
        self._conns.clear()
        for request_id, fut in list(self._dials.items()):
            self._netlayer.cancel_connect(request_id)
            if not fut.done():
                fut.set_exception(PancakeError(_ERR_CLOSED, "iroh loop closed"))
        self._dials.clear()
        if self._accept_waiter is not None:
            a = self._accept_waiter
            self._accept_waiter = None
            if not a.done():
                a.set_result(False)

    def _wake_closed(self, w: _ConnWaiters) -> None:
        w.closed = True
        for attr in ("readable", "writable"):
            fut = getattr(w, attr)
            if fut is not None:
                setattr(w, attr, None)
                if not fut.done():
                    fut.set_result(False)

    def _on_ready(self) -> None:
        # The event loop calls this on the loop thread whenever the readiness fd
        # signals. Drain the queue in batches until a short count (a deeper queue
        # than one drain holds is never stranded), dispatching each record. A
        # fault means the endpoint was closed under us, stop watching the fd.
        if self._closed:
            return
        while True:
            try:
                n = self._netlayer.drain_ready(self._buf, _DRAIN_READY_CAP)
            except Exception:
                if self._aio_loop is not None and self._fd >= 0:
                    self._aio_loop.remove_reader(self._fd)
                    self._fd = -1
                return
            for i in range(n):
                self._dispatch(self._buf[i].subject, self._buf[i].events)
            if n < _DRAIN_READY_CAP:
                return

    def _dispatch(self, subject: int, events: int) -> None:
        if events & _IROH_EV_ACCEPT:
            if self._accept_waiter is not None:
                a = self._accept_waiter
                self._accept_waiter = None
                if not a.done():
                    a.set_result(True)
            else:
                self._accept_pending += 1
            return
        if events & _IROH_EV_CONNECT:
            fut = self._dials.pop(subject, None)
            try:
                conn = self._netlayer.finish_connect(subject)
            except BaseException as exc:
                if fut is not None and not fut.done():
                    fut.set_exception(exc)
                return
            if fut is None or fut.done():
                conn.release()
            else:
                fut.set_result(conn)
            return
        w = self._conns.get(subject)
        if w is None:
            return  # a record for an already-released connection
        if events & _IROH_EV_CLOSED:
            w.closed = True
        if events & (_IROH_EV_READABLE | _IROH_EV_CLOSED):
            if w.readable is not None:
                fut = w.readable
                w.readable = None
                if not fut.done():
                    fut.set_result(not w.closed)
            else:
                w.readable_pending = True
        if events & (_IROH_EV_WRITABLE | _IROH_EV_CLOSED):
            if w.writable is not None:
                fut = w.writable
                w.writable = None
                if not fut.done():
                    fut.set_result(not w.closed)
            else:
                w.writable_pending = True


class _IrohTransport:
    """The iroh transport: a non-blocking :class:`IrohConn` driven by an
    :class:`_IrohLoop` (ADR-0057), reshaped into the byte transport a
    :class:`pancake.Session`'s serve loop reads. ``read`` sources raw
    inbound bytes through the sidecar's non-blocking ``try_read`` — the
    readiness loop, not a parked blocking read, decides when bytes are
    available — and the host's stream delimiter frames them above. ``write``
    goes through the non-blocking ``try_write``, re-arming on the next writable
    record when the sidecar buffer is full (the serve loop's FLUSH drain
    serializes the writes, so the retry never interleaves frames). The write
    contract every transport record shares: ``write()`` moves bytes only — it
    must not call host verbs or feed a connection, because it runs under the
    connection's ``_write_lock`` and a reentrant flush would deadlock or
    interleave frames.

    Lifetime: a server-accepted transport borrows the server's loop and
    netlayer; a dialing transport minted its own netlayer and loop
    (``owns_loop``) and tears both down on close, in the load-bearing order —
    unregister, release the connection, close the loop, release the netlayer —
    so no callback still touches the endpoint when it is freed. No call ever
    parks on this connection, so ``close`` cannot race a parked read."""

    _READ_CHUNK = 65536

    def __init__(
        self,
        conn: IrohConn,
        loop: _IrohLoop,
        owned_netlayer: "Optional[IrohNetlayer]" = None,
        owns_loop: bool = False,
    ):
        self._conn = conn
        self._loop = loop
        self._owns_loop = owns_loop
        self._owned_netlayer = owned_netlayer
        self._read_buf = (ctypes.c_uint8 * self._READ_CHUNK)()
        self._closed = False

    async def read(self) -> "Optional[bytes]":
        while True:
            # Drain every byte currently available (the readiness signal is
            # edge-ish, so leaving bytes buffered in the sidecar could stall
            # until fresh data); the chunks are copied out so the read buffer
            # can be reused by the next read.
            chunks: "list[bytes]" = []
            while True:
                n = self._conn.try_read_into(self._read_buf)
                if n == _WOULD_BLOCK:
                    break
                if n == _ERR_CLOSED:
                    # Drained, then a clean end of stream: hand back what
                    # arrived first; the next read reports the close.
                    return b"".join(chunks) if chunks else None
                chunks.append(ctypes.string_at(self._read_buf, n))
            if chunks:
                return b"".join(chunks)
            # Nothing buffered yet: park on this connection's readiness, not a
            # wire read. False means it was released/closed under us.
            if not await self._loop.wait_readable(self._conn):
                return None

    async def write(self, data: bytes) -> None:
        while True:
            n = self._conn.try_write(data)
            if n != _WOULD_BLOCK:
                return  # the whole slice went (all-or-nothing)
            if not await self._loop.wait_writable(self._conn):
                raise PancakeError(_ERR_CLOSED, "iroh connection closed while writing")

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        # Drop the routing entry first so no further readiness record resolves
        # a waiter on this connection, then free the sidecar connection (no
        # call parks on it, so the release cannot race a read).
        self._loop.unregister(self._conn)
        self._conn.release()
        if self._owns_loop:
            # The dialing transport owns the loop and netlayer: close the loop
            # (removing the readiness-fd reader and waking every waiter) before
            # releasing the netlayer, so no callback still touches the endpoint
            # when it is freed.
            self._loop.close()
            if self._owned_netlayer is not None:
                self._owned_netlayer.release()


_DISCOVERY_DIAL_RETRY_S = DISCOVERY_DIAL_RETRY_MS / 1000.0


async def _dial_resolving(loop: _IrohLoop, node_id: str, direct_addresses: str, retry: bool) -> IrohConn:
    """Dial, retrying only under a propagating-discovery posture (``DISCOVERY`` and
    ``DISCOVERY_NO_RELAY``) while it resolves the partner by id. A dial-by-id can
    fail with "no addressing information" until the exporter's pkarr record
    propagates to the n0 resolver (seconds, variable); every other posture dials
    once (Direct's addresses are in hand, local_discovery resolves instantly).
    Mirrors the TS ``dialResolving`` and the Zig ``iroh-reachability`` driver.

    ADR-0082: only transient dial faults (projected as ``ERR_IO``) are retried;
    permanent faults (``ERR_INVALID_ARGUMENT``, ``ERR_INTERNAL``, …) surface
    immediately.
    """
    from ._errors import PancakeError
    from ._constants_gen import ERR_IO

    attempt = 1
    while True:
        try:
            return await loop.dial(node_id, direct_addresses)
        except PancakeError as e:
            if e.code != ERR_IO or not retry or attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS:
                raise
        except Exception:
            raise
        attempt += 1
        await asyncio.sleep(_DISCOVERY_DIAL_RETRY_S)


async def _connect_iroh_with_host(
    node_id: str,
    direct_addresses: str,
    reachability: "Union[int, Reachability]",
    host: Host,
    handshake_timeout_ms: "Optional[int]" = _c.HANDSHAKE_TIMEOUT_MS,
) -> Session:
    """Binding-internal Host-keyed iroh dial behind a handoff redeem.
    Application code uses ``connect(locator, reachability, host=…)``."""
    netlayer = IrohNetlayer(IrohConfig(reachability))
    loop = _IrohLoop(netlayer)
    loop.start()
    try:
        conn = await _dial_resolving(
            loop, node_id, direct_addresses,
            int(reachability) in (int(Reachability.DISCOVERY), int(Reachability.DISCOVERY_NO_RELAY)),
        )
    except BaseException:
        loop.close()
        netlayer.release()
        raise
    loop.register(conn)
    # The transport owns the dialer-minted connection, loop, and ephemeral
    # netlayer; on a handshake failure `establish_dialed_locator` abandons the
    # half-built connection, and its transport close is what unregisters and
    # releases the sidecar connection, stops the readiness loop, and releases
    # the netlayer. The session is minted against `host`, so the session's
    # identity (a give's recipient key) and the Host's session directory agree —
    # what a three-party handoff requires.
    transport = _IrohTransport(conn, loop, netlayer, owns_loop=True)
    # `handshake_timeout_ms` bounds only the keyed exchange over the live QUIC
    # connection, which is one round trip: resolving a node id over discovery
    # and hole-punching a path is `_dial_resolving`'s own retry budget above,
    # already finished by the time the handshake starts.
    try:
        # This module opened the connection, so it is the one place that can
        # say what QUIC proved about the far end.
        return await Session.establish_dialed_locator(
            host, TRANSPORT_IROH, node_id, transport, handshake_timeout_ms,
            conn.remote_node_id(),
        )
    except BaseException:
        # establish can fail after register; close the transport so the conn,
        # loop, and netlayer never leak without an owner.
        with contextlib.suppress(Exception):
            transport.close()
        raise


async def dial_locator_for_relay(locator: str, reachability: "Union[int, Reachability]") -> "_IrohTransport":
    """Dial an iroh ``ocapn://`` locator to a raw byte channel for a
    byte-transparent relay: no CapTP handshake, since the relay only pipes bytes
    and the two ends key the session end to end. This is the Python parallel to
    the TypeScript ``dialLocatorForRelay``; the iroh readiness compose lives in
    each binding, over the same C-ABI conn and readiness primitives, exactly as
    the iroh serve loop does.

    Returns an ``_IrohTransport`` (``async read() -> bytes | None``,
    ``async write(bytes)``, ``close()``). ``close`` unregisters the connection,
    stops the readiness loop, and releases the ephemeral netlayer it minted."""
    from ._locator import parse_locator

    parsed = parse_locator(locator)
    if parsed.transport != TRANSPORT_IROH:
        raise ValueError(f"expected an iroh locator, got transport {parsed.transport!r}")
    node_id = parsed.designator
    direct_addresses = parsed.hints.get(HINT_DIRECT_ADDRESSES, "")

    netlayer = IrohNetlayer(IrohConfig(reachability))
    loop = _IrohLoop(netlayer)
    loop.start()
    try:
        conn = await _dial_resolving(
            loop,
            node_id,
            direct_addresses,
            int(reachability) in (int(Reachability.DISCOVERY), int(Reachability.DISCOVERY_NO_RELAY)),
        )
    except BaseException:
        loop.close()
        netlayer.release()
        raise
    loop.register(conn)
    return _IrohTransport(conn, loop, netlayer, owns_loop=True)


async def _accept_iroh(
    conn: IrohConn,
    local_node_id: str,
    direct_addresses: str,
    loop: _IrohLoop,
    host: Host,
) -> Session:
    """Complete the responder handshake over an accepted iroh connection, signing
    the server's endpoint id as the locator designator (used by
    :class:`IrohServer`). The accepted connection's loop and netlayer belong to
    the server, not this connection. It is bound to the server's one ``host``
    — shared identity and handoff router — and every node-giftable is published
    on it by the open itself, before a dialer's pipelined fetch is answered
    (the exporter half of a three-party handoff, ADR-0009), exactly as the TCP
    responder does."""
    # As the dial side: this module accepted the connection, so it is the one
    # place that can say what QUIC proved about the peer that reached it.
    return await Session.establish_accepted(
        host, TRANSPORT_IROH, local_node_id, _IrohTransport(conn, loop),
        accepted_local_addr=direct_addresses,
        verified_channel_key=conn.remote_node_id(),
    )


class IrohServer:
    """A listening iroh endpoint — the iroh sibling of :class:`pancake.Server`.
    Async-iterable (``async for conn in server``) for an accepted
    :class:`pancake.Session` per partner; read :attr:`uri` for the dialable
    address (endpoint id + direct-address hints) to hand a client.
    ``reachability`` (a :class:`Reachability`) is required and sets the endpoint's
    addressing posture — there is no default. Needs the iroh ABI library
    (``zig build iroh-abi``).

    One seed drives both the iroh endpoint and the :class:`Host`: the node id,
    the locator designator, and the session signing key are one value
    (ADR-0075). Pass the same seed after a restart to keep the designator
    stable."""

    def __init__(
        self,
        config: IrohConfig,
        secret_seed: "Optional[bytes]" = None,
        host: "Optional[Host]" = None,
    ):
        if secret_seed is not None and len(secret_seed) != 32:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "listen_iroh: secret_seed must be 32 bytes")
        if host is not None and secret_seed is not None and host.seed != secret_seed:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "listen_iroh: host seed must match secret_seed (one identity for endpoint and Host)",
            )
        # One seed for the endpoint and the Host — never mint a fresh Host
        # beside a different endpoint key (rooms Deno / Zig interop pattern).
        seed = secret_seed if secret_seed is not None else (
            host.seed if host is not None else secrets.token_bytes(32)
        )
        self._netlayer = IrohNetlayer(config, seed)
        self._node_id = self._netlayer.node_id()
        # Serve every accepted connection from one readiness loop instead of a
        # blocking accept and a blocking read parked per connection (ADR-0057).
        self._loop = _IrohLoop(self._netlayer)
        # One shared Host across every accepted session — one retained
        # identity and one live-session directory — the iroh sibling of the TCP
        # :class:`pancake.Server`. The gifter half of a three-party handoff dials
        # the exporter under this same Host (:func:`pancake.connect` with ``host=``)
        # so a published node-giftable and the introducer it returns share one
        # Host (ADR-0009/ADR-0056).
        self._host = host if host is not None else Host(seed=seed)
        # Dials from this Host sign the endpoint's own id so a partner's
        # crossed-hellos table can recognize it.
        self._host.set_self_designator(self._node_id)
        self._advertised_direct_addresses: Optional[str] = None
        self._refresh_advertised_locator()
        self._closed = False
        # Accepted sessions still borrow the endpoint through their loop
        # connections; release them before the netlayer.
        self._sessions: list[Session] = []

    @property
    def node_id(self) -> str:
        """This endpoint's id, the keyed locator designator and the URI host."""
        return self._node_id

    @property
    def host(self) -> Host:
        """The server's shared Host: one retained identity and handoff router
        across every accepted session. Pass it to
        :func:`pancake.connect` with ``host=self.host`` so a fetched capability and the dialing
        session share one Host — the gifter side of a three-party handoff —
        and publish a host-giftable on it with :meth:`Host.publish_giftable`."""
        return self._host

    @property
    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct-address hints."""
        return self._refresh_advertised_locator()

    def _refresh_advertised_locator(self) -> str:
        direct_addresses = self._netlayer.direct_addresses()
        if direct_addresses != self._advertised_direct_addresses:
            self._host.set_advertised_locator(encode_peer_locator(
                TRANSPORT_IROH, self._node_id, direct_addresses,
            ))
            self._advertised_direct_addresses = direct_addresses
        return direct_addresses

    @property
    def uri(self) -> str:
        """The ``ocapn://<nodeid>.iroh?direct-addresses=…`` URI a partner dials."""
        hints = {HINT_DIRECT_ADDRESSES: self.direct_addresses} if self.direct_addresses else None
        return format_peer_uri(TRANSPORT_IROH, self._node_id, hints)

    def __aiter__(self) -> "IrohServer":
        return self

    async def __anext__(self) -> "Session":
        self._loop.start()
        while True:
            if self._closed:
                raise StopAsyncIteration
            conn = self._netlayer.try_accept()
            if conn is None:
                # Nothing pending: wait for the loop's next accept record. A
                # False resolution means the server is closing.
                if not await self._loop.next_accept():
                    raise StopAsyncIteration
                continue
            self._loop.register(conn)
            # A handshake failure belongs to that one connection (a partner that
            # dialed and died, or one that opened its stream and then said
            # nothing, which `Session.establish_accepted` bounds), never the
            # server, release it and keep accepting. The sidecar's own
            # `connect_timeout` bounds only the QUIC `accept_bi` below it, not
            # the OCapN handshake over the accepted stream.
            try:
                session = await _accept_iroh(
                    conn, self._node_id, self.direct_addresses, self._loop, self._host,
                )
            except Exception:
                self._loop.unregister(conn)
                conn.release()
                continue
            self._sessions.append(session)
            return session

    async def close(self) -> None:
        """Stop accepting and release the endpoint. Closes every accepted
        session (so each loop conn is released), then the readiness loop and
        netlayer — never free the netlayer while a conn still points at it."""
        if self._closed:
            return
        self._closed = True
        sessions = self._sessions
        self._sessions = []
        for session in sessions:
            with contextlib.suppress(Exception):
                await session.close()
        self._netlayer.close()
        self._loop.close()
        self._netlayer.release()

    async def __aenter__(self) -> "IrohServer":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()


def listen_iroh(
    config: IrohConfig,
    secret_seed: "Optional[bytes]" = None,
    host: "Optional[Host]" = None,
) -> IrohServer:
    """Bind an iroh endpoint and return an :class:`IrohServer` you iterate for
    each accepted :class:`pancake.Session`. ``reachability`` (a
    :class:`Reachability`) is required and sets the endpoint's addressing
    posture. There is no default. ``secret_seed`` is a 32-byte Ed25519 secret
    for a stable endpoint id, or ``None`` for a fresh random one shared with
    the :class:`Host`. Pass ``host`` only when it was built from the same seed
    (one identity for netlayer and session). ``config`` carries the endpoint's
    timeouts (see :class:`IrohConfig`); a server that treats a live session as
    presence should set ``idle_timeout_ms``, because that is what ends a
    connection whose peer was killed rather than closed. Needs the iroh ABI
    library (``zig build iroh-abi``)."""
    return IrohServer(config, secret_seed, host)
