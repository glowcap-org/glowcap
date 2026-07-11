"""Internal: the CapTP :class:`Node` — pancake's analogue of Goblins'
``mycapn``, one per node — over the byte-fed host archive
(``libpancake_driver``, ADR-0072).

The ``PancakeHost`` owns every decision: the retained identity, the shared
gift registry, routing, transparent three-party redemption, and the gifter
half's origination. What lives here is only what the embedder contract leaves
to the binding: the host handle, the conn-pointer → :class:`Connection`
registry the action drain routes by, the vow table the drain's SETTLE/FAIL
arms settle, the action drain itself, gift-id entropy, and the iroh redeem
posture the dial executor reads. The pump and the dial executor live in
:mod:`pancake._connection`, which owns the :class:`Connection` they act on.
Re-exported from the :mod:`pancake` package; import from there.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
from collections import deque
from typing import Callable, NamedTuple, Optional

from . import _constants as _abi
from ._codec import _arg_from_c, _codec_id
from ._errors import PancakeError, VowBroken, _check_host
from ._ffi_driver import _host, _HostAction
from ._ffi_ocapn import _byte_buf
from ._trampoline import _BehaviorEntry, _inside_turn, _register_behavior, _TRAMPOLINE

_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED
_HOST_ACTION_DIAL = _abi.HOST_ACTION_DIAL
_HOST_ACTION_FLUSH = _abi.HOST_ACTION_FLUSH
_HOST_ACTION_NEED_GIFT_ID = _abi.HOST_ACTION_NEED_GIFT_ID
_HOST_ACTION_SETTLE = _abi.HOST_ACTION_SETTLE
_HOST_ACTION_FAIL = _abi.HOST_ACTION_FAIL
_HOST_ACTION_CLOSE = _abi.HOST_ACTION_CLOSE

# Every connection's maximum admissible frame, mirroring the engine's default
# session limit; the core's stream delimiter (`pancake_host_conn_feed_bytes`)
# enforces it while it scans, so a hostile stream cannot grow an inbox past it.
_HOST_FRAME_CAP = 2 ** 20

# Cap on stored outcomes whose vow is never awaited, so the store cannot grow
# without bound; the oldest un-awaited outcome is evicted at the cap.
_MAX_UNOBSERVED_OUTCOMES = 1024


class _VowRow:
    """A host vow's row: registered the instant the vow is minted (the mint IS
    the registration), settled by the drain's SETTLE/FAIL arms. An outcome that
    lands before anyone awaits is stored, so a late observation settles from
    the recorded state instead of hanging — and no exception is materialized
    into a future until a waiter exists, so an unobserved broken answer never
    warns "exception was never retrieved"."""

    __slots__ = ("conn", "state", "waiter")

    def __init__(self, conn):
        # The connection the vow was minted on, for closed-vs-broken
        # classification; None for a vow whose home is not a single connection.
        self.conn = conn
        self.state: "Optional[tuple[bool, object]]" = None  # (ok, payload)
        self.waiter: "Optional[asyncio.Future]" = None


class _PoppedAction(NamedTuple):
    """One embedder action popped off the host, every borrowed view copied out
    (and a SETTLE's value lifted) before the next ``pancake_host_next_action``
    call can free them."""

    kind: int
    ticket: int
    conn_ptr: int
    locator: str
    transport: str
    designator: str
    hint: str
    value: object
    message: str


def _view(ptr, length) -> str:
    # The bytes originate in a partner-authored give, so decode leniently
    # rather than let hostile bytes raise mid-drain.
    return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""


class Node:
    """The CapTP node: one identity, one gift registry, one routing and redeem
    authority, shared by every connection minted against it. The cross-node
    machinery lives in the Zig core behind ``libpancake_driver`` (ADR-0072);
    this is the host-idiom residue over it — the :class:`Connection` registry,
    the vow table, the action drain that performs the I/O the host asks for
    (dial, flush, settle, entropy), and the iroh redeem posture.

    ``seed`` is the node's 32-byte Ed25519 identity (``None`` draws a fresh
    random one — entropy at the binding boundary, never inside the sans-io
    host). ``codec`` picks the wire grammar every connection this node mints
    negotiates in (``"syrup"`` by default; both ends of a connection must
    carry the same value). ``context`` routes every byte the host owns through
    a caller-supplied allocation scope (:class:`Context`)."""

    def __init__(self, seed: Optional[bytes] = None, *, codec: str = "syrup",
                 context: "Optional[Context]" = None):
        self.seed = seed if seed is not None else secrets.token_bytes(32)
        self.codec = codec
        out = ctypes.c_void_p()
        sbuf, sptr = _byte_buf(self.seed)
        if context is not None:
            _check_host(_host.pancake_host_new_in(
                context._raw, sptr, 32,
                _HOST_FRAME_CAP, 1, _codec_id(codec), ctypes.byref(out),
            ))
        else:
            _check_host(_host.pancake_host_new(
                sptr, 32,
                _HOST_FRAME_CAP, 1, _codec_id(codec), ctypes.byref(out),
            ))
        self._raw = out
        # A node in a caller-supplied context must not outlive it: hold the
        # context so it cannot be collected (and its allocator released) first.
        self._context = context
        # Every live connection by its PancakeHostConn address, so a FLUSH
        # action routes to the transport that owns the bytes and a dialed
        # exporter stays reachable for teardown.
        self._connections: "dict[int, Connection]" = {}
        # The vow table the drain's SETTLE/FAIL arms settle.
        self._vows: "dict[int, _VowRow]" = {}
        # FIFO of settled-but-unobserved vow ids, for the eviction cap
        # (a deque: the eviction pops from the head).
        self._unobserved: "deque[int]" = deque()
        # One scratch action struct reused across pops: the drain runs one at
        # a time on the loop thread, and every borrowed view is lifted into
        # Python values before the next pop overwrites it.
        self._action_scratch = _HostAction()
        # Fire-and-forget drain tasks, retained because the event loop holds
        # tasks only weakly: an unreferenced drain could be collected mid-flight.
        self._kick_tasks: "set[asyncio.Task]" = set()
        # Releases the C tier refused inside a behavior callback park here
        # (pancake_host_conn_release / pancake_host_release are refused
        # mid-turn); the drain runs them once the enclosing feed unwinds, so a
        # mid-turn close never leaks its C handle. Mirrors the Rust binding's
        # parked-release list.
        self._parked_releases: "list[Callable[[], None]]" = []
        # The iroh reachability posture this node uses to redeem a *hint-less*
        # handoff give — one whose exporter location names the exporter by node
        # id alone. Defaults to Discovery (n0 relays + DNS/pkarr), the
        # maximal-reach choice; a relay-policy deployment lowers it. A hinted
        # give always dials Direct and ignores it. Stored as the numeric value
        # so the core stays free of the optional iroh module.
        self._redeem_reachability = 1  # Reachability.DISCOVERY

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHost handle. Binding-internal: :class:`Connection`
        mints and drives connections against it."""
        return self._raw

    def release(self) -> None:
        """Release the host and everything it owns — every still-open
        connection (each parked vow breaks inside), the vow map, parked
        actions, and the giftable rows. Usually unnecessary (a dropped
        :class:`Node` is reclaimed by the collector), but a node created in a
        caller-supplied :class:`Context` must be released before that context.
        Called from inside a behavior callback — where the C tier refuses the
        release — it parks the release for the enclosing feed's unwind instead
        of leaking the handle. Idempotent."""
        if self._raw:
            raw, self._raw = self._raw, None
            if _inside_turn():
                self._park_release(lambda: _host.pancake_host_release(raw))
            else:
                _host.pancake_host_release(raw)

    def __del__(self):
        self.release()

    @property
    def redeem_reachability(self) -> int:
        """The iroh reachability posture this node uses to redeem a *hint-less*
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
        """Record the designator this node's dials sign as their own dialable
        address (a node that also listens); ``listen`` / ``listen_iroh`` set it
        to the bound address so a partner's crossed-hellos table can recognize
        this node. Binding-internal."""
        data = designator.encode()
        # Empty resets to the unreachable-client placeholder; keep the NULL the
        # header documents for that arm.
        buf, ptr = _byte_buf(data) if data else (None, None)
        _check_host(_host.pancake_host_set_self_designator(self._raw, ptr, len(data)))

    def publish_giftable(self, name: str, behavior: "Behavior") -> None:
        """Publish ``behavior`` under ``name`` on every connection of this node
        — those open now and any accepted later — so a recipient can withdraw a
        gift naming it on a connection it dialed itself (the exporter half of a
        three-party handoff, ADR-0009). The replay onto future connections is
        host-internal."""
        # A giftable is bound to no single connection: its forwards always go
        # through the host, and a turn it runs belongs to whichever connection
        # the deliver arrived on.
        ctx = _register_behavior(_BehaviorEntry(run=behavior, conn=None, resolve_local=None))
        data = name.encode()
        buf, ptr = _byte_buf(data)
        _check_host(_host.pancake_host_publish(
            self._raw, ptr, len(data),
            _TRAMPOLINE, ctypes.c_void_p(ctx), None,
        ))
        self.schedule_kick()

    # ── Connection registry ────────────────────────────────────────────────────

    def register_connection(self, ptr: int, conn: "Connection") -> None:
        """Track a live connection by its conn address. Binding-internal: the
        :class:`Connection` constructor calls it."""
        self._connections[ptr] = conn

    def unregister_connection(self, ptr: int) -> None:
        """Stop tracking a released connection. Binding-internal."""
        self._connections.pop(ptr, None)

    def close_exporters(self) -> None:
        """Close every exporter connection this node dialed for redeems.
        Binding-internal: :meth:`Connection.close` sweeps them."""
        for conn in [c for c in self._connections.values() if c.node_dialed]:
            conn.close_transport()

    # ── The vow table ──────────────────────────────────────────────────────────

    def vow_minted(self, vow: int, conn: "Optional[Connection]") -> None:
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
        if row.state is None:
            row.waiter = future
            return future
        del self._vows[vow]
        ok, payload = row.state
        if ok:
            future.set_result(payload)
        else:
            future.set_exception(payload)
        return future

    def _settle_vow(self, vow: int, ok: bool, payload) -> None:
        # The drain's settle arms: fire the waiter, or record the outcome for a
        # late observation (bounded FIFO — an outcome nobody ever awaits is
        # evicted at the cap).
        row = self._vows.get(vow)
        if row is None:
            return  # an outcome nobody registered for
        if row.waiter is not None:
            del self._vows[vow]
            if not row.waiter.done():
                if ok:
                    row.waiter.set_result(payload)
                else:
                    row.waiter.set_exception(payload)
            return
        row.state = (ok, payload)
        self._unobserved.append(vow)
        while len(self._unobserved) > _MAX_UNOBSERVED_OUTCOMES:
            oldest = self._unobserved.popleft()
            stale = self._vows.get(oldest)
            # Only evict a row still parked unobserved; an observed one is gone.
            if stale is not None and stale.state is not None and stale.waiter is None:
                del self._vows[oldest]

    # ── The action drain (the one loop rule) ──────────────────────────────────

    def _park_release(self, release: "Callable[[], None]") -> None:
        """Park a C release the host refused inside a behavior callback; the
        next drain — the head of :meth:`kick_actions`, or the feed's unwind —
        runs it where it is legal. Binding-internal."""
        self._parked_releases.append(release)

    def _drain_parked_releases(self) -> None:
        """Run every parked release, always outside a callback frame where the
        C tier accepts them. Called at the head of :meth:`kick_actions` and
        right after a feed returns. Binding-internal."""
        if _inside_turn():
            return
        while self._parked_releases:
            self._parked_releases.pop()()

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
        """Run the action drain to empty, honoring each action. Reentrant on
        purpose: the DIAL arm's dial executor establishes a whole new
        connection *inside* an action, and that establish must itself drain
        (its start-session FLUSH) — a single-flighted drain would await its own
        completion there. Each action is popped exactly once
        (:meth:`_next_action` is synchronous), so overlapping drains split the
        queue between them rather than double-running anything. A no-op inside
        a hosted turn: the host refuses the driving verbs there, and everything
        the turn enqueued pumps when the enclosing feed unwinds into this same
        drain. Binding-internal."""
        if _inside_turn():
            return
        # Parked releases run first — before the raw-handle check, because a
        # mid-turn Node.release cleared `_raw` while parking the actual free.
        self._drain_parked_releases()
        if not self._raw:
            return
        while True:
            action = self._next_action()
            if action is None:
                return
            # One failing action must not strand the rest of the drain: a FLUSH
            # to a connection whose socket just died fails here while the
            # actions behind it belong to other, live connections. The failed
            # connection tears itself down through its own serve loop (a DIAL
            # failure is reported to the core inside the arm).
            try:
                await self._run_action(action)
            except Exception:  # noqa: BLE001 — the drain reaches every action
                pass

    def _next_action(self) -> Optional[_PoppedAction]:
        # Pop the next embedder action, its borrowed views copied into Python
        # values — a SETTLE's PancakeArgument lifted whole — before anything
        # else can call `pancake_host_next_action` (which frees them), and
        # before the drain's first await. None when the queue is dry.
        a = self._action_scratch
        rc = _host.pancake_host_next_action(self._raw, ctypes.byref(a))
        if rc == _WOULD_BLOCK:
            return None
        _check_host(rc)
        kind = a.kind
        is_dial = kind == _HOST_ACTION_DIAL
        return _PoppedAction(
            kind=kind,
            ticket=a.ticket,
            conn_ptr=a.conn or 0,
            locator=_view(a.locator, a.locator_len) if is_dial else "",
            transport=_view(a.transport, a.transport_len) if is_dial else "",
            designator=_view(a.designator, a.designator_len) if is_dial else "",
            hint=_view(a.direct_addresses_hint, a.direct_addresses_hint_len) if is_dial else "",
            value=_arg_from_c(a.value) if kind == _HOST_ACTION_SETTLE else None,
            message=_view(a.message, a.message_len) if kind == _HOST_ACTION_FAIL else "",
        )

    async def _run_action(self, action: _PoppedAction) -> None:
        # The executor is deliberately dumb: every decision was already made in
        # the core; each arm is pure I/O or marshalling. `Connection` and
        # `Node` are one mutually-recursive layer split across two modules;
        # import at call time to keep the module-load edge acyclic.
        from ._connection import Connection

        if action.kind == _HOST_ACTION_DIAL:
            try:
                conn = await Connection._dial_exporter(
                    action.locator, action.transport, action.designator, action.hint, self,
                )
            except Exception as error:  # noqa: BLE001 — a failed dial breaks the redeems
                reason = (str(error) or type(error).__name__).encode()
                buf, ptr = _byte_buf(reason)
                _check_host(_host.pancake_host_dial_failed(
                    self._raw, action.ticket, ptr, len(reason),
                ))
                return
            conn.node_dialed = True
            # Keep the exporter connection pumped: the withdraw's resolution —
            # and any later routed traffic — rides it immediately.
            conn.serve()
            _check_host(_host.pancake_host_dialed(self._raw, action.ticket, conn.raw))
        elif action.kind == _HOST_ACTION_FLUSH:
            conn = self._connections.get(action.conn_ptr)
            if conn is not None:
                await conn.flush_outbound()
        elif action.kind == _HOST_ACTION_CLOSE:
            # The host condemned the connection mid-pump (local turn budget
            # exceeded): write its queued resource_exhausted abort, then close
            # the transport and release the conn shell.
            conn = self._connections.get(action.conn_ptr)
            if conn is not None:
                try:
                    await conn.flush_outbound()
                except Exception:  # noqa: BLE001 — the session is ending either way
                    pass
                conn.close_transport()
        elif action.kind == _HOST_ACTION_NEED_GIFT_ID:
            # Entropy is a host effect, drawn only when a reply actually
            # becomes a gift.
            gift_id = secrets.token_bytes(32)
            buf, ptr = _byte_buf(gift_id)
            _check_host(_host.pancake_host_provide_gift_id(
                self._raw, action.ticket, ptr, 32,
            ))
        elif action.kind == _HOST_ACTION_SETTLE:
            self._settle_vow(action.ticket, True, action.value)
        elif action.kind == _HOST_ACTION_FAIL:
            # A FAIL fired by the disconnect's own break (the connection is
            # closing) classifies as the typed ERR_CLOSED, not a partner break.
            row = self._vows.get(action.ticket)
            closing = row is not None and row.conn is not None and row.conn.closing
            error = (
                PancakeError(_ERR_CLOSED, action.message)
                if closing else VowBroken(action.message)
            )
            self._settle_vow(action.ticket, False, error)
        else:
            raise RuntimeError(f"unknown host action kind: {action.kind}")
