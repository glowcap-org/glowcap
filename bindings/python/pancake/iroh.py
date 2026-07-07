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

    server = listen_iroh(Reachability.DIRECT)
    print(server.uri)                       # hand this to a partner
    async for conn in server:
        conn.serve()

The frame unit is identical to TCP's, so the same peer machinery drives a session
over it; only the addressing differs — an endpoint id plus direct-address hints,
no host:port. The sidecar's loop surface (ADR-0057) is the netlayer's one I/O
model: :class:`_IrohLoop` registers the endpoint's single readiness fd with the
asyncio event loop (``add_reader``) and drains readiness records when it signals,
so one endpoint serves many connections at scale with no per-connection thread —
the parity with the Zig resident and the Deno binding that
``zig build python-iroh-loop`` proves."""

from __future__ import annotations

import asyncio
import ctypes
import enum
from typing import Optional, Union

# The core binding owns the value vocabulary, the peer/connection machinery, and
# the libpancake_ocapn handle; the iroh transport plugs into that seam. The raw iroh
# FFI loader behind ``_iroh()`` lives in the internal :mod:`pancake._ffi_iroh`.
from . import (
    AsyncConnection,
    Connection,
    Node,
    Peer,
    PancakeError,
    _ERR_CLOSED,
    _FramePump,
    _KeyedLocator,
    _OK,
    _WOULD_BLOCK,
    _open_keyed_session,
    format_peer_uri,
)
from ._ffi_iroh import (
    _iroh,
    _IrohReadyEvent,
    _IROH_EV_ACCEPT,
    _IROH_EV_CLOSED,
    _IROH_EV_READABLE,
    _IROH_EV_WRITABLE,
)

__all__ = [
    "Reachability",
    "IrohServer",
    "IrohNetlayer",
    "IrohConn",
    "listen_iroh",
    "connect_iroh",
    "connect_iroh_with_node",
]


def _iroh_last_error() -> "Optional[str]":
    """The calling thread's last error message from the iroh transport archive
    (``libpancake_net_transport_iroh``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so an iroh call's diagnostic is
    read here and never from the core family's :func:`pancake.last_error`."""
    length = _iroh().pancake_iroh_last_error(None, 0)
    if length == 0:
        return None
    buf = (ctypes.c_uint8 * (length + 1))()
    _iroh().pancake_iroh_last_error(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


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

    ``DIRECT`` (0)
        Dial by endpoint id plus direct-address hints; relay-less, no discovery.
        A URI must carry ``direct-addresses``. This is the rooms demo's posture.
    ``DISCOVERY`` (1)
        Use the n0 relays and DNS discovery, so a partner is dialable by
        endpoint id alone.
    ``DISCOVERY_NO_RELAY`` (2)
        Use DNS discovery, but no relays.
    ``LOCAL_DISCOVERY`` (3)
        Use an in-process address book, for tests and same-process peers.
    """

    DIRECT = 0
    DISCOVERY = 1
    DISCOVERY_NO_RELAY = 2
    LOCAL_DISCOVERY = 3


class IrohConn:
    """One iroh QUIC connection carrying one OCapN session, the iroh sibling of
    :class:`pancake.tcp.TcpEndpoint`. It is driven by an :class:`_IrohLoop`, which
    frames the raw bytes :meth:`try_read_into` hands out the same way the TCP pump
    frames its socket bytes. No call here ever parks on the connection, so a
    release never races a read."""

    def __init__(self, raw):
        self._raw = raw

    def key(self) -> int:
        """This connection's routing key — its raw handle as an int, the value a
        ``drain_ready`` record carries — so an :class:`_IrohLoop` can map a
        readiness record back to this connection."""
        return self._raw.value if self._raw else 0

    def try_read_into(self, buf) -> int:
        """Non-blocking read of raw inbound bytes into the ctypes ``buf``: the
        byte count (>0), ``_WOULD_BLOCK`` when nothing is buffered yet,
        ``_ERR_CLOSED`` on a clean end of stream, or raises on a fault. The caller
        frames these bytes itself."""
        n = _iroh().pancake_iroh_conn_try_read(self._raw, buf, len(buf))
        if n == _WOULD_BLOCK or n == _ERR_CLOSED:
            return n
        if n < 0:
            raise PancakeError(n, _iroh_last_error() or f"iroh conn try_read failed (code {n})")
        return n

    def try_write(self, frame: bytes) -> int:
        """Non-blocking write of ``frame``'s raw bytes: the count written (the
        whole slice, all-or-nothing), or ``_WOULD_BLOCK`` when the outbound buffer
        is at its bound (retry the same bytes after the next writable record).
        Raises on a fault."""
        buf = (ctypes.c_uint8 * len(frame)).from_buffer_copy(frame) if frame else (ctypes.c_uint8 * 0)()
        n = _iroh().pancake_iroh_conn_try_write(self._raw, buf, len(frame))
        if n == _WOULD_BLOCK:
            return n
        if n < 0:
            raise PancakeError(n, _iroh_last_error() or f"iroh conn try_write failed (code {n})")
        return n

    def __enter__(self) -> "IrohConn":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_conn_release(self._raw)
            self._raw = None


class IrohNetlayer:
    """A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
    sibling of :class:`pancake.tcp.TcpNetlayer`, and its own listener (there is no
    host:port, so :meth:`accept` lives here). Release every :class:`IrohConn` it
    mints before releasing it.

    ``reachability`` (a :class:`Reachability`) is required, it sets the
    endpoint's addressing posture and has no default."""

    def __init__(self, reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None):
        if secret_seed is not None and len(secret_seed) != 32:
            raise ValueError("an iroh secret seed must be 32 bytes")
        seed = secret_seed or b""
        buf = ctypes.create_string_buffer(seed, len(seed)) if seed else None
        out = ctypes.c_void_p()
        _check_iroh(_iroh().pancake_iroh_netlayer_new(
            ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None, len(seed),
            int(reachability), ctypes.byref(out),
        ))
        self._raw = out

    def node_id(self) -> str:
        """This endpoint's id, its Ed25519 public key as lowercase hex, the
        dialable designator a keyed locator signs."""
        cap = 64
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_node_id(self._raw, out, cap, ctypes.byref(n)))
        return bytes(out[: n.value]).decode()

    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct socket addresses, the dialing
        hint a partner needs because the sidecar binds relay-less."""
        cap = 1024
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_direct_addrs(self._raw, out, cap, ctypes.byref(n)))
        return bytes(out[: n.value]).decode()

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
        n = _iroh().pancake_iroh_netlayer_drain_ready(self._raw, buf, cap)
        if n < 0:
            raise PancakeError(n, _iroh_last_error() or f"iroh drain_ready failed (code {n})")
        return n

    def try_accept(self) -> "Optional[IrohConn]":
        """Claim one accepted non-blocking connection, or ``None`` when none is
        pending."""
        out = ctypes.c_void_p()
        code = _iroh().pancake_iroh_netlayer_try_accept(self._raw, ctypes.byref(out))
        if code == _WOULD_BLOCK:
            return None
        _check_iroh(code)
        return IrohConn(out)

    def try_connect(self, node_id: str, addr_hints: str) -> IrohConn:
        """Dial a partner and return a non-blocking loop connection. The dial
        itself blocks the calling thread (run it off the event loop); subsequent
        frame I/O is non-blocking."""
        id_b = node_id.encode()
        hints_b = addr_hints.encode()
        id_buf = ctypes.create_string_buffer(id_b, len(id_b))
        hints_buf = ctypes.create_string_buffer(hints_b, len(hints_b))
        out = ctypes.c_void_p()
        _check_iroh(_iroh().pancake_iroh_netlayer_try_connect(
            self._raw,
            ctypes.cast(id_buf, ctypes.c_void_p), len(id_b),
            ctypes.cast(hints_buf, ctypes.c_void_p), len(hints_b),
            ctypes.byref(out),
        ))
        return IrohConn(out)

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

    __slots__ = ("readable", "writable", "readable_pending", "writable_pending", "closed")

    def __init__(self) -> None:
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

    This is the Python sibling of the Deno binding's ``IrohLoop`` and the Zig
    resident's ``LoopHost``: one reactor multiplexes many connections."""

    def __init__(self, netlayer: IrohNetlayer):
        self._netlayer = netlayer
        self._conns: "dict[int, _ConnWaiters]" = {}
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
        self._conns[conn.key()] = _ConnWaiters()

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

    async def close(self) -> None:
        """Remove the fd reader and wake every waiter so parked pumps unwind. The
        caller releases the netlayer after this, no callback still touches it."""
        if self._closed:
            return
        self._closed = True
        if self._aio_loop is not None and self._fd >= 0:
            self._aio_loop.remove_reader(self._fd)
            self._fd = -1
        for w in self._conns.values():
            self._wake_closed(w)
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
                self._dispatch(self._buf[i].conn, self._buf[i].events)
            if n < _DRAIN_READY_CAP:
                return

    def _dispatch(self, conn_ptr: "Optional[int]", events: int) -> None:
        if events & _IROH_EV_ACCEPT:
            if self._accept_waiter is not None:
                a = self._accept_waiter
                self._accept_waiter = None
                if not a.done():
                    a.set_result(True)
            else:
                self._accept_pending += 1
            return
        w = self._conns.get(conn_ptr or 0)
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


class _IrohLoopPump(_FramePump):
    """The iroh pump: a non-blocking :class:`IrohConn` driven by an
    :class:`_IrohLoop` (ADR-0057). It sources raw inbound bytes through the
    sidecar's non-blocking ``try_read``, buffers them, and lets the peer frame
    them, exactly like the TCP pump, since the frame unit is identical; the
    readiness loop, not a parked blocking read, decides when bytes are available.
    Outbound frames go through the non-blocking ``try_write``, re-arming on the
    next writable record if the sidecar buffer is full. The keyed locator signs
    the ``iroh`` transport with the local endpoint id as designator (empty for a
    dialer, matching the Zig driver).

    Lifetime: a server-accepted pump borrows the server's loop and netlayer; a
    dialing pump minted its own netlayer and loop (``owns_loop``) and tears both
    down on close. No call ever parks on this connection, so ``close`` cannot race
    a parked read, the teardown hazard the blocking pump had."""

    _READ_CHUNK = 65536

    def __init__(
        self,
        conn: IrohConn,
        designator: str,
        loop: _IrohLoop,
        owned_netlayer: "Optional[IrohNetlayer]" = None,
        owns_loop: bool = False,
    ):
        self._conn = conn
        self._designator = designator
        self._loop = loop
        self._owns_loop = owns_loop
        self._owned_netlayer = owned_netlayer
        self._inbox = bytearray()
        self._read_buf = (ctypes.c_uint8 * self._READ_CHUNK)()
        # See _TcpPump: a burst is copied into `_cache` once and walked by `_off`,
        # not recopied per frame. While `_cache` is live `_inbox` is untouched.
        self._cache: Optional["ctypes.Array"] = None
        self._off = 0

    def locator(self) -> _KeyedLocator:
        return _KeyedLocator("iroh", self._designator)

    def dispatch_buffered(self, peer: Peer) -> bool:
        if self._cache is None:
            if not self._inbox:
                return False
            self._cache = (ctypes.c_uint8 * len(self._inbox)).from_buffer_copy(self._inbox)
            self._off = 0
        consumed = peer.recv_stream_at(self._cache, self._off, len(self._cache) - self._off)
        if consumed is None:
            return False
        self._off += consumed
        return True

    async def receive(self, peer: Peer) -> bool:
        # Drop the dispatched prefix and invalidate the cache before appending, so
        # the next dispatch recopies only the true remainder (tail + new bytes).
        if self._cache is not None:
            del self._inbox[: self._off]
            self._cache = None
            self._off = 0
        while True:
            # Drain every byte currently available (the readiness signal is
            # edge-ish, so leaving bytes buffered in the sidecar could stall until
            # fresh data), then frame them above.
            got = False
            while True:
                n = self._conn.try_read_into(self._read_buf)
                if n == _WOULD_BLOCK:
                    break
                if n == _ERR_CLOSED:
                    return got  # drained, then a clean end of stream
                self._inbox.extend(bytes(self._read_buf[:n]))
                got = True
            if got:
                return True
            # Nothing buffered yet: park on this connection's readiness, not a
            # wire read. False means the connection was released/closed under us.
            if not await self._loop.wait_readable(self._conn):
                return False

    async def write_frame(self, frame: bytes) -> None:
        while True:
            n = self._conn.try_write(frame)
            if n != _WOULD_BLOCK:
                return  # the whole frame went (all-or-nothing)
            if not await self._loop.wait_writable(self._conn):
                raise PancakeError(_ERR_CLOSED, "iroh connection closed while writing")

    def shutdown(self) -> bool:
        # No parked worker-thread read to close: the receive parks on a future the
        # loop resolves. Dropping the routing entry wakes that waiter with a clean
        # end, so the inbound loop unwinds, the unblock half of teardown.
        self._loop.unregister(self._conn)
        return True

    async def close(self) -> None:
        # The routing entry is already dropped by `shutdown`; releasing the
        # connection is safe because no call parks on it.
        self._loop.unregister(self._conn)
        self._conn.release()
        if self._owns_loop:
            # The dialing pump owns the loop and netlayer: close the loop
            # (removing the readiness-fd reader and waking every waiter) before
            # releasing the netlayer, so no callback still touches the endpoint
            # when it is freed.
            await self._loop.close()
            if self._owned_netlayer is not None:
                self._owned_netlayer.release()


# The discovery-posture dial retry budget: how long pkarr propagation is given
# before each retry, and how many attempts (~72s total, covering n0 DNS/pkarr
# propagation). Matches the TS ``dialResolving`` budget.
_DISCOVERY_DIAL_RETRY_S = 3.0
_DISCOVERY_DIAL_MAX_ATTEMPTS = 24


async def _dial_resolving(netlayer: IrohNetlayer, node_id: str, direct_addresses: str, retry: bool) -> IrohConn:
    """Dial, retrying only under a propagating-discovery posture (``DISCOVERY`` and
    ``DISCOVERY_NO_RELAY``) while it resolves the partner by id. A dial-by-id can
    fail with "no addressing information" until the exporter's pkarr record
    propagates to the n0 resolver (seconds, variable); every other posture dials
    once (Direct's addresses are in hand, local_discovery resolves instantly).
    Mirrors the TS ``dialResolving`` and the Zig ``iroh-reachability`` driver."""
    attempt = 1
    while True:
        try:
            return await asyncio.to_thread(netlayer.try_connect, node_id, direct_addresses)
        except Exception:
            if not retry or attempt >= _DISCOVERY_DIAL_MAX_ATTEMPTS:
                raise
        attempt += 1
        await asyncio.sleep(_DISCOVERY_DIAL_RETRY_S)


async def _dial_iroh_ac(node_id: str, direct_addresses: str, reachability: "Union[int, Reachability]", peer: Peer) -> AsyncConnection:
    """Dial an iroh endpoint and return the :class:`AsyncConnection` over an
    ephemeral, self-owned netlayer + readiness loop (ADR-0057), before the keyed
    handshake, driving the node-owned ``peer`` (ADR-0066). Shared by
    :func:`connect_iroh` (a fresh node) and :func:`connect_iroh_with_node` (a
    handoff redeem under a shared node)."""
    netlayer = IrohNetlayer(reachability)
    loop = _IrohLoop(netlayer)
    try:
        conn = await _dial_resolving(
            netlayer, node_id, direct_addresses,
            int(reachability) in (int(Reachability.DISCOVERY), int(Reachability.DISCOVERY_NO_RELAY)),
        )
    except BaseException:
        await loop.close()
        netlayer.release()
        raise
    loop.register(conn)
    loop.start()
    # A dialer signs an empty designator (its identity is the session key),
    # matching the Zig driver; the pump owns the ephemeral netlayer and loop.
    return AsyncConnection.from_pump(peer, _IrohLoopPump(conn, "", loop, netlayer, owns_loop=True))


async def connect_iroh(node_id: str, direct_addresses: str, reachability: "Union[int, Reachability]") -> Connection:
    """Dial an iroh partner by endpoint id and direct-address hints, complete the
    keyed OCapN handshake over the encrypted-QUIC transport, and return a ready
    :class:`pancake.Connection` — the iroh sibling of :func:`pancake.connect`.
    The local endpoint is ephemeral (a fresh key) and released with the
    connection, and it is driven by its own readiness loop (ADR-0057).
    ``reachability`` (a :class:`Reachability`) sets the ephemeral dialer's posture
    and is required — there is no default. This is what :func:`pancake.connect`
    calls for an ``iroh`` locator. Needs the iroh ABI library
    (``zig build iroh-abi``).

    The fresh node's session key and its node identity are one and the same
    seed, so the connection's wire identity stays coherent, a handoff this node
    later redeems signs its ``desc:handoff-receive`` with the very key the gifter
    recorded, exactly as the TCP dialer does."""
    return await connect_iroh_with_node(node_id, direct_addresses, reachability, Node())


async def connect_iroh_with_node(
    node_id: str,
    direct_addresses: str,
    reachability: "Union[int, Reachability]",
    node: Node,
) -> Connection:
    """The node-keyed iroh dial behind a handoff redeem: bring the connection
    up under ``node`` rather than a fresh node, so the redeemed capability and
    any further handoff it triggers share the recipient's one identity and gift
    registry (ADR-0009/ADR-0056), the iroh sibling of the TCP redeem's shared
    node. Needs the iroh ABI library (``zig build iroh-abi``)."""
    conn_id, peer = node.register_conn()
    try:
        ac = await _dial_iroh_ac(node_id, direct_addresses, reachability, peer)
        await _open_keyed_session(ac, node.seed)
    except BaseException:
        node.remove_conn(conn_id)
        raise
    return Connection(ac, node, conn_id)


async def _accept_iroh(conn: IrohConn, local_node_id: str, loop: _IrohLoop, node: Node) -> Connection:
    """Complete the responder handshake over an accepted iroh connection, signing
    the server's endpoint id as the locator designator (used by
    :class:`IrohServer`). The accepted connection's loop and netlayer belong to
    the server, not this connection. It is bound to the server's one ``node``
    — shared identity and gift registry — and constructed before the handshake
    completes so the node's giftables are published as bootstrap caps before a
    dialer's pipelined fetch is answered (the exporter half of a three-party
    handoff, ADR-0009), exactly as the TCP responder does."""
    conn_id, peer = node.register_conn()
    ac = AsyncConnection.from_pump(peer, _IrohLoopPump(conn, local_node_id, loop))
    accepted = Connection(ac, node, conn_id)
    await _open_keyed_session(ac, node.seed)
    return accepted


class IrohServer:
    """A listening iroh endpoint — the iroh sibling of :class:`pancake.Server`.
    Async-iterable (``async for conn in server``) for an accepted
    :class:`pancake.Connection` per partner; read :attr:`uri` for the dialable
    address (endpoint id + direct-address hints) to hand a client.
    ``reachability`` (a :class:`Reachability`) is required and sets the endpoint's
    addressing posture — there is no default. Needs the iroh ABI library
    (``zig build iroh-abi``)."""

    def __init__(self, reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None):
        self._netlayer = IrohNetlayer(reachability, secret_seed)
        self._node_id = self._netlayer.node_id()
        # Serve every accepted connection from one readiness loop instead of a
        # blocking accept and a blocking read parked per connection (ADR-0057).
        self._loop = _IrohLoop(self._netlayer)
        # One shared node across every accepted connection — one retained
        # identity and one gift registry — the iroh sibling of the TCP
        # :class:`pancake.Server`. The gifter half of a three-party handoff dials
        # the exporter under this same node (:func:`connect_iroh_with_node`)
        # so a published node-giftable and the introducer it returns share one
        # node (ADR-0009/ADR-0056).
        self._node = Node()
        self._closed = False

    @property
    def node_id(self) -> str:
        """This endpoint's id, the keyed locator designator and the URI host."""
        return self._node_id

    @property
    def node(self) -> Node:
        """The server's shared node: one retained identity and gift registry
        across every accepted connection. Pass it to
        :func:`connect_iroh_with_node` so a fetched capability and the dialing
        connection share one node — the gifter side of a three-party handoff —
        and publish a node-giftable on it with :meth:`Node.publish_giftable`."""
        return self._node

    @property
    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct-address hints."""
        return self._netlayer.direct_addresses()

    @property
    def uri(self) -> str:
        """The ``ocapn://<nodeid>.iroh?direct-addresses=…`` URI a partner dials."""
        hints = {"direct-addresses": self.direct_addresses} if self.direct_addresses else None
        return format_peer_uri("iroh", self._node_id, hints)

    def __aiter__(self) -> "IrohServer":
        return self

    async def __anext__(self) -> "Connection":
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
            # dialed and died), never the server, release it and keep accepting.
            try:
                return await _accept_iroh(conn, self._node_id, self._loop, self._node)
            except Exception:
                self._loop.unregister(conn)
                conn.release()
                continue

    async def close(self) -> None:
        """Stop accepting and release the endpoint. Closes the readiness loop
        (removing its fd reader and waking every waiter) before freeing the
        netlayer, so no callback still touches the endpoint when it is
        released."""
        if self._closed:
            return
        self._closed = True
        self._netlayer.close()
        await self._loop.close()
        self._netlayer.release()

    async def __aenter__(self) -> "IrohServer":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()


def listen_iroh(reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None) -> IrohServer:
    """Bind an iroh endpoint and return an :class:`IrohServer` you iterate for
    each accepted :class:`pancake.Connection`. ``reachability`` (a
    :class:`Reachability`) is required and sets the endpoint's addressing
    posture. There is no default. ``secret_seed`` is a 32-byte Ed25519 secret
    for a
    stable endpoint id, or ``None`` for a fresh random one. Needs the iroh ABI
    library (``zig build iroh-abi``)."""
    return IrohServer(reachability, secret_seed)
