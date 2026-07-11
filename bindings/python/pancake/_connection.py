"""Internal: the application surface over the byte-fed host
(``libpancake_driver``, ADR-0072).

This is what an application holds: :class:`Connection` and its verbs
(``fetch``/``send``/``tell``/``spawn``/``publish``/``enliven``/``serve``/
``close``), the :class:`RemotePromise` a send returns, :class:`Server` and the
top-level :func:`connect` / :func:`listen` dialers, and the two things the
embedder contract leaves to the binding — the pump (read raw bytes off the
transport, hand them to the core's stream delimiter
``pancake_host_conn_feed_bytes``, which owns framing, drain the host's action
queue, write what ``take_outbound`` drains) and the dial executor a DIAL
action names (the recipient half of a three-party handoff opens its own socket
to the exporter; the posture decision for a hint-less iroh give lives here).
The host owns everything else: routing, redemption, gift origination, far
vows. :class:`Node` and :class:`Connection` are one mutually-recursive layer;
the node half lives in :mod:`pancake._host`. Re-exported from the
:mod:`pancake` package; import from there.
"""

from __future__ import annotations

import asyncio
import weakref
from typing import Optional

import ctypes

from . import _constants as _abi
from ._codec import _args_to_c, _ref_to_c
from ._errors import (
    AbortDetail,
    FetchFailed,
    PancakeError,
    PancakeException,
    VowBroken,
    _abort_domain_label,
    _check_host,
    _host_last_error,
)
from ._ffi_driver import _host
from ._ffi_ocapn import _byte_buf, _LastAbort, _lib, _ManagedFrame
from ._host import Node
from ._locator import REDEEMED_TOKEN_BASE, parse_locator, tcp_locator
from ._trampoline import (
    _BehaviorEntry,
    _chase_local_forwards,
    _current_turn_for,
    _entry_for,
    _inside_turn,
    _register_behavior,
    _TRAMPOLINE,
    _turn_spawn,
    _unregister_behavior,
)
from ._value import Far, Forward, Near, Ref, _lift_value, _lower_value

_OK = _abi.OK
_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED
_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE


class _StreamTransport:
    """How bytes move for one TCP connection over asyncio streams — the
    transport seam the byte-fed pump reads and the FLUSH drain writes. The iroh
    companion (:mod:`pancake.iroh`) supplies its own record with the same three
    verbs, so the iroh artifact stays out of this core module entirely. Framing
    is never the transport's job: the host's stream delimiter owns it. The
    write contract every transport record shares: ``write()`` moves bytes
    only — it must not call host verbs or feed a connection, because it runs
    under the connection's ``_write_lock`` and a reentrant flush would
    deadlock or interleave frames."""

    _READ_CHUNK = 65536

    def __init__(self, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter"):
        self._reader = reader
        self._writer = writer

    async def read(self) -> Optional[bytes]:
        """The next chunk of inbound bytes, or ``None`` at a clean end of
        stream."""
        chunk = await self._reader.read(self._READ_CHUNK)
        return chunk if chunk else None

    async def write(self, data: bytes) -> None:
        """Write every byte of ``data``, awaiting the stream's backpressure."""
        self._writer.write(data)
        await self._writer.drain()

    def close(self) -> None:
        self._writer.close()


class RemotePromise(asyncio.Future):
    """The handle :meth:`Connection.send` returns: the eventual result of one
    eventual-send, and -- the point of promise pipelining (ADR-0007) -- a target
    you can ``send`` to before it resolves.

    It is a real :class:`asyncio.Future`, so ``await conn.send(...)``,
    ``asyncio.gather(...)``, and ``isinstance(_, asyncio.Future)`` all work
    natively. Pass it *unawaited* as the ``target`` of a later ``send`` to
    address the object the answer will resolve to: the dependent call rides a
    ``desc:answer`` deliver and the partner queues it until the answer settles,
    so a ``create -> use`` chain costs one round trip::

        task = conn.send(root, "create", ["x"])       # not awaited
        conn.send(task, "assign", ["alice"])          # pipelined at the answer
        status = await conn.send(task, "status", [])  # settles the chain

    The send is queued when this is created, but its bytes leave the wire only
    when this -- or any send pipelined behind it -- is first observed: awaited,
    or registered with a done callback, which is how ``asyncio.gather`` /
    ``wait`` / ``shield`` observe a future, so a gathered handle settles too.
    A pipelined batch therefore travels together. A handle that is never
    observed is a fire-and-forget send; prefer :meth:`Connection.tell` for
    that. Because the
    settle is drain-routed and no exception is materialized until the handle is
    observed, an unobserved anchor whose far answer *breaks* stays silent. Like
    any ``asyncio.Future``, construct it within a running event loop (``send``
    is always called from one). ``vow`` is the host vow the answer settles, or
    ``None`` for a local send (not pipelinable).

    The projection verbs :meth:`index` / :meth:`untag` (ADR-0050/ADR-0052)
    pipeline an element or untag access *at the answer*, before it resolves:
    each returns a new :class:`RemotePromise` for the projected value.
    """

    def __init__(self, vow: Optional[int], begin, project=None) -> None:
        # The future is created empty -- no flush runs here, so construction is
        # side-effect-free and the send stays lazy.
        super().__init__()
        self._vow = vow
        self._begin = begin
        # Issues a projection op (index/untag) at this vow and returns the new
        # RemotePromise; None for a local-send handle (no answer to project).
        self._project = project
        self._started = False
        # The begin task, retained: the event loop holds tasks only weakly, so
        # an unreferenced begin could be collected mid-flight.
        self._begin_task: "Optional[asyncio.Future]" = None

    @property
    def vow(self) -> Optional[int]:
        return self._vow

    def _project_op(self, op: str, key) -> "RemotePromise":
        if self._project is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot project a local-send promise; await it for a value")
        return self._project(op, key)

    def index(self, i: int) -> "RemotePromise":
        """Pipeline an ``op:index`` for ``i`` at this answer (ADR-0050): a new
        :class:`RemotePromise` for the List element of whatever this resolves
        to."""
        return self._project_op("index", int(i))

    def untag(self, tag: str) -> "RemotePromise":
        """Pipeline an ``op:untag`` for ``tag`` at this answer (ADR-0052): a new
        :class:`RemotePromise` for the payload of whatever this resolves to,
        which must be a Tagged record whose tag equals ``tag``."""
        return self._project_op("untag", tag)

    def _ensure_started(self) -> None:
        # First observation schedules the send's flush + reply wait, exactly
        # once, and chains its outcome onto this future. Observation is an
        # ``await`` or a Future-protocol registration (``add_done_callback``,
        # below). An unobserved handle never starts ``begin``, so its answer
        # breaking never settles us.
        if not self._started:
            self._started = True
            task = asyncio.ensure_future(self._begin())
            self._begin_task = task
            task.add_done_callback(self._chain)

    def __await__(self):
        self._ensure_started()
        return super().__await__()

    __iter__ = __await__  # `yield from` compatibility, mirroring asyncio.Future

    def add_done_callback(self, callback, *, context=None) -> None:
        # The Future-protocol observation path: ``asyncio.gather`` / ``wait`` /
        # ``shield`` never call ``__await__`` on a child, they register a done
        # callback — so registering interest is what starts the send.
        self._ensure_started()
        if context is None:
            super().add_done_callback(callback)
        else:
            super().add_done_callback(callback, context=context)

    def _chain(self, task: "asyncio.Future") -> None:
        # Copy the begin task's outcome onto this future. Guard the states a
        # future can already be in so a late settlement never raises.
        if self.cancelled():
            return
        if task.cancelled():
            self.cancel()
            return
        exc = task.exception()
        if exc is not None:
            self.set_exception(exc)
        else:
            self.set_result(task.result())


class Caretaker:
    """A revocable caretaker over a capability (ADR-0064), returned by
    :meth:`Connection.caretaker`. Hand :attr:`proxy` to a partner; call
    :meth:`revoke` to sever it, after which every call through the proxy breaks
    with ``Revoked``."""

    def __init__(self, proxy: Ref, live: list):
        self.proxy = proxy
        self._live = live

    def revoke(self) -> None:
        """Sever the proxy: subsequent calls through it break with ``Revoked``.
        Idempotent."""
        self._live[0] = False


class Connection:
    """A live connection to one OCapN partner, the one object an app holds,
    over one byte-fed ``PancakeHostConn`` the shared :class:`Node` minted.

        conn = await connect(tcp_locator("127.0.0.1", 9099))
        conn.serve()
        board = await conn.fetch("board")
        inbox = conn.spawn(lambda verb, args: None)
        await conn.send(board, "watch", [inbox])
    """

    def __init__(self, ptr: ctypes.c_void_p, node: Node, transport):
        self._ptr = ptr
        self._key = ptr.value or 0
        self._node = node
        self._transport = transport
        # Inbound bytes read from the wire but not yet consumed by the core's
        # stream delimiter (the unconsumed tail of the last feed).
        self._inbox = bytearray()
        self._serve_task: Optional[asyncio.Task] = None
        # Set the moment teardown begins (an application close, or the
        # transport reporting EOF), so the FAIL completions the break queues
        # classify as the typed ERR_CLOSED instead of partner breaks.
        self._closing = False
        self._released = False
        # Serializes transport writes: `flush_outbound` runs from the action
        # drain, the feed-failure choreography, and teardown, and each frame
        # must land whole and in submission order.
        self._write_lock = asyncio.Lock()
        # Export position -> trampoline ctx id for the objects this connection
        # hosts, so a `Forward` whose target this side hosts composes in
        # process (and a send to a self-spawned Ref runs in process).
        self._hosted: "dict[int, int]" = {}
        # True for an exporter connection the node's action drain dialed to
        # redeem a handoff, so `close()` can sweep it.
        self.node_dialed = False
        # Distributed GC (ADR-0063), opt-in and off by default. A finalizer
        # (possibly off the loop thread) only parks the token; the release runs
        # on the loop thread, at the head of the next verb or as its own task.
        self._gc = False
        self._gc_pending: "list[int]" = []
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None
        # Join the node's registry so a FLUSH action can find the transport and
        # a dialed exporter stays reachable for teardown.
        node.register_connection(self._key, self)

    # ── Construction: establish, dial, accept ──────────────────────────────────

    @classmethod
    def _mint_dialed(cls, node: Node, locator_uri: str, transport) -> "Connection":
        # Mint the dialing half without driving the handshake — the signed
        # op:start-session is encoded (its FLUSH queued) but nothing has moved.
        data = locator_uri.encode()
        buf, ptr = _byte_buf(data)
        out = ctypes.c_void_p()
        _check_host(_host.pancake_host_conn_open_dialed(
            node.raw, ptr, len(data), ctypes.byref(out),
        ))
        return cls(out, node, transport)

    @classmethod
    async def establish_dialed(cls, node: Node, locator_uri: str, transport) -> "Connection":
        """Mint the dialing half of a connection to the peer ``locator_uri``
        names over ``transport`` (already connected) and drive the keyed
        handshake open. The transport seam the companions build on: the iroh
        module calls this with its loop-driven transport. Binding-internal."""
        return await cls._mint_dialed(node, locator_uri, transport)._establish()

    @classmethod
    async def establish_accepted(cls, node: Node, transport_name: str, designator: str, transport) -> "Connection":
        """Mint the accepting half over a connection the caller's own listener
        produced: the keyed op:start-session signs the listener's own
        ``transport_name``/``designator`` — the address a partner can actually
        dial, and the locator a give made on this node names as the exporter
        location. Every node-wide giftable is published on the new connection
        before the open returns, so a dialer's pipelined fetch finds it.
        Binding-internal."""
        t = transport_name.encode()
        d = designator.encode()
        tbuf, tptr = _byte_buf(t)
        dbuf, dptr = _byte_buf(d)
        out = ctypes.c_void_p()
        _check_host(_host.pancake_host_conn_open_accepted(
            node.raw, tptr, len(t), dptr, len(d), ctypes.byref(out),
        ))
        return await cls(out, node, transport)._establish()

    @classmethod
    async def connect(cls, host: str, port: int, node: Optional[Node] = None) -> "Connection":
        """Dial ``host:port``, complete the keyed OCapN handshake, and return a
        ready connection. The session is open before this resolves, so a
        ``fetch``/``send`` rides an established session, the same handshake a
        real Goblins peer requires. Pass ``node`` to share one node identity
        and gift registry across several connections (the gifter side of a
        three-party handoff); omit it for a standalone connection."""
        node = node if node is not None else Node()
        reader, writer = await asyncio.open_connection(host, port)
        transport = _StreamTransport(reader, writer)
        try:
            return await cls.establish_dialed(node, tcp_locator(host, port), transport)
        except BaseException:
            # The socket opened but the open or handshake failed: `_establish`
            # abandons a half-built connection; a failed open_dialed leaves
            # only the socket to close.
            transport.close()
            raise

    @classmethod
    async def _accept(cls, reader, writer, node: Node) -> "Connection":
        """Wrap an accepted stream and complete the keyed handshake from the
        responder side. Resolves once the session is open."""
        sock = writer.get_extra_info("sockname")
        transport = _StreamTransport(reader, writer)
        try:
            return await cls.establish_accepted(node, "tcp", f"{sock[0]}:{sock[1]}", transport)
        except BaseException:
            transport.close()
            raise

    @classmethod
    async def _dial_exporter(cls, uri: str, transport_name: str, designator: str,
                             direct_addresses_hint: str, node: Node) -> "Connection":
        """Dial an exporter a DIAL action names, keyed with ``node``'s retained
        identity, and bind the result to that same node so the redeemed
        capability and any further handoff it triggers share one identity and
        connection table. The action carries the locator's parsed pieces, so
        nothing re-parses the URI grammar here beyond the tcp host:port split.
        Binding-internal: the node's action drain calls this to redeem a give.
        Dispatches on the transport: a ``tcp`` locator dials its host:port; an
        ``iroh`` give with direct-address hints dials them with no discovery
        service (Direct), and a bare node id resolves by id under the node's
        configured redeem posture (default Discovery; a relay-policy node
        lowers it), so one give shape covers an offline direct dial and an
        internet dial-by-id alike."""
        if transport_name == "tcp":
            # The host:port split is the core grammar's verdict, read off the
            # full locator rather than a re-derived string scan.
            loc = parse_locator(uri)
            if loc.host is None or loc.port is None:
                raise PancakeError(_ERR_INVALID_ARGUMENT, f"tcp locator designator is not host:port: {designator}")
            return await cls.connect(loc.host, loc.port, node)
        if transport_name == "iroh":
            # Reached lazily so the core never hard-depends on the optional
            # iroh artifact.
            from . import iroh as _iroh_transport
            reachability = (
                _iroh_transport.Reachability.DIRECT
                if direct_addresses_hint else node.redeem_reachability
            )
            return await _iroh_transport.connect_iroh_with_node(
                designator, direct_addresses_hint, reachability, node,
            )
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'handoff redeem: unsupported exporter transport "{transport_name}" in {uri}',
        )

    async def _establish(self) -> "Connection":
        # Drive the freshly opened connection's keyed handshake to an open
        # session, abandoning the connection on any failure (release +
        # transport close) so a rude partner costs one accept, never the
        # listener.
        try:
            # The signed op:start-session was encoded by the open; its FLUSH is
            # on the action queue, so the drain puts it on the wire now.
            await self._node.kick_actions()
            while not self.session_open:
                chunk = await self._transport.read()
                if chunk is None:
                    raise PancakeError(_ERR_CLOSED, "connection closed during the OCapN handshake")
                # The one feed body serves the handshake too: the core stops
                # consuming at the frame that opens the session, so a fast
                # partner's application frames arriving coalesced behind its
                # start-session stay buffered in the inbox until the
                # application has published and called `serve()` — otherwise a
                # pipelined fetch would be answered before the object it names
                # exists.
                await self._feed(chunk)
            return self
        except BaseException:
            self.close_transport()
            raise

    # ── Properties ──────────────────────────────────────────────────────────────

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHostConn handle. Binding-internal: the node's DIAL
        arm reports it through ``pancake_host_dialed``."""
        return self._ptr

    @property
    def node(self) -> Node:
        """The connection's shared node, its retained identity and gift
        registry, shared by every connection of one node so the gifter half of
        a handoff can reach a sibling connection's session keys. An application
        reads it to publish node-giftables (:meth:`Node.publish_giftable`),
        share one identity across dials, or set the redeem posture."""
        return self._node

    @property
    def closing(self) -> bool:
        """Whether teardown has begun. Binding-internal: the node's FAIL arm
        classifies a closing connection's breaks as the typed ERR_CLOSED."""
        return self._closing or self._released

    @property
    def session_open(self) -> bool:
        """Whether the keyed handshake has completed and the session is open."""
        return not self._released and _host.pancake_host_conn_session_open(self._ptr) == 1

    def _guard_open(self) -> None:
        if self._released:
            raise PancakeError(_ERR_CLOSED, "connection closed")

    # ── The pump ────────────────────────────────────────────────────────────────

    def serve(self) -> "asyncio.Task":
        """Run the inbound loop as a background task: read raw bytes, hand them
        to the core's stream delimiter (behaviors run and vow completions queue
        inside the feed), and drain the action queue. The task completes when
        the connection closes cleanly; started once."""
        if self._serve_task is None:
            self._serve_task = asyncio.get_running_loop().create_task(self._serve_loop())
        return self._serve_task

    async def _serve_loop(self) -> None:
        try:
            # Frames that arrived behind the handshake's tail are still
            # buffered; dispatch them before parking on the wire.
            if self._inbox:
                await self._feed(b"")
            while True:
                if self._released:
                    return
                chunk = await self._transport.read()
                if chunk is None:
                    return  # clean EOF
                await self._feed(chunk)
        except (asyncio.CancelledError, OSError):
            # A read cancelled by our own close is a clean shutdown; any other
            # failure is a real fault the awaiting caller should see.
            if not self.closing:
                raise
        finally:
            # The wire is gone: pending far vows can never settle, so break
            # them (classified as closure — `_closing` is set first) and
            # release the conn, freeing the fd. Idempotent with an application
            # `close()`.
            if not self.closing:
                self._closing = True
                try:
                    msg = b"connection closed"
                    buf, ptr = _byte_buf(msg)
                    _check_host(_host.pancake_host_conn_break_far_vows(
                        self._ptr, ptr, len(msg),
                    ))
                    await self._node.kick_actions()
                except Exception:
                    pass  # teardown is best-effort; release still reclaims the rows
                self.close_transport()

    def _feed_raw(self, ptr, length: int) -> "tuple[int, int]":
        # One synchronous feed of `length` bytes at `ptr`: behavior trampolines
        # fire and completions queue inside. Returns (rc, consumed).
        consumed = ctypes.c_size_t(0)
        rc = _host.pancake_host_conn_feed_bytes(self._ptr, ptr, length, ctypes.byref(consumed))
        return rc, consumed.value

    async def _feed(self, chunk: bytes) -> None:
        # Feed inbound bytes to the core's stream delimiter: the session's
        # codec splits each complete frame off the front — both codecs, both
        # frame shapes, the frame cap enforced during the scan — and dispatches
        # it, then the actions the dispatch queued drain. Steady state (no
        # pending tail) borrows the fresh chunk's own buffer for the one
        # synchronous feed, zero-copy; only when a partial frame already
        # straddles two reads is the burst coalesced into the inbox — the one
        # copy on the inbound path, paid only while a tail is pending, because
        # the delimiter needs the tail and the new bytes contiguous. Only the
        # unconsumed tail stays in the inbox. A mid-feed close parks its C
        # release; it drains the moment the feed returns.
        if self._released:
            return
        if not self._inbox:
            n = len(chunk)
            if not n:
                return
            # Borrowed, not copied: c_char_p points at `chunk`'s own bytes,
            # which the synchronous feed only reads.
            ptr = ctypes.cast(ctypes.c_char_p(chunk), ctypes.c_void_p)
            rc, consumed = self._feed_raw(ptr, n)
            self._node._drain_parked_releases()
            if rc != _OK:
                await self._raise_feed_refusal(rc)
            if consumed < n:
                self._inbox.extend(chunk[consumed:])
            await self._node.kick_actions()
            return
        self._inbox.extend(chunk)
        n = len(self._inbox)
        # The coalesce copy: one ctypes buffer over the pending tail plus the
        # fresh chunk, so the core sees contiguous bytes.
        buf = (ctypes.c_uint8 * n).from_buffer_copy(self._inbox)
        rc, consumed = self._feed_raw(ctypes.c_void_p(ctypes.addressof(buf)), n)
        self._node._drain_parked_releases()
        if rc != _OK:
            await self._raise_feed_refusal(rc)
        del self._inbox[:consumed]
        await self._node.kick_actions()

    async def _raise_feed_refusal(self, rc: int) -> None:
        # The feed refusal choreography: capture the host's last error BEFORE
        # the abort reader can clobber it, read the typed cause, write the
        # typed op:abort the core already projected so the partner hears why,
        # then raise.
        message = _host_last_error()
        abort = self.last_abort()
        try:
            await self.flush_outbound()
        except Exception:
            pass  # the transport may already be gone; the local typed error stands
        raise PancakeError(rc, message, abort=abort)

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of this connection's most recent local dispatch
        failure, or ``None`` when none has been recorded. The flat per-feed
        error code names the failure family; this names the member. Errors
        raised by a refused feed carry it already as ``err.abort``."""
        if self._released:
            return None
        info = _LastAbort()
        rc = _host.pancake_host_conn_last_abort(self._ptr, ctypes.byref(info))
        if rc == _WOULD_BLOCK:
            return None
        _check_host(rc)

        def text(ptr, length) -> str:
            return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""

        return AbortDetail(
            domain=_abort_domain_label(info.domain),
            kind=text(info.kind_name, info.kind_name_len) if info.has_kind else None,
            message=text(info.message, info.message_len),
            error_name=text(info.error_name, info.error_name_len),
        )

    async def flush_outbound(self) -> None:
        """Drain every encoded outbound frame on this connection and write it
        to the transport — how a FLUSH action lands. Writes are serialized, so
        frames stay whole and in submission order. Binding-internal."""
        async with self._write_lock:
            while True:
                if self._released:
                    return
                mf = _ManagedFrame()
                rc = _host.pancake_host_conn_take_outbound(self._ptr, ctypes.byref(mf))
                if rc == _WOULD_BLOCK:
                    return
                _check_host(rc)
                frame = ctypes.string_at(mf.bytes, mf.len) if mf.bytes else b""
                # The managed frame is the shared core vocabulary, released
                # through the core archive.
                _lib.pancake_managed_frame_release(ctypes.byref(mf))
                await self._transport.write(frame)

    # ── Teardown ────────────────────────────────────────────────────────────────

    async def close(self) -> None:
        """Close the connection and every exporter connection its node dialed
        for handoffs. A running :meth:`serve` completes cleanly; pending vows
        settle with the typed ERR_CLOSED."""
        self._closing = True
        self._node.close_exporters()
        self.close_transport()
        task = self._serve_task
        if task is not None and task is not asyncio.current_task():
            try:
                await task
            except (asyncio.CancelledError, OSError, PancakeException):
                pass

    def close_transport(self) -> None:
        """Close just this connection, without touching the node's other
        connections: stop the transport first, then retire the node's entry and
        free the host handle (its still-parked far vows break inside the
        release, classified as closure), so no foreign call touches a freed
        connection. Called from inside a behavior callback — where the C tier
        refuses the release — it parks the release on the node; the enclosing
        feed's unwind runs it, so a mid-turn close never leaks the handle.
        Binding-internal."""
        self._closing = True
        try:
            self._transport.close()
        except Exception:
            pass  # already closed
        if self._released:
            return
        self._released = True
        self._node.unregister_connection(self._key)
        # The host can never deliver to this connection's hosted objects again;
        # drop their trampoline entries so the registry does not pin dead
        # behaviors. Node-wide giftables live on the node, untouched here.
        for ctx in self._hosted.values():
            _unregister_behavior(ctx)
        self._hosted.clear()
        ptr = self._ptr
        self._ptr = None
        if _inside_turn():
            self._node._park_release(lambda: _host.pancake_host_conn_release(ptr))
        else:
            _host.pancake_host_conn_release(ptr)
        # The release queued FAIL completions (and sibling withdraws may have
        # failed closed): route them now.
        self._node.schedule_kick()

    async def __aenter__(self) -> "Connection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    # ── Hosting: spawn, publish, and the proxy verbs ───────────────────────────

    def _register_actor(self, behavior: "Behavior") -> int:
        # Register `behavior` in the trampoline registry as an actor of this
        # connection, so a Forward whose target this side hosts composes in
        # process and a turn it runs can spawn turn-time.
        return _register_behavior(_BehaviorEntry(
            run=behavior,
            conn=self,
            resolve_local=lambda position: _entry_for(self._hosted.get(position)),
        ))

    def spawn(self, behavior: "Behavior") -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback. The
        position comes from the session's one export allocator, so it can never
        alias a bootstrap or resolver export. Callable from inside a served
        turn (a factory's ``create`` minting the task it replies with)."""
        self._guard_open()
        ctx = self._register_actor(behavior)
        turn = _current_turn_for(self)
        if turn is not None:
            # The turn-time spawn: the host refuses the top-level one inside a
            # behavior callback.
            position = _turn_spawn(turn, ctx)
        else:
            out = ctypes.c_uint64()
            _check_host(_host.pancake_host_conn_spawn(
                self._ptr, _TRAMPOLINE, ctypes.c_void_p(ctx), None, ctypes.byref(out),
            ))
            position = out.value
        self._hosted[position] = ctx
        return Ref(near=Near(position))

    def publish(self, name: str, behavior: "Behavior") -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        self._guard_open()
        ctx = self._register_actor(behavior)
        swiss = name.encode()
        buf, ptr = _byte_buf(swiss)
        out = ctypes.c_uint64()
        _check_host(_host.pancake_host_conn_publish(
            self._ptr, ptr, len(swiss),
            _TRAMPOLINE, ctypes.c_void_p(ctx), None, ctypes.byref(out),
        ))
        position = out.value
        self._hosted[position] = ctx
        return Ref(near=Near(position))

    def caretaker(self, target: Ref) -> Caretaker:
        """Wrap ``target`` (local or far) in a revocable caretaker (ADR-0064).
        Returns a :class:`Caretaker` whose ``proxy`` is an ordinary capability
        to hand a partner; every call through it forwards to ``target`` until
        :meth:`Caretaker.revoke`, after which each breaks with ``Revoked``.
        ``target`` may be a capability imported over the wire — the proxy
        forwards transparently — so this hands out a revocable view of
        authority you do not own locally. The proxy is a plain spawned actor,
        so it answers a local call exactly as a partner's does."""
        live = [True]

        def proxy_behavior(verb: str, args: list):
            if not live[0]:
                raise ValueError("Revoked")
            return Forward(target, verb, args)

        return Caretaker(self.spawn(proxy_behavior), live)

    def attenuate(self, target: Ref, verbs: "list[str]") -> Ref:
        """Wrap ``target`` (local or far) in an attenuator (ADR-0064): a proxy
        that forwards only the calls whose verb is in ``verbs`` and breaks
        every other with ``Attenuated``. Returns the proxy capability to hand a
        partner. The proxy is a plain spawned actor."""
        allowed = set(verbs)

        def proxy_behavior(verb: str, args: list):
            if verb not in allowed:
                raise ValueError("Attenuated")
            return Forward(target, verb, args)

        return self.spawn(proxy_behavior)

    # ── The application verbs ───────────────────────────────────────────────────

    async def fetch(self, name: str) -> Ref:
        """Fetch a partner's published capability by ``name``. Returns a
        :class:`Ref` you can ``send`` to. The canonical fetch lives in the
        library: one call registers the bootstrap import, allocates the answer,
        and queues the deliver; the host enrolls the fulfilled capability under
        a node-unique token (ADR-0069) before the completion is queued, so a
        return re-gifts the right home. Starts the inbound loop itself, so a
        ``fetch`` straight after ``connect`` works without a separate
        :meth:`serve` call. Raises :class:`VowBroken` when the partner breaks
        the fetch, and :class:`FetchFailed` when it fulfills with something
        that is not a live capability."""
        return await self._fetch_like(name.encode(), name, _host.pancake_host_conn_fetch, track=True)

    async def _fetch_like(self, swiss: bytes, label: str, mint, track: bool) -> Ref:
        # The one mint/await/classify body under `fetch` and `enliven`: mint
        # the host vow with `mint`, await its drain-routed completion, and
        # classify — only a near/far reference is a live capability this
        # surface can hand out; anything else would leak a half-supported
        # kind, so the call fails instead. `track` marks the Far arm for
        # distributed GC: a fetch's import is finalizer-tracked, an enliven's
        # is owned by the ADR-0012 dedup cache instead (ADR-0063).
        self._guard_open()
        self._drain_gc()
        buf, ptr = _byte_buf(swiss)
        out = ctypes.c_uint64()
        _check_host(mint(self._ptr, ptr, len(swiss), ctypes.byref(out)))
        result = await self._await_minted(out.value)
        if isinstance(result, Near):
            return Ref(near=result)
        if not isinstance(result, Far):
            raise FetchFailed(label)
        ref = Ref(far=result)
        return self._track_import(ref) if track else ref

    async def enliven(self, sturdyref: str) -> Ref:
        """Enliven a sturdyref against this connection (ADR-0012): bring the
        durable ``(peer, swissnum)`` to life as a live :class:`Ref`. Parses
        ``sturdyref`` for its swissnum, then fetches it through the host's
        dedup cache -- a repeat enliven of the same swissnum on this session
        short-circuits with no wire traffic (its completion is queued before
        the minting call returns). The connection must already be open to the
        sturdyref's peer; the sans-io core tracks no remote locator and never
        dials. Raises :class:`VowBroken` when the partner breaks the enliven,
        and :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        swiss = parse_locator(sturdyref, sturdyref=True).swissnum.encode()
        return await self._fetch_like(swiss, sturdyref, _host.pancake_host_conn_enliven, track=False)

    async def _await_minted(self, vow: int):
        # The shared fetch/enliven wait: register the vow, keep the inbound
        # loop running (the completion's bytes arrive on it), kick the drain so
        # the deliver leaves now, and await the drain-routed outcome.
        self._node.vow_minted(vow, self)
        self.serve()
        settled = self._node.await_vow(vow)
        await self._node.kick_actions()
        return await settled

    def send(self, target: "Ref | RemotePromise", verb: str, args: "Optional[list]" = None) -> RemotePromise:
        """Eventual-send ``verb(args)`` to ``target`` and return a
        :class:`RemotePromise` for the reply. ``await`` it for the value (a
        :class:`Ref` if the partner returned a capability; raises
        :class:`VowBroken` on a partner break).

        ``target`` is a capability :class:`Ref` *or* a :class:`RemotePromise`
        from an earlier send: passing the latter pipelines (ADR-0007) -- the
        call is addressed at the answer that send will resolve, so a dependent
        chain costs one round trip instead of one per link. ``args`` may
        contain :class:`Ref`\\ s. A :class:`Ref` this connection spawned runs
        in process; a partner's rides the wire, and a redeemed or fetched token
        routes to the exporter connection that hosts it, transparently.

        The deliver is queued now; its bytes leave the wire when the returned
        handle -- or any send pipelined behind it -- is first observed (awaited
        or gathered), so a pipelined batch travels together."""
        self._guard_open()
        self._drain_gc()
        args = list(args or [])
        # A send to an object this side hosts runs its behavior in process — a
        # proxy over a *far* target then defers onto the wire reply, the same
        # forward semantics a partner's delivery gets (ADR-0064).
        if isinstance(target, Ref) and target.near is not None:
            ctx = self._hosted.get(target.near.id)
            if ctx is not None:
                return self._send_local(ctx, verb, args)
        verb_bytes = verb.encode()
        vbuf, vptr = _byte_buf(verb_bytes)
        keepalive: list = []
        arr, count = _args_to_c([_lower_value(a) for a in args], keepalive)
        out = ctypes.c_uint64()
        if isinstance(target, RemotePromise):
            # Promise pipelining: eventual-send to the unresolved answer. A
            # local send's promise has no wire answer to pipeline against.
            if target.vow is None:
                raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot pipeline against a local-send promise; await it for a Ref")
            _check_host(_host.pancake_host_vow_send(
                self._node.raw, target.vow, vptr, len(verb_bytes), arr, count, ctypes.byref(out),
            ))
        else:
            ref = _ref_to_c(target._wire())
            _check_host(_host.pancake_host_conn_send(
                self._ptr, ctypes.byref(ref), vptr, len(verb_bytes), arr, count, ctypes.byref(out),
            ))
        vow = out.value
        self._node.vow_minted(vow, self)
        return self._promise_for(vow)

    def _send_local(self, ctx: int, verb: str, args: list) -> RemotePromise:
        # The local arm of `send`: run the hosted behavior on first observation
        # and settle from its result. A `Forward` to another object this side
        # hosts composes in process; a `Forward` to a far target defers the
        # answer onto the forwarded send's reply (ADR-0064); a raise settles
        # broken with the behavior's own words.
        async def begin():
            try:
                entry = _entry_for(ctx)
                # A closed connection unregisters its hosted entries; the
                # break agrees with the wire semantics (a trampoline breaks)
                # so the two dispatch paths cannot drift apart.
                if entry is None:
                    raise VowBroken("no such hosted object")
                result = _chase_local_forwards(entry, entry.run(verb, args))
                if isinstance(result, Forward):
                    # A far (or promise) target: the local answer settles on
                    # the forwarded send's wire reply.
                    return await self.send(result.target, result.verb, result.args)
                return result
            except PancakeException:
                # A typed wire failure (the forwarded reply's break) passes
                # through; a behavior's own raise breaks with its words, as
                # over the wire.
                raise
            except Exception as error:  # noqa: BLE001 — a raise breaks the answer
                raise VowBroken(str(error) or type(error).__name__)

        return RemotePromise(None, begin, None)

    def _promise_for(self, vow: int) -> RemotePromise:
        # The RemotePromise over a freshly minted host vow: observation kicks
        # the drain (the flush that puts the queued batch on the wire) and
        # awaits the drain-routed completion; projections mint sibling vows at
        # the answer.
        async def begin():
            self.serve()  # the settle's bytes arrive on the inbound loop
            settled = self._node.await_vow(vow)
            await self._node.kick_actions()
            return _lift_value(await settled)

        def project(op: str, key) -> RemotePromise:
            out = ctypes.c_uint64()
            if op == "index":
                _check_host(_host.pancake_host_vow_index(
                    self._node.raw, vow, int(key), ctypes.byref(out),
                ))
            else:
                tag = str(key).encode()
                tbuf, tptr = _byte_buf(tag)
                _check_host(_host.pancake_host_vow_untag(
                    self._node.raw, vow, tptr, len(tag), ctypes.byref(out),
                ))
            projected = out.value
            self._node.vow_minted(projected, self)
            return self._promise_for(projected)

        return RemotePromise(vow, begin, project)

    async def tell(self, target: Ref, verb: str, args: "Optional[list]" = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        self._guard_open()
        self._drain_gc()
        args = list(args or [])
        # A tell to an object this side hosts runs its behavior in process; the
        # result is discarded (no answer), a far forward continues as a far
        # tell, and a raise breaks nothing — there is no answer to break.
        if target.near is not None:
            ctx = self._hosted.get(target.near.id)
            if ctx is not None:
                try:
                    entry = _entry_for(ctx)
                    result = None
                    if entry is not None:
                        result = _chase_local_forwards(entry, entry.run(verb, args))
                    if isinstance(result, Forward):
                        await self.tell(result.target, result.verb, result.args)
                except Exception:  # noqa: BLE001 — no answer to break
                    pass
                return
        verb_bytes = verb.encode()
        vbuf, vptr = _byte_buf(verb_bytes)
        keepalive: list = []
        arr, count = _args_to_c([_lower_value(a) for a in args], keepalive)
        ref = _ref_to_c(target._wire())
        _check_host(_host.pancake_host_conn_tell(
            self._ptr, ctypes.byref(ref), vptr, len(verb_bytes), arr, count,
        ))
        await self._node.kick_actions()

    def set_exporter_locator(self, raw_locator: bytes) -> None:
        """Record the verbatim exporter-location bytes (from
        :func:`encode_peer_locator`) the gifter embeds when *this* connection
        is the exporter side of a handoff this node originates (ADR-0009).
        Needed when the partner's signed location is not dialable on its own —
        an iroh partner signs only its node id, so a gifter that learned the
        exporter's ``direct-addresses`` out of band sets the full locator here.
        Unset, origination falls back to the partner's signed location."""
        self._guard_open()
        # Empty unsets the override; keep the NULL the header documents there.
        buf, ptr = _byte_buf(raw_locator) if raw_locator else (None, None)
        _check_host(_host.pancake_host_conn_set_exporter_location(
            self._ptr, ptr, len(raw_locator),
        ))

    # ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

    def with_gc(self) -> "Connection":
        """Opt this connection into distributed GC (ADR-0063), off by default.
        Once on, a far capability returned by :meth:`fetch` releases its import
        to the partner -- a single ``op:gc-exports`` delta, routed through the
        host to the import's home connection -- when the runtime reclaims the
        last :class:`Ref` to it, so the partner can release the matching
        export. CPython's refcounting makes that release prompt on the last
        ``del``. Capabilities lifted elsewhere (a ``send`` reply, a delivered
        argument, an ``enliven`` result the dedup cache owns) are outside this
        seam. Returns ``self`` for chaining."""
        self._gc = True
        return self

    def _track_import(self, ref: Ref) -> Ref:
        # Register a fetched capability for GC when GC is on. The `Ref` holds a
        # node-unique token (ADR-0069) — only ids in the token range are
        # tracked — and the host resolves the token to its home connection and
        # real wire import when the release fires. The finalizer captures only
        # the bare token integer, never the `Ref`, so it cannot resurrect the
        # handle whose death it waits on.
        wire = ref.far
        if self._gc and wire is not None and wire.id >= REDEEMED_TOKEN_BASE:
            weakref.finalize(ref, self._on_import_dropped, wire.id)
        return ref

    def _on_import_dropped(self, token: int) -> None:
        # Runs when the last `Ref` is collected, possibly off the loop thread:
        # park the token and hop to the loop to drain it — gc_release never
        # runs from a finalizer thread.
        self._gc_pending.append(token)
        if self._loop is None:
            return
        try:
            self._loop.call_soon_threadsafe(self._drain_gc)
        except RuntimeError:
            pass  # the loop is closed; teardown reclaims the partner's export

    def _drain_gc(self) -> None:
        # Drain the parked GC releases on the loop thread: one release delta
        # per reclaimed token, then a kick so the op:gc-exports flushes.
        # Best-effort — a refused release strands a partner export reclaimed at
        # teardown, never a fault. Called at the head of the connection's own
        # verbs and as the finalizer's hopped call.
        if not self._gc_pending or self._released:
            return
        pending, self._gc_pending = self._gc_pending, []
        for token in pending:
            try:
                _check_host(_host.pancake_host_gc_release(self._node.raw, token, 1))
            except Exception:  # noqa: BLE001 — best-effort
                pass
        self._node.schedule_kick()


class Server:
    """A listening server, one object an app holds. Async-iterable (``async
    for conn in server``), and ``.port`` surfaces the bound port so binding an
    ephemeral port (``port=0``) and telling a partner where to connect works
    the same as the other bindings."""

    def __init__(self, server: "asyncio.AbstractServer", queue: "asyncio.Queue", node: Node):
        self._server = server
        self._queue = queue
        self._node = node

    @property
    def port(self) -> int:
        """The kernel-chosen bound port (read it back after binding ``port=0``)."""
        return self._server.sockets[0].getsockname()[1]

    @property
    def node(self) -> Node:
        """The server's shared node: one retained identity and gift registry
        across every accepted connection. Pass it to :func:`connect` (or
        :meth:`Connection.connect`) so a fetched capability and the recipient
        connection share one node, the gifter side of a three-party handoff.
        Publish a node-giftable on it with :meth:`Node.publish_giftable`."""
        return self._node

    def close(self) -> None:
        """Stop accepting new partners. This closes the listening socket only;
        connections already accepted are unaffected."""
        self._server.close()

    async def __aenter__(self) -> "Server":
        return self

    async def __aexit__(self, *exc) -> None:
        self.close()

    def __aiter__(self) -> "Server":
        return self

    async def __anext__(self) -> "Connection":
        # A partner that fails its handshake — a rude probe that connects and
        # hangs up — is that connection's failure, never the listener's: skip
        # it and keep accepting, so one port scan cannot take a long-lived
        # server down. (`Connection._accept` already closed the transport.)
        while True:
            reader, writer = await self._queue.get()
            try:
                return await Connection._accept(reader, writer, self._node)
            except (PancakeError, OSError):
                # PancakeError: the handshake failed (EOF mid-handshake).
                # OSError: the probe reset the socket under the teardown.
                continue


async def listen(host: str, port: int = 0, node: Optional[Node] = None,
                 codec: Optional[str] = None) -> Server:
    """Bind a listening :class:`Server`. ``async for conn in await listen(host,
    0)`` accepts each partner; ``server.port`` reads the bound ephemeral port.
    Each yielded :class:`Connection` is one accepted partner: publish
    capabilities on it and call :meth:`Connection.serve`. ``codec`` picks the
    wire grammar for a server built on a fresh node; a supplied ``node``
    already carries one, and a conflicting explicit codec is refused rather
    than silently ignored."""
    if node is not None and codec is not None and codec != node.codec:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'codec "{codec}" conflicts with the node\'s "{node.codec}"; mint the node with it instead',
        )
    node = node if node is not None else Node(codec=codec or "syrup")
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), host, port,
    )
    # This node also dials (the gifter side of a handoff), and its dials sign
    # the listener's own address so a partner's crossed-hellos table can
    # recognize it.
    bound_port = server.sockets[0].getsockname()[1]
    node.set_self_designator(f"{host}:{bound_port}")
    return Server(server, queue, node)


async def connect(uri: str, reachability: "Optional[int]" = None,
                  node: "Optional[Node]" = None, codec: Optional[str] = None) -> Connection:
    """Dial a partner from its ``ocapn://`` locator, the one dialer,
    dispatching on the locator's transport: ``iroh`` dials the endpoint id with
    its ``direct-addresses`` hints, ``tcp`` dials the ``host:port`` designator.
    There is no other dial: a literal address is a ``tcp`` locator, built with
    :func:`tcp_locator`. Parse once, the core grammar picks the netlayer.

    A ``tcp`` locator needs only this core module. An ``iroh`` locator reaches
    into the companion :mod:`pancake.iroh` (the optional encrypted-QUIC
    artifact), imported lazily here so the core never hard-depends on it;
    ``reachability`` is a :class:`pancake.iroh.Reachability` (its ``int`` value
    also works) and sets the iroh dialer's posture. It is required only for an
    ``iroh`` locator; a ``tcp`` locator ignores it, so a plain TCP dial needs
    nothing but the locator. An iroh locator with no posture fails closed
    rather than guessing one.

    ``node`` shares one identity and gift registry across a server and its
    dialed sibling connections — the gifter half of a three-party handoff (read
    it as ``server.node``). Only the ``tcp`` branch threads it today; supplying
    it with an ``iroh`` locator fails closed rather than silently dialing on a
    fresh identity (use :func:`pancake.iroh.connect_iroh_with_node` to key an
    iroh dial with a shared node). ``codec`` picks the wire grammar for a dial
    on a fresh node; a supplied ``node`` already carries one, and a conflicting
    explicit codec is refused."""
    loc = parse_locator(uri)
    # Fail closed on options a branch cannot honor: dropping a shared node
    # silently would dial on a different identity than `node`, so a capability
    # fetched here and re-gifted is not recognized against the shared gift
    # registry; and the codec is the node's, so a conflict is an error at the
    # call that caused it.
    if node is not None and loc.transport != "tcp":
        raise PancakeError(_ERR_INVALID_ARGUMENT, "connect: a shared node is supported only for tcp locators today")
    if node is not None and codec is not None and codec != node.codec:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'codec "{codec}" conflicts with the shared node\'s "{node.codec}"',
        )
    if codec is not None and loc.transport != "tcp":
        raise PancakeError(_ERR_INVALID_ARGUMENT, "connect: a codec option is supported only for tcp locators today")
    if loc.transport == "iroh":
        if reachability is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"connect: an iroh locator requires a reachability posture: {uri}")
        from . import iroh as _iroh_transport
        return await _iroh_transport.connect_iroh(loc.designator, loc.hints.get("direct-addresses", ""), reachability)
    if loc.transport == "tcp":
        if loc.host is None or loc.port is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"tcp locator designator is not host:port: {loc.designator}")
        return await Connection.connect(
            loc.host, loc.port, node if node is not None else Node(codec=codec or "syrup"),
        )
    raise PancakeError(_ERR_INVALID_ARGUMENT, f'connect: unsupported transport "{loc.transport}"')
