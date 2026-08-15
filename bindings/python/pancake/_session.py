"""Internal: the application surface over the multi-session host family
(ADR-0072, loaded from ``libpancake_host``).

This is what an application holds: :class:`Session` and its verbs
(``fetch``/``send``/``tell``/``spawn``/``publish``/``enliven``/``serve``/
``close``), plus mint/handshake (``establish_*``). Runtime composition and
connection setup live in :mod:`pancake._dial`; transport modules own their
listener fronts. The
:class:`RemotePromise` handle, remote-send mint, and fetch/enliven wait live
in :mod:`pancake._promise`. Spawn/publish hosting, local send/tell, Host-ref
dispatch, and ADR-0064 proxy factories live in :mod:`pancake._trampoline`. The
byte-fed embedder pump — read raw bytes off the transport, hand them to the
core's stream delimiter ``pancake_host_session_feed_bytes``, drain the host's
action queue, write what ``take_outbound`` drains — lives in
:mod:`pancake._pump`; :class:`Session` methods wrap it. The host owns
everything else: routing, redemption, gift origination, far vows.
:class:`Host` and :class:`Session` are one mutually-recursive layer; the
Host half lives in :mod:`pancake._host`. Import from the :mod:`pancake`
package.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Awaitable, NamedTuple, Optional

import ctypes

from . import _constants as _abi
from . import _pump
from ._constants import DurableProvenance, _provenance_from_abi
from ._errors import (
    AbortDetail,
    PancakeError,
    _check_host,
    _retain_terminal_failure,
)
from ._ffi_host import _PartnerIdentity, _host
from ._ffi_ocapn import _byte_buf, _Reference
from ._host import Host
from ._locator import _OwnedLocator, Locator
from ._lifecycle import PendingWork, _UNSET, _close_options, _monotonic_ms
from ._promise import RemotePromise, _fetch_like, _listen_far
from ._gc import release_ref
from ._trampoline import (
    Caretaker,
    _attenuate_proxy,
    _caretaker_proxy,
    _dispatch_send,
    _dispatch_tell,
    _inside_turn,
    _spawn_hosted,
    _publish_hosted,
)
from ._value import Behavior, Ref, Argument, _ref_from_id

_ERR_CLOSED = _abi.ERR_CLOSED
_ERR_TIMEOUT = _abi.ERR_TIMEOUT
_HANDSHAKE_TIMEOUT_MS = _abi.HANDSHAKE_TIMEOUT_MS


class SendRedeemingResult(NamedTuple):
    """What :meth:`Session.send_redeeming` hands back: the ``reply`` the send
    settled to, and ``via``, the direct exporter :class:`Session` that reply
    routes to (``None`` when it routes to no live redeemed exporter).

    A :class:`~typing.NamedTuple`, so it unpacks like the pair it is and still
    names its halves at a call site that only wants one of them::

        reply, via = await session.send_redeeming(directory, "introduce", [nick])
    """

    reply: Argument
    via: Optional["Session"]


@dataclass(frozen=True)
class PartnerIdentity:
    """The identity :meth:`Session.partner_identity` proves about the peer on
    the other end of a session.

    ``session_key`` is the partner's session public key. ``designator`` is the
    location designator it signed, which is text such as a hex key or a
    ``host:port`` pair, and it is empty when the partner's location carried
    none. ``locator_record`` is the verbatim location record those two came
    from, empty when the session captured none.

    The partner signs its whole location record, so the designator is bound to
    the session key by that one signature.
    """

    session_key: bytes
    designator: str
    locator_record: bytes
    provenance: "DurableProvenance"

    def durable_identity_authenticated(self) -> bool:
        """Whether the durable identity this partner advertised was
        cryptographically authenticated by the realized channel.

        This is the predicate to ask when an operation requires a proved
        durable peer. It stays correct once each session draws a fresh signing
        key, which a designator-equals-session-key comparison does not.
        """
        return self.provenance is not DurableProvenance.UNAUTHENTICATED


class Session:
    """A live CapTP session with one OCapN partner, the one object an app holds,
    over one byte-fed ``PancakeHostSession`` the shared :class:`Host` minted.

        async with Runtime.open(provider=tcp.provider()) as runtime:
            session = await runtime.connect(tcp.locator("127.0.0.1", 9099))
        session.serve()
        board = await session.fetch("board")
        inbox = session.spawn(lambda verb, args: None)
        await session.send(board, "watch", [inbox])
    """

    def __init__(self, ptr: ctypes.c_void_p, host: Host, transport):
        self._ptr: ctypes.c_void_p | None = ptr
        self._key = ptr.value or 0
        self._host = host
        self._transport = transport
        # A Host may be constructed before asyncio.run(). The first Session
        # driven by a running loop binds that Host to this loop, so sibling
        # sessions and every action drain share one owner.
        host._bind_running_loop()
        self._serve_task: Optional[asyncio.Task] = None
        # Set the moment teardown begins (an application close, or the
        # transport reporting EOF), so a cancelled read is clean and the
        # adapter reports transport loss to the core only once.
        self._closing = False
        self._released = False
        self._release_pending = False
        self._close_future: Optional[asyncio.Future[None]] = None
        # First terminal byte-channel fact. Action execution contains a
        # session-scoped FLUSH refusal, while Session boundaries expose this
        # exact object after physical retirement completes.
        self._wire_failure: Optional[BaseException] = None
        # Ordered terminal evidence. The first object remains the exception
        # every close observer raises; later close/result/transport/serve
        # failures stay available without replacing or flattening it.
        self._terminal_failures: list[BaseException] = []
        self._terminal_failure_count = 0
        self._terminal_joined = False
        self._transport_lost = False
        self._transport_close_started = False
        # The native close barrier outlives any one caller awaiting it. Keep the
        # effect-driving task strongly referenced until it reaches that barrier;
        # asyncio keeps only weak references to otherwise detached tasks.
        self._close_task: Optional[asyncio.Task[None]] = None
        # Serializes transport writes: `flush_outbound` runs from the action
        # drain, the feed-failure choreography, and teardown, and each frame
        # must land whole and in submission order.
        self._write_lock = asyncio.Lock()
        # Opaque Host capability id -> trampoline ctx id for objects this session
        # hosts, so a `Forward` whose target this side hosts composes in
        # process (and a send to a self-spawned Ref runs in process).
        # Capability ids and their actors are Host-scoped. Closing this Port
        # must not erase a trampoline a sibling Port can still call.
        self._hosted = host._hosted
        # Distributed GC (ADR-0063), opt-in and off by default — see `_gc`.
        self._gc_enabled = False
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = (
                asyncio.get_running_loop()
            )
        except RuntimeError:
            self._loop = None
        # Join the Host's registry so a FLUSH action can find the transport and
        # a dialed exporter stays reachable for teardown.
        host.register_session(self._key, self)

    # ── Construction: establish, dial, accept ──────────────────────────────────

    @classmethod
    def _open_dialed_locator(
        cls,
        host: Host,
        locator: Locator,
        transport,
    ) -> "Session":
        # Mint the dialing half over a channel the caller already realized for
        # ``locator``, without driving the handshake — the signed
        # op:start-session is encoded (its FLUSH queued) but nothing has
        # moved. The locator travels whole; the host retains its own dial
        # default for the transport, so no locator policy lives here.
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
        """Mint the dialing half over a channel the caller already realized
        for ``locator``. The handshake is bounded by ``handshake_timeout_ms``
        (``HANDSHAKE_TIMEOUT_MS`` by default; ``None`` or ``0`` waits
        unbounded); overrunning it raises ``PancakeError`` with
        ``ERR_TIMEOUT`` and abandons the half-built connection, exactly as a
        failed handshake does. Binding-internal."""
        session = cls._open_dialed_locator(
            host,
            locator,
            transport,
        )
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
        """Mint the accepting half over a connection the caller's own listener
        produced. ``server_designator`` is the listener's signing designator
        (key for keyed-tcp/iroh; unused for tcp); ``accepted_local_addr`` is
        what accept reported. The host resolves what this accept signs and
        retains it without displacing an explicitly selected advertised
        locator (ADR-0078); no locator policy lives in this binding layer. The
        handshake is bounded by ``handshake_timeout_ms``
        (``HANDSHAKE_TIMEOUT_MS`` by default; ``None`` or ``0`` waits
        unbounded); overrunning it raises ``PancakeError`` with
        ``ERR_TIMEOUT``, which every accept loop skips like any other bad
        partner. Binding-internal."""
        t = transport_name.encode()
        server = server_designator.encode()
        local = accepted_local_addr.encode()
        tbuf, tptr = _byte_buf(t)
        sbuf, sptr = _byte_buf(server)
        lbuf, lptr = _byte_buf(local)
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
                tptr,
                len(t),
                designator_scheme,
                sptr,
                len(server),
                lptr,
                len(local),
                ctypes.byref(out),
            )
        )
        # Every accept path lands here, and each runs the handshake inline in
        # its accept loop, so a silent partner must not park the loop; the
        # bound lives in `_establish`, which both halves reach.
        session = cls(out, host, transport)
        return await session._bind_channel_proof_and_establish(
            verified_channel_key, handshake_timeout_ms
        )

    async def _bind_channel_proof_and_establish(
        self,
        verified_channel_key: "Optional[str]",
        handshake_timeout_ms: "Optional[int]",
    ) -> "Session":
        """Consume post-mint setup under the Session's transport ownership."""
        try:
            # Before the first partner byte, which is the only window a
            # realizer's proof can be weighed in.
            if verified_channel_key:
                self.bind_verified_channel_key(verified_channel_key)
            return await self._establish(handshake_timeout_ms)
        except BaseException:
            # `_establish` owns its own failure path; this additionally covers
            # proof refusal before that path starts. Teardown is idempotent.
            self.close_transport()
            raise

    async def _establish(
        self,
        handshake_timeout_ms: "Optional[int]" = _HANDSHAKE_TIMEOUT_MS,
    ) -> "Session":
        # Drive the freshly opened connection's keyed handshake to an open
        # session, abandoning the connection on any failure (release +
        # transport close) so a rude partner costs one accept, never the
        # listener. The read/feed loop lives in ``_pump._run_handshake``.
        #
        # The one place both halves bound that handshake: a peer that opens the
        # byte channel and then says nothing is the case no failure check can
        # catch — nothing fails, the handshake simply waits — so unbounded it
        # parks the dialer forever, and on the accepting side every later
        # connection behind that one client. A falsy budget is the caller's
        # explicit opt-in to waiting without one. The timeout takes the same
        # abandon path a failed handshake does.
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

    # ── State: the consumer reads only `host`; the rest is a binding-internal
    # seam ──────────────────────────────────────────────────────────────────────
    # The underscore fields (`_ptr`, `_transport`, `_write_lock`,
    # `_hosted`, `_gc`, `_closing`, `_released`) are the private backing store.
    # The non-underscore accessors below are the binding-internal seam the pump,
    # trampoline, and GC reach through: a named tier between the public verbs and
    # the raw storage, so an owning module names the seam rather than reaching a
    # private field, and a consumer holding a Session still sees only the verbs
    # and `host`.

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHostSession handle. Binding-internal seam: the Host's
        DIAL arm reports it through ``pancake_host_dialed``. Raises once the
        session is released, rather than handing out the null the field
        then holds."""
        self._host._assert_owner()
        if self._ptr is None:
            raise PancakeError(_ERR_CLOSED, "the session has been released")
        return self._ptr

    @property
    def host(self) -> Host:
        """The Host shared by this session and its sibling sessions.

        The Host owns the actor runtime and live-session directory; each
        session owns its own gifts and replay state. An application reads this
        property to publish host giftables (:meth:`Host.publish_giftable`),
        share Host configuration across dials, or set the redeem posture.
        """
        return self._host

    @property
    def released(self) -> bool:
        """Whether the host session handle has been released. Binding-internal seam."""
        return self._released

    @property
    def closing_flag(self) -> bool:
        """The Session ``_closing`` flag alone (not ``released``). Binding-internal
        seam for the pump."""
        return self._closing

    @closing_flag.setter
    def closing_flag(self, value: bool) -> None:
        self._closing = value

    @property
    def is_closing(self) -> bool:
        """Whether local transport teardown has begun. Binding-internal pump seam."""
        return self._closing or self._released

    @property
    def session_open(self) -> bool:
        """Whether the keyed handshake has completed and the session is open.
        Binding-internal seam for the pump."""
        self._host._assert_owner()
        return not self._released and _host.pancake_host_session_is_open(self._ptr) == 1

    @property
    def write_lock(self) -> asyncio.Lock:
        """Serializes transport writes. Binding-internal seam for the pump."""
        return self._write_lock

    @property
    def transport(self):
        """Byte-channel transport. Binding-internal seam for the pump."""
        return self._transport

    @property
    def gc(self):
        """Host-owned GC state. Binding-internal seam for promise fetch track."""
        return self._host.gc

    @property
    def gc_enabled(self) -> bool:
        return self._gc_enabled

    @property
    def hosted(self) -> "dict[int, int]":
        """Opaque Host capability id → trampoline ctx. Binding-internal seam."""
        return self._hosted

    def schedule_on_loop(self, run) -> None:
        """Hop ``run`` onto this session's event loop (finalizer → drain).
        Binding-internal seam for GcHandle."""
        loop = self._loop
        if loop is None:
            return
        try:
            loop.call_soon_threadsafe(run)
        except RuntimeError:
            pass  # the loop is closed; teardown reclaims the partner's export

    def guard_open(self) -> None:
        """Raise ERR_CLOSED when the connection is released. Binding-internal
        seam."""
        self._host._assert_owner()
        if self._closing or self._released:
            self.raise_wire_failure()
            raise PancakeError(_ERR_CLOSED, "connection closed")

    # ── The pump ────────────────────────────────────────────────────────────────

    def serve(self) -> "asyncio.Task":
        """Run the inbound loop as a background task: read raw bytes, hand them
        to the core's stream delimiter (behaviors run and vow completions queue
        inside the feed), and drain the action queue. The task completes when
        the CapTP session closes cleanly; started once.

        A loop-backed session (ADR-0112) has no byte pump of its own — the
        native loop reads, feeds, and drains — so its serve task only awaits
        the session's closure, keeping the completes-on-close contract."""
        self._host._assert_owner()
        if self._serve_task is None:
            transport = self._transport
            if getattr(transport, "_driver_loop", None) is not None:
                # Post-open setup is done: tell the loop to start delivering
                # this session's inbound, the byte-fed serve-resume contract
                # spoken at the loop tier.
                transport._driver_loop.serve_session(self._key)
                self._serve_task = asyncio.get_running_loop().create_task(
                    transport.wait_closed(),
                )
            else:
                self._serve_task = asyncio.get_running_loop().create_task(
                    _pump._serve_loop(self),
                )
        return self._serve_task

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of this CapTP session's most recent local dispatch
        failure, or ``None`` when none has been recorded. The flat per-feed
        error code names the failure family; this names the member. Errors
        raised by a refused feed carry it already as ``err.abort``."""
        return _pump.last_abort(self)

    async def flush_outbound(self) -> None:
        """Drain every encoded outbound frame on this CapTP session and write it
        to the transport — how a FLUSH action lands. Writes are serialized, so
        frames stay whole and in submission order. Binding-internal. On a
        loop-backed session one loop step is the flush."""
        try:
            loop_ref = getattr(self._transport, "_driver_loop", None)
            if loop_ref is not None:
                loop_ref.step_now()
                return
            await _pump.flush_outbound(self)
        except BaseException as error:
            self.record_outbound_failure(error)
            self.close_transport()
            raise

    def record_wire_failure(self, error: BaseException) -> None:
        """Retain the exact first terminal failure. Binding-internal pump seam."""
        self._record_terminal_failure(error)
        if self._wire_failure is None:
            self._wire_failure = error

    def _record_terminal_failure(self, error: BaseException) -> None:
        failures = getattr(self, "_terminal_failures", None)
        if failures is None:
            failures = []
            self._terminal_failures = failures
        self._terminal_failure_count = _retain_terminal_failure(
            failures, getattr(self, "_terminal_failure_count", 0), error
        )

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        """Terminal failures in observation order.

        The first item is the exact exception raised by :meth:`close`. Later
        items are cleanup consequences retained by the same Session.
        """
        return tuple(getattr(self, "_terminal_failures", ()))

    @property
    def terminal_failure_count(self) -> int:
        """Total distinct terminal occurrences, including bounded overflow."""
        return getattr(self, "_terminal_failure_count", 0)

    def mark_transport_lost(self) -> None:
        """Make inbound/protocol teardown the terminal owner. Pump seam."""
        self._transport_lost = True

    def record_outbound_failure(self, error: BaseException) -> None:
        """Retain a write failure only when it precedes local/peer teardown."""
        if (
            not self._released
            and not self._transport_close_started
            and not self._transport_lost
        ):
            self.record_wire_failure(error)

    def raise_wire_failure(self) -> None:
        if self._wire_failure is not None:
            raise self._wire_failure

    async def _join_close_barrier(
        self, result: Optional[Awaitable[None]] = None
    ) -> None:
        """Join the terminal result, transport, and serve task in first-cause
        order. A rejected close still retires the wrapper before returning."""
        if getattr(self, "_terminal_joined", False):
            failures = self.terminal_failures
            if failures:
                raise failures[0]
            return
        if self._wire_failure is not None:
            self._record_terminal_failure(self._wire_failure)

        async def join(awaitable: Awaitable[None]) -> None:
            try:
                await asyncio.shield(awaitable)
            except asyncio.CancelledError as error:
                current = asyncio.current_task()
                if current is not None and current.cancelling():
                    raise
                self._record_terminal_failure(error)
            except BaseException as error:
                self._record_terminal_failure(error)

        if result is not None:
            await join(result)
        if not self._released and not self._release_pending:
            self.close_transport()
        wait_closed = getattr(self._transport, "wait_closed", None)
        if wait_closed is not None:
            await join(wait_closed())
        task = self._serve_task
        if task is not None and task is not asyncio.current_task():
            await join(task)
        if self._wire_failure is not None:
            self._record_terminal_failure(self._wire_failure)
        self._terminal_joined = True
        failures = self.terminal_failures
        if failures:
            raise failures[0]

    # ── Teardown ────────────────────────────────────────────────────────────────

    async def close(
        self,
        *,
        pending: PendingWork = PendingWork.CANCEL,
        grace: object = _UNSET,
    ) -> None:
        """Close this session's connection and nothing else. A running
        :meth:`serve` completes cleanly; pending vows settle with the typed
        ERR_CLOSED.

        It does not reach a sibling session, and it does not reach the
        connections the Host opened by itself to redeem a handoff -- the
        ``via`` from :meth:`send_redeeming` is one of those.
        :meth:`Runtime.close` ends the Runtime's Host and those sessions."""
        options = _close_options(pending, grace)
        self._host._assert_owner()
        active_close = self._close_future
        if active_close is not None:
            if not self._released:
                ptr = self._ptr
                assert ptr is not None
                _check_host(
                    _host.pancake_host_session_close(
                        ptr,
                        ctypes.byref(options),
                        _monotonic_ms(),
                    )
                )
                self._closing = True
                # The close call escalates pending-work policy while a close
                # driver may already be parked; wake it to re-read progress.
                self._host.signal_close_activity()
                self._start_close_driver()
                self._host.schedule_kick()
            await self._join_close_barrier(active_close)
            return
        else:
            if self._released:
                await self._join_close_barrier()
                return
            ptr = self._ptr
            assert ptr is not None
            loop_ref = getattr(self._transport, "_driver_loop", None)
            if loop_ref is not None:
                await self._join_close_barrier(loop_ref.close_session(ptr, options))
                return
            else:
                close_future = asyncio.get_running_loop().create_future()
                _check_host(
                    _host.pancake_host_session_close(
                        ptr,
                        ctypes.byref(options),
                        _monotonic_ms(),
                    )
                )
                self._closing = True
                self._host.signal_close_activity()
                self._close_future = close_future
                self._start_close_driver()
                self._host.schedule_kick()
                await self._join_close_barrier(close_future)

    def _start_close_driver(self) -> None:
        task = self._close_task
        if task is not None and not task.done():
            return
        task = asyncio.get_running_loop().create_task(self._drive_close())
        self._close_task = task

        def retire(finished: asyncio.Task[None]) -> None:
            if self._close_task is finished:
                self._close_task = None

        task.add_done_callback(retire)

    async def _drive_close(self) -> None:
        try:
            while not self._released:
                ptr = self._ptr
                if ptr is None:
                    break
                # Arm the Host-level waiter before reading progress (the
                # lost-wakeup discipline). Host-wide activity or another
                # session's deadline may wake this loop early; the re-check
                # makes that harmless.
                self._host.arm_close_activity()
                state = ctypes.c_uint32()
                rc = _host.pancake_host_session_close_progress(
                    ptr,
                    _monotonic_ms(),
                    ctypes.byref(state),
                )
                if rc not in (_abi.OK, _abi.ERR_TIMEOUT):
                    _check_host(rc)
                # Drain what the progress call queued (a spent grace escalates
                # into teardown actions). A drain that ran work sets the armed
                # event, so the wait below returns at once and the loop
                # re-checks instead of parking over undrained work.
                await self._host.kick_actions()
                if not self._released:
                    await self._host.wait_close_wake()
        except BaseException as error:
            self.close_transport()
            future = self._close_future
            if future is not None and not future.done():
                future.set_exception(error)

    def _finish_close(self, result: int) -> None:
        future = self._close_future
        if future is None or future.done():
            return
        if self._wire_failure is not None:
            future.set_exception(self._wire_failure)
        elif result == _abi.ERR_TIMEOUT:
            future.set_exception(
                PancakeError(_abi.ERR_TIMEOUT, "finish close exhausted its grace period")
            )
        elif result != _abi.OK:
            future.set_exception(PancakeError(result, "session close failed"))
        else:
            future.set_result(None)

    def _native_owner_did_release(self) -> None:
        """Commit wrapper retirement after the whole native loop was released."""
        self._closing = True
        self._released = True
        self._release_pending = False
        self._ptr = None
        if not self._transport_close_started:
            self._transport_close_started = True
            try:
                self._transport.close()
            except BaseException as error:
                self.record_wire_failure(error)

    def close_transport(self) -> None:
        """Close just this session, without touching the Host's other
        sessions: stop the transport first, then retire the Host's entry and
        free the host handle (the core settles any still-parked far vows during
        release), so no foreign call touches a freed
        session. Called from inside a behavior callback — where the C tier
        refuses the release — it parks the release on the Host; the enclosing
        feed's unwind runs it, so a mid-turn close never leaks the handle.
        Binding-internal."""
        if self._host._schedule_cleanup(self.close_transport):
            return
        self._host._assert_owner()
        self._closing = True
        if not self._transport_close_started:
            self._transport_close_started = True
            try:
                self._transport.close()
            except BaseException as error:
                self.record_wire_failure(error)
        if self._released or self._release_pending:
            return
        ptr = self._ptr
        loop_ref = getattr(self._transport, "_driver_loop", None)

        def commit_release(p=ptr):
            try:
                if loop_ref is not None:
                    loop_ref._native_session_release(p)
                else:
                    _check_host(_host.pancake_host_session_release(p))
            except BaseException as error:
                self._release_pending = False
                self.record_wire_failure(error)
                future = self._close_future
                if future is not None and not future.done():
                    future.set_exception(error)
                self._host.signal_close_activity()
                return
            self._released = True
            self._release_pending = False
            self._host.unregister_session(self._key)
            self._ptr = None
            # The released session is retired close-relevant state; wake any
            # parked close driver.
            self._host.signal_close_activity()
            self._host.schedule_kick()

        self._release_pending = True
        if _inside_turn():
            self._host.park_release(commit_release)
        else:
            commit_release()

    async def __aenter__(self) -> "Session":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    # ── Hosting: spawn, publish, and the proxy verbs ───────────────────────────

    def spawn(self, behavior: Behavior) -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback. The
        returned identity is opaque and Host-scoped; wire export positions stay
        inside pancake. Callable from inside a served turn (a factory's
        ``create`` minting the task it replies with)."""
        return _spawn_hosted(self, behavior)

    def publish(self, name: str, behavior: Behavior) -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        return _publish_hosted(self, name, behavior)

    def caretaker(self, target: Ref) -> Caretaker:
        """Wrap ``target`` (local or far) in a revocable caretaker (ADR-0064).
        Returns a :class:`Caretaker` whose ``proxy`` is an ordinary capability
        to hand a partner; every call through it forwards to ``target`` until
        :meth:`Caretaker.revoke`, after which each breaks with ``Revoked``.
        ``target`` may be a capability imported over the wire — the proxy
        forwards transparently — so this hands out a revocable view of
        authority you do not own locally. The proxy is a plain spawned actor,
        so it answers a local call exactly as a partner's does."""
        return _caretaker_proxy(self.spawn, target)

    def attenuate(self, target: Ref, verbs: "list[str]") -> Ref:
        """Wrap ``target`` (local or far) in an attenuator (ADR-0064): a proxy
        that forwards only the calls whose verb is in ``verbs`` and breaks
        every other with ``Attenuated``. Returns the proxy capability to hand a
        partner. The proxy is a plain spawned actor."""
        return _attenuate_proxy(self.spawn, target, verbs)

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
        return await _fetch_like(
            self,
            name.encode(),
            name,
            _host.pancake_host_session_fetch,
            track=True,
        )

    async def enliven(self, sturdyref: str) -> Ref:
        """Enliven a sturdyref against this session (ADR-0098): bring the
        durable ``(peer, swissnum)`` to life as a live :class:`Ref`. The host
        verifies the complete locator against this session before consulting
        its dedup cache -- a repeat enliven of the same swissnum on this session
        short-circuits with no wire traffic (its completion is queued before
        the minting call returns). The session must already be open to the
        sturdyref's peer; this session-level call never dials. Raises
        :class:`VowBroken` when the partner breaks the enliven,
        and :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        return await _fetch_like(
            self,
            sturdyref.encode(),
            sturdyref,
            _host.pancake_host_session_enliven,
            track=False,
        )

    def send(
        self, target: "Ref | RemotePromise", verb: str, args: "Optional[list]" = None
    ) -> RemotePromise:
        """Eventual-send ``verb(args)`` to ``target`` and return a
        :class:`RemotePromise` for the reply. ``await`` it for the value (a
        :class:`Ref` if the partner returned a capability; raises
        :class:`VowBroken` on a partner break).

        ``target`` is a capability :class:`Ref` *or* a :class:`RemotePromise`
        from an earlier send: passing the latter pipelines (ADR-0007) -- the
        call is addressed at the answer that send will resolve, so a dependent
        chain costs one round trip instead of one per link. ``args`` may
        contain :class:`Ref`\\ s. A :class:`Ref` this session spawned runs
        in process; a partner's rides the wire, and a redeemed or fetched token
        routes to the exporter session that hosts it, transparently.

        The deliver is queued now; its bytes leave the wire when the returned
        handle -- or any send pipelined behind it -- is first observed (awaited
        or gathered), so a pipelined batch travels together."""
        # A send that cannot be issued comes back as a failed handle, not a
        # raise. `send` must return synchronously so a caller can pipeline at
        # the answer before it settles (ADR-0050), so it cannot be `async` —
        # but an awaitable whose failure arrives synchronously is a trap:
        # `gather(*[s.send(...) for s in sessions], return_exceptions=True)`
        # raises inside the comprehension, before `gather` is ever entered.
        try:
            self.guard_open()
            self._host.gc.drain_gc()
            args = list(args or [])
            return _dispatch_send(self, target, verb, args)
        except Exception as err:  # noqa: BLE001 - reported through the handle
            return RemotePromise.failed(err)

    def listen(self, target: Ref) -> RemotePromise:
        """Listen on a far capability this session holds (CapTP
        ``op:listen``): the returned handle settles with the listen
        notification, which may be any value, not only a capability. In 1.0,
        the target may be a far promise or live far object; in pancake-next,
        the target must be a promise. A re-gifted promise routes to its
        exporter session transparently."""
        try:
            self.guard_open()
            self._host.gc.drain_gc()
            return _listen_far(self, target)
        except Exception as err:  # noqa: BLE001 - reported through the handle
            return RemotePromise.failed(err)

    async def send_redeeming(
        self,
        target: "Ref | RemotePromise",
        verb: str,
        args: "Optional[list]" = None,
    ) -> SendRedeemingResult:
        """Eventual-send ``verb(args)`` to ``target``, await the reply, and also
        surface the direct :class:`Session` a three-party-handoff redeem opened
        to answer it.

        When ``target`` answers with a handoff give (a room's ``introduce``,
        say), the binding redeems it by dialing the exporter, and the reply
        settles to a capability that routes over a fresh direct session. The
        byte connection is otherwise internal. This returns the session as
        ``via``, so you can host your own objects in the same session as the
        redeemed capability. That is the one place a reply capability handed
        back to the exporter is valid: an OCapN near reference names a position
        in one specific session, so a :meth:`spawn` on *this* session is not a
        live export in the exporter's, and the host refuses that send rather
        than mis-encode it.

        ``via`` is resolved from the reply's own token, which carries the
        session it lives in, not from watching which dial ran during the
        send. So it is right with several redeems in flight at once, and it
        still finds the exporter when the reply reused a session an earlier
        redeem already dialed -- a cache hit that opens no new session and
        that a which-dial-ran guess could never see. ``via`` is ``None`` when
        the reply is not a redeemed-handoff capability (an ordinary far reply,
        or a value that is no capability at all) or its exporter session is
        already gone; fall back to this session there::

            reply, via = await session.send_redeeming(directory, "introduce", [nick])
            where = via or session
            inbox = where.spawn(on_reply)          # hosted where the reply lives
            await where.send(reply, "dm", [text, inbox])
        """
        self.guard_open()
        reply = await self.send(target, verb, args)
        via = self._host.exporter_for(reply) if isinstance(reply, Ref) else None
        if via is self:
            via = None
        return SendRedeemingResult(reply, via)

    async def tell(self, target: Ref, verb: str, args: "Optional[list]" = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        self.guard_open()
        self._host.gc.drain_gc()
        args = list(args or [])
        await _dispatch_tell(self, target, verb, args)
        self.raise_wire_failure()

    def set_exporter_locator(self, locator: "Optional[Locator]") -> None:
        """Override the exporter location with a complete typed locator.
        ``None`` restores the partner's signed location."""
        self.guard_open()
        if locator is None:
            _check_host(
                _host.pancake_host_session_set_exporter_location(self._ptr, None)
            )
            return
        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.pancake_host_session_set_exporter_location(
                    self._ptr, owned.borrow_view()
                )
            )

    # ── Who the partner is, as the handshake proved it ─────────────────────────

    def partner_identity(self) -> PartnerIdentity:
        """Who this session is talking to, as the handshake proved it rather
        than as the partner claims it.

        A partner opens a keyed session by signing its own location record, and
        the engine verifies that signature before the session opens. So a value
        returned here always means the signature was checked, and because the
        signed record covers the whole location, the designator is bound to the
        session key by that same signature. This is how a server refuses a
        caller that claims a locator it does not own: read the identity, then
        compare what the caller says about itself against what it proved.

        The byte views the library hands back belong to the session, so they
        are copied into Python-owned values before this returns.

        Raises when the partner's ``op:start-session`` has not arrived with a
        key yet, and raises as well when the session was opened without partner
        verification, because then there is no proved identity to read.
        """
        self.guard_open()
        info = _PartnerIdentity()
        _check_host(
            _host.pancake_host_session_partner_identity(
                self._ptr,
                ctypes.byref(info),
            )
        )

        def owned(ptr, length) -> bytes:
            return ctypes.string_at(ptr, length) if ptr and length else b""

        return PartnerIdentity(
            session_key=owned(info.session_key, info.session_key_len),
            designator=owned(info.designator, info.designator_len).decode(
                errors="replace"
            ),
            locator_record=owned(info.locator_record, info.locator_record_len),
            provenance=_provenance_from_abi(info.provenance),
        )

    def bind_verified_channel_key(self, designator: str) -> None:
        """Testify what proved this connection's far end, when your own
        transport proved one.

        pancake does not open your sockets, so it cannot see what opening them
        established. An iroh connection completes only with the holder of the
        node id you dialed or accepted, and that is a stronger fact than
        anything a partner can claim about itself -- but only you hold it. Pass
        the node id here and :meth:`partner_identity` reports
        ``authenticated-transport``; withhold it and the same session reports
        ``unauthenticated``.

        ``designator`` is that identity as a locator writes it, which is
        exactly what the iroh transport's remote node id hands you.

        Call it after opening the session and before feeding the first byte
        from the partner. It raises afterwards, because by then the handshake
        this evidence was for has already been judged. Naming a second,
        different identity raises too: one connection has one far end. Naming
        the same one twice is the same statement made twice and is fine.
        """
        self.guard_open()
        raw = designator.encode()
        buf, ptr = _byte_buf(raw)
        _check_host(
            _host.pancake_host_session_bind_verified_channel_key(
                self._ptr,
                ptr,
                len(raw),
            )
        )

    # ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

    def with_gc(self) -> "Session":
        """Opt this session into distributed GC (ADR-0063), off by default.
        Once on, a far capability returned by :meth:`fetch` releases its import
        to the partner -- a single ``op:gc-exports`` delta, routed through the
        host to the import's home connection -- when the runtime reclaims the
        last :class:`Ref` to it, so the partner can release the matching
        export. CPython's refcounting makes that release prompt on the last
        ``del``. Capabilities lifted elsewhere (a ``send`` reply, a delivered
        argument, an ``enliven`` result the dedup cache owns) are outside this
        seam. Returns ``self`` for chaining."""
        self._gc_enabled = True
        return self

    def published_ref(self, name: str) -> "Ref | None":
        """A :class:`Ref` for the object published under ``name`` on this
        session, or ``None`` when nothing is published there.

        :meth:`publish` returns its own ``Ref``, so this is for the other
        publisher: :meth:`Host.publish_giftable` hosts one actor under a
        Host-wide alias and returns nothing. Reading its Host identity lazily
        projects it onto this session so an application can pass it as an
        ordinary capability argument; no enrollment step exists.

        A :meth:`send` to the returned ``Ref`` runs the behavior in process rather
        than over the wire, and a giftable registered no session, so
        ``current_session()`` inside it is ``None``. Pass it on as a capability
        argument; a behavior written to answer over the connection
        its call arrived on will not answer a local send.
        """
        self.guard_open()
        data = name.encode()
        buf, ptr = _byte_buf(data)
        out = _Reference()
        try:
            rc = _host.pancake_host_session_published_ref(
                self._ptr, ptr, len(data), ctypes.byref(out)
            )
        finally:
            del buf
        if rc == _abi.ERR_NOT_FOUND:
            return None
        _check_host(rc)
        ref = _ref_from_id(out.id)
        # Join the host's giftable to the identity this session surfaced, so a
        # later local send to the returned Ref composes in process.
        if ref.id not in self._hosted:
            ctx = self._host._giftables.get(name)
            if ctx is not None:
                self._hosted[ref.id] = ctx
        return ref

    def release(self, ref: Ref) -> None:
        """Give a capability back to the partner, now, because this
        application is done holding it.

        Releases one application retain. For a remote capability the Host emits
        any required ``op:gc-exports``; a local capability needs no wire
        message. :meth:`with_gc` does this too, but only for a
        :meth:`fetch` result and only when the runtime reclaims the handle;
        this is deterministic and works for any far capability this session
        holds, including one lifted from a delivered argument or a reply.

        ``ref`` is spent afterwards and every use of it raises. The Host
        generation makes the stale id fail closed; the binding rejects it before
        crossing the ABI.

        A capability from another Host, or one already released, is a caller
        error and raises ``ValueError``.
        """
        if ref.released:
            raise ValueError("capability already released")
        release_ref(self._host.raw, ref)
        self._host.gc.disarm(ref)
        ref._mark_released()
