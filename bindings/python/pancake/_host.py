"""Internal: the CapTP :class:`Host` — multi-session CapTP product over the byte-fed
host archive (``libpancake_host``, ADR-0072). The Host owns ``engine.Node``
(the sans-io handoff router). Goblins ``mycapn`` is two roles: the Host is the
endpoint half; ``engine.Node`` is the router-tables half — never a single-type
equation (ADR-0079).

The ``PancakeHost`` owns every cross-session decision: retained identity, the
live-session directory, routing, transparent three-party redemption, and the
gifter half's origination. Each session owns its own gift and replay authority.
What lives here is only what the embedder contract leaves
to the binding: the host handle, the conn-pointer → :class:`Session`
registry the action drain routes by, the vow table the drain's SETTLE/FAIL
arms settle, the action drain itself, gift-id entropy, and the iroh redeem
posture the dial executor reads. The action decode+execute switch lives in
:mod:`pancake._action`; the pump lives in :mod:`pancake._pump`; the dial
executor lives in :mod:`pancake._dial`. :mod:`pancake._session` owns the
:class:`Session` they act on. Import from the :mod:`pancake` package.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
import threading
from collections import deque
from typing import TYPE_CHECKING, Callable, Optional

from . import _constants as _abi
from ._action import _park_actions, _run_action
from ._codec import _codec_id, _ref_to_c
from ._errors import PancakeError, _check_host

if TYPE_CHECKING:
    from ._context import Context
    from ._session import Session
from ._ffi_host import _host
from ._ffi_ocapn import _byte_buf
from ._trampoline import (
    _BehaviorEntry,
    _inside_turn,
    _register_behavior,
    _TRAMPOLINE,
    _unregister_behavior,
)
from ._value import Behavior, Ref
from ._gc import HostGc, bind_host

_ERR_CLOSED = _abi.ERR_CLOSED

# Every connection's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
_HOST_FRAME_CAP = _abi.DEFAULT_FRAME_CAP

# Cap on stored outcomes whose vow is never awaited, so the store cannot grow
# without bound; the oldest un-awaited outcome is evicted at the cap.
_MAX_UNOBSERVED_OUTCOMES = 1024


# A vow row's initial state: registered, not yet awaited and not yet settled.
_MINTED = object()


# Releases the C tier refused inside a behavior callback park here
# (pancake_host_session_release / pancake_host_release are refused mid-turn);
# the next drain — the head of any kick, or a feed's unwind — runs them once
# the enclosing feed unwinds, so a mid-turn close never leaks its C handle.
# Thread-local, not per-host: a Host finalized inside a turn parks its own
# release, and a list on the object being finalized would never drain. The
# thread boundary prevents one Host thread from releasing another's handles.
_release_state = threading.local()


def _parked_releases() -> "deque[Callable[[], None]]":
    releases = getattr(_release_state, "releases", None)
    if releases is None:
        releases = deque()
        _release_state.releases = releases
    return releases


class _VowRow:
    """A host vow's row: registered the instant the vow is minted (the mint IS
    the registration), settled by the drain's SETTLE/FAIL arms. An outcome that
    lands before anyone awaits is held for a late observation instead of
    hanging, and no exception is materialized into a future until a waiter
    exists, so an unobserved broken answer never warns "exception was never
    retrieved"."""

    __slots__ = ("conn", "state")

    def __init__(self, conn):
        # The session the vow was minted on, for closed-vs-broken
        # classification; None for a vow whose home is not a single session.
        self.conn = conn
        # Exactly one of three shapes, so "settled with a live waiter" cannot
        # exist: _MINTED (registered), an asyncio.Future (a parked waiter), or
        # an (ok, payload) tuple (a settled outcome).
        self.state = _MINTED


class Host:
    """The CapTP Host: one identity, one session directory, one routing and redeem
    authority, shared by every session minted against it. It owns
    ``engine.Node`` in the Zig core behind ``libpancake_host`` (ADR-0072);
    this is the host-idiom residue over it — the :class:`Session` registry,
    the vow table, the action drain that performs the I/O the host asks for
    (dial, flush, settle, entropy), and the iroh redeem posture.

    ``seed`` is the Host's 32-byte Ed25519 identity (``None`` draws a fresh
    random one — entropy at the binding boundary, never inside the sans-io
    host). ``codec`` picks the wire grammar every session this Host mints
    negotiates in (``"syrup"`` by default; both ends of a session must
    carry the same value). ``context`` routes every byte the host owns through
    a caller-supplied allocation scope (:class:`Context`).
    ``local_turn_budget`` is ``0`` for unbounded (the default) or a nonzero
    cap on local-turn amplification per drive (ADR-0076)."""

    def __init__(self, seed: Optional[bytes] = None, *, codec: str = "syrup",
                 context: "Optional[Context]" = None, local_turn_budget: int = 0):
        self.seed = seed if seed is not None else secrets.token_bytes(32)
        self.codec = codec
        out = ctypes.c_void_p()
        sbuf, sptr = _byte_buf(self.seed)
        if context is not None:
            _check_host(_host.pancake_host_new_in(
                context._raw, sptr, 32,
                _HOST_FRAME_CAP, 1, _codec_id(codec), local_turn_budget, ctypes.byref(out),
            ))
        else:
            _check_host(_host.pancake_host_new(
                sptr, 32,
                _HOST_FRAME_CAP, 1, _codec_id(codec), local_turn_budget, ctypes.byref(out),
            ))
        self._raw: ctypes.c_void_p | None = out
        # Host-scoped references outlive the session that delivered them; their
        # finalizer queue therefore belongs here, beside the authority registry.
        self._gc = HostGc()
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None
        bind_host(self._gc, self)
        # A node in a caller-supplied context must not outlive it: hold the
        # context so it cannot be collected (and its allocator released) first.
        self._context = context
        # Every live session by its PancakeHostSession address, so a FLUSH
        # action routes to the transport that owns the bytes and a dialed
        # exporter stays reachable for teardown.
        self._sessions: "dict[int, Session]" = {}
        # The vow table the drain's SETTLE/FAIL arms settle.
        self._vows: "dict[int, _VowRow]" = {}
        # FIFO of settled-but-unobserved vow ids, for the eviction cap
        # (a deque: the eviction pops from the head).
        self._unobserved: "deque[int]" = deque()
        # Fire-and-forget drain tasks, retained because the event loop holds
        # tasks only weakly: an unreferenced drain could be collected mid-flight.
        self._kick_tasks: "set[asyncio.Task]" = set()
        # Trampoline ctx of each giftable, by published name, so
        # `Session.published_ref` can find the one it must bind. The registry is
        # process-global, not host-scoped, so nothing drops these when the host
        # dies — release() frees them, or one row leaks per giftable per Host
        # generation.
        self._giftables: "dict[str, int]" = {}
        # Every ordinary Session.spawn/publish trampoline on this Host. Actors
        # live in the Host Vat, so closing the Port that first projected one
        # must not unregister behavior another Port can still call.
        self._hosted: "dict[int, int]" = {}
        # Ctx ids a re-publish displaced. Existing capabilities and gifts still
        # reach the old Host-Vat actor, so its trampoline stays registered until
        # release() drops it with the rest.
        self._displaced_giftables: "list[int]" = []
        # The iroh reachability posture this host uses to redeem a *hint-less*
        # handoff give — one whose exporter location names the exporter by node
        # id alone. Starts at the generated ABI default (Discovery, n0 relays +
        # DNS/pkarr, the maximal-reach choice); a relay-policy deployment
        # lowers it. A hinted give always dials Direct and ignores it. Stored
        # as the numeric value so the core stays free of the optional iroh
        # module.
        self._redeem_reachability = _abi.IROH_REACH_REDEEM_DEFAULT

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHost handle. Binding-internal: :class:`Session`
        mints and drives sessions against it. Raises once the host is
        released, rather than handing out the null the field then holds."""
        if self._raw is None:
            raise PancakeError(_ERR_CLOSED, "the host has been released")
        return self._raw

    @property
    def raw_or_none(self):
        """Raw handle or ``None`` for the finalizer-safe GC seam."""
        return self._raw

    @property
    def released(self) -> bool:
        return self._raw is None

    @property
    def gc(self) -> HostGc:
        """Host-owned distributed-GC state. Binding-internal."""
        return self._gc

    def schedule_on_loop(self, run) -> None:
        """Hop a finalizer drain onto the Host's event loop."""
        loop = self._loop
        if loop is None:
            return
        try:
            loop.call_soon_threadsafe(run)
        except RuntimeError:
            pass

    def release(self) -> None:
        """Release the host and everything it owns — every still-open
        session (each parked vow breaks inside), the vow map, parked
        actions, and the giftable rows. Usually unnecessary (a dropped
        :class:`Host` is reclaimed by the collector), but a host created in a
        caller-supplied :class:`Context` must be released before that context.
        Called from inside a behavior callback — where the C tier refuses the
        release — it parks the release for the enclosing feed's unwind instead
        of leaking the handle. Idempotent."""
        if self._raw:
            # Sessions first: each releases its own handle, and a handle
            # outliving the Host it belongs to is a free of freed memory.
            self.close_sessions()
            raw, self._raw = self._raw, None
            def release_host() -> None:
                _host.pancake_host_release(raw)
                for ctx in self._giftables.values():
                    _unregister_behavior(ctx)
                self._giftables.clear()
                for ctx in self._displaced_giftables:
                    _unregister_behavior(ctx)
                self._displaced_giftables.clear()
                for ctx in self._hosted.values():
                    _unregister_behavior(ctx)
                self._hosted.clear()
            if _inside_turn():
                self.park_release(release_host)
            else:
                release_host()

    def __del__(self):
        self.release()

    @property
    def redeem_reachability(self) -> int:
        """The iroh reachability posture this host uses to redeem a *hint-less*
        handoff give (the exporter named by node id alone, with no
        direct-address hints). Defaults to ``Reachability.DISCOVERY`` (n0
        relays + DNS/pkarr); set ``Reachability.DISCOVERY_NO_RELAY`` to honor a
        no-relay deployment policy. A hinted give always dials
        ``Reachability.DIRECT`` and ignores it. Assign a
        :class:`pancake.iroh.Reachability` (or its int)."""
        return self._redeem_reachability

    @redeem_reachability.setter
    def redeem_reachability(self, reachability) -> None:
        self._redeem_reachability = int(reachability)

    def set_self_designator(self, designator: str) -> None:
        """Record the designator this host's dials sign as their own dialable
        address (a host that also listens); ``listen`` / ``listen_iroh`` /
        ``listen_keyed_tcp`` set it so a partner's crossed-hellos table can
        recognize this host. Binding-internal."""
        data = designator.encode()
        # Empty resets to the unreachable-client placeholder; keep the NULL the
        # header documents for that arm.
        buf, ptr = _byte_buf(data) if data else (None, None)
        _check_host(_host.pancake_host_set_self_designator(self._raw, ptr, len(data)))

    def set_session_limits(self, max_frame_bytes: int = 0, queue_cap: int = 0) -> None:
        """Selective session-limit knobs (ADR-0082). Pass 0 to leave a field
        unchanged. Affects peers minted after this call."""
        _check_host(_host.pancake_host_set_session_limits(
            self._raw, int(max_frame_bytes), int(queue_cap)))

    def designator(self) -> str:
        """The canonical key designator (64 lowercase hex digits) for this
        node's identity seed — what a keyed-tcp locator names as its
        designator (ADR-0075)."""
        out = (ctypes.c_ubyte * 64)()
        buf, ptr = _byte_buf(self.seed)
        _check_host(_host.pancake_host_designator_from_seed(ptr, 32, out, 64))
        return bytes(out).decode("ascii")

    def publish_giftable(self, name: str, behavior: Behavior) -> None:
        """Host ``behavior`` once and bind ``name`` as a Host-wide alias.

        Fetch lazily projects the actor onto a session. A deposited gift keeps
        that exact actor when a recipient later withdraws over its own exporter
        session (ADR-0009)."""
        # A giftable is bound to no single session: its forwards always go
        # through the host, and a turn it runs belongs to whichever session
        # the deliver arrived on.
        ctx = _register_behavior(_BehaviorEntry(run=behavior, resolve_local=None))
        data = name.encode()
        buf, ptr = _byte_buf(data)
        try:
            _check_host(_host.pancake_host_publish(
                self._raw, ptr, len(data),
                _TRAMPOLINE, ctypes.c_void_p(ctx), None,
            ))
        except BaseException:
            # free = NULL: the C tier never owns the row, so a refused publish
            # must drop it here or the registry pins the behavior forever.
            _unregister_behavior(ctx)
            raise
        prior = self._giftables.get(name)
        if prior is not None:
            # Replacement moves discovery only. Existing capabilities and
            # deposited gifts can still call the old actor.
            self._displaced_giftables.append(prior)
        self._giftables[name] = ctx
        self.schedule_kick()

    # ── Session registry ────────────────────────────────────────────────────

    def register_session(self, ptr: int, session: "Session") -> None:
        """Track a live session by its conn address. Binding-internal: the
        :class:`Session` constructor calls it."""
        self._sessions[ptr] = session

    def unregister_session(self, ptr: int) -> None:
        """Stop tracking a released session. Binding-internal."""
        self._sessions.pop(ptr, None)

    def exporter_for(self, ref: Ref) -> "Optional[Session]":
        """The live :class:`Session` homing remote ``ref``, or ``None`` for a
        local, stale, foreign-Host, or closed-session capability.

        The answer is deterministic (ADR-0088): the reply's own token carries
        which connection it lives on, so :meth:`Session.send_redeeming` resolves
        the exact exporter session it should host its back-channel on. There is
        no capture window and no dependence on which dial finished first, so it
        is right with several redeems in flight, and it finds an exporter a
        prior redeem already dialed -- a cache hit that opens no new connection.
        :meth:`Session.send_redeeming` suppresses its own sending session and
        surfaces only a different exporter. Binding-internal."""
        c_ref = _ref_to_c(ref._live())
        out = ctypes.c_void_p()
        _check_host(_host.pancake_host_reference_exporter(
            self.raw, ctypes.byref(c_ref), ctypes.byref(out),
        ))
        # The handle is host-owned and lives with the exporter session, so the
        # registry lookup is the whole answer: a pointer with no live row is a
        # session this binding no longer holds, which reads as no route.
        return self._sessions.get(out.value) if out.value else None

    def close_sessions(self) -> None:
        """Close every session this Host holds -- the ones an application
        opened and the ones the Host dialed for redeems alike. Each close
        releases that session's handle, so this must run before the Host
        handle goes. Binding-internal: :meth:`release` sweeps them."""
        for conn in list(self._sessions.values()):
            conn.close_transport()

    # ── The vow table ──────────────────────────────────────────────────────────

    def vow_minted(self, vow: int, conn: "Optional[Session]") -> None:
        """Record a freshly minted vow so the drain can route its completion.
        Runs in the same synchronous block as the minting FFI call, so no drain
        can pop the completion first. Binding-internal."""
        self._vows[vow] = _VowRow(conn)

    def await_vow(self, vow: int) -> "asyncio.Future":
        """A future for the vow's eventual outcome: the fulfilled wire value,
        or an exception — :class:`VowBroken` for a partner break, the typed
        ``ERR_CLOSED`` :class:`PancakeError` when the settle was the
        disconnect's own break. Settles immediately from the recorded state
        when the outcome already landed. Binding-internal."""
        future = asyncio.get_running_loop().create_future()
        row = self._vows.get(vow)
        if row is None:
            # Evicted (never awaited until past the cap) or never minted here.
            future.set_exception(PancakeError(
                _ERR_CLOSED, "the vow's outcome is gone (unobserved past the cap)"))
            return future
        if not isinstance(row.state, tuple):
            # Minted or re-awaited: park (or replace) the waiter. Replacing a
            # prior future matches the previous overwrite.
            row.state = future
            return future
        del self._vows[vow]
        ok, payload = row.state
        if ok:
            future.set_result(payload)
        else:
            future.set_exception(payload)
        return future

    def settle_vow(self, vow: int, ok: bool, payload) -> None:
        # The drain's settle arms: fire the waiter, or record the outcome for a
        # late observation (bounded FIFO — an outcome nobody ever awaits is
        # evicted at the cap).
        row = self._vows.get(vow)
        if row is None:
            return  # an outcome nobody registered for
        if isinstance(row.state, asyncio.Future):
            waiter = row.state
            del self._vows[vow]
            if not waiter.done():
                if ok:
                    waiter.set_result(payload)
                else:
                    waiter.set_exception(payload)
            return
        # Minted, or an already-settled row re-settled: record for a late
        # observation.
        row.state = (ok, payload)
        self._unobserved.append(vow)
        while len(self._unobserved) > _MAX_UNOBSERVED_OUTCOMES:
            oldest = self._unobserved.popleft()
            stale = self._vows.get(oldest)
            # Only evict a settled row still parked unobserved; an observed one
            # is gone.
            if stale is not None and isinstance(stale.state, tuple):
                del self._vows[oldest]

    def vow_session_closing(self, vow: int) -> bool:
        """Whether the vow's home connection is tearing down — FAIL arms
        classify those breaks as ERR_CLOSED. Binding-internal."""
        row = self._vows.get(vow)
        return row is not None and row.conn is not None and row.conn.is_closing

    def get_session(self, ptr: int):
        """Look up a live session by conn address. Binding-internal: the
        action drain's FLUSH/CLOSE arms route through it."""
        return self._sessions.get(ptr)

    # ── The action drain (the one loop rule) ──────────────────────────────────

    def park_release(self, release: "Callable[[], None]") -> None:
        """Park a C release the host refused inside a behavior callback; the
        next drain — the head of :meth:`kick_actions`, or the feed's unwind —
        runs it where it is legal. The parked list is thread-local (see
        ``_parked_releases``), so independent Host threads cannot drain one
        another's callback-time releases. Binding-internal."""
        _parked_releases().append(release)

    def drain_parked_releases(self) -> None:
        """Run every parked release, always outside a callback frame where the
        C tier accepts them. Called at the head of :meth:`kick_actions` and
        right after a feed returns. Binding-internal."""
        if _inside_turn():
            return
        releases = _parked_releases()
        while releases:
            releases.popleft()()

    def pending_release_count(self) -> int:
        """How many releases are parked — test observability for the mid-turn
        close park. Binding-internal."""
        return len(_parked_releases())

    def schedule_kick(self) -> None:
        """Kick the action drain from a synchronous verb: schedule it as its
        own task, retained until done. Binding-internal."""
        if _inside_turn() or not self._raw:
            return
        try:
            task = asyncio.get_running_loop().create_task(self.kick_actions())
        except RuntimeError:
            # No running loop (a sync teardown path); the next verb drains.
            return
        self._kick_tasks.add(task)
        task.add_done_callback(self._kick_tasks.discard)

    async def kick_actions(self) -> None:
        """Run the shared C action drain, then honor each parked arm. Reentrant
        on purpose: the DIAL arm's dial executor establishes a whole new
        connection *inside* an action, and that establish must itself drain
        (its start-session FLUSH) — a single-flighted drain would await its own
        completion there. Arms are parked under ``pancake_host_pump_drain``
        (sync hooks only) and awaited after the C loop returns, so overlapping
        kickers never await inside the C callback. Re-parks until empty: a
        NEED_GIFT_ID's ``provide_gift_id`` can queue FLUSH legs after the C
        drain returns (same as Racket's ``drain-host-actions!``). A no-op
        inside a hosted turn: the host refuses the driving verbs there, and
        everything the turn enqueued pumps when the enclosing feed unwinds
        into this same drain. Binding-internal."""
        if _inside_turn():
            return
        # Parked releases run first — before the raw-handle check, because a
        # mid-turn Host.release cleared `_raw` while parking the actual free.
        self.drain_parked_releases()
        if not self._raw:
            return
        while True:
            parked = _park_actions(self)
            if not parked:
                return
            for action in parked:
                # One failing action must not strand the rest of the drain: a
                # FLUSH to a session whose socket just died fails here while
                # the actions behind it belong to other, live sessions. The
                # failed session tears itself down through its own serve loop
                # (a DIAL failure is reported to the core inside the arm).
                try:
                    await _run_action(self, action)
                except Exception:  # noqa: BLE001 — the drain reaches every action
                    pass
