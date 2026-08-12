"""Internal: the CapTP :class:`Host` — multi-session CapTP product over the
byte-fed host family (ADR-0072, loaded from ``libpancake_host``). The Host
owns ``engine.Node``
(the sans-io handoff router). Goblins ``mycapn`` is two roles: its product maps
to Host; its router tables map to ``engine.Node`` — never a single-type
equation (ADR-0079).

The ``PancakeHost`` owns every cross-session decision: retained identity, the
live-session directory, routing, transparent three-party redemption, and the
gifter half's origination. Each session owns its own gift and replay authority.
What lives here is only what the embedder contract leaves
to the binding: the host handle, the session-pointer → :class:`Session`
registry the action drain routes by, the vow table the drain's SETTLE/FAIL
arms settle, the action drain itself, gift-id entropy, and the iroh redeem
posture the dial executor reads. The action decode+execute switch lives in
:mod:`pancake._action`; the pump lives in :mod:`pancake._pump`; the dial
executor lives in :mod:`pancake._dial`. :mod:`pancake._session` owns the
:class:`Session` they act on. Import from the :mod:`pancake` package.
"""

from __future__ import annotations

import asyncio
import atexit
import ctypes
import secrets
import threading
import weakref
from collections import deque
from typing import (
    TYPE_CHECKING,
    Any,
    Awaitable,
    Callable,
    Coroutine,
    Optional,
)

from . import _constants as _abi
from ._action import _park_actions, _run_action
from ._codec import _arg_to_c, _captp_version_id, _codec_id, _feature_mask, _ref_to_c
from ._errors import PancakeError, _check_host, _host_last_error
from . import _trace

if TYPE_CHECKING:
    from ._context import Context
    from ._session import Session
from ._ffi_host import _host
from ._ffi_ocapn import _byte_buf
from ._trampoline import (
    _BehaviorEntry,
    _inside_turn,
    _register_behavior as _register_global_behavior,
    _TRAMPOLINE,
    _unregister_behavior as _unregister_global_behavior,
)
from ._value import Behavior, Ref
from ._gc import HostGc, bind_host

_ERR_CLOSED = _abi.ERR_CLOSED


_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT

# Every connection's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
_HOST_FRAME_CAP = _abi.DEFAULT_FRAME_CAP

# Cap on stored outcomes whose vow is never awaited, so the store cannot grow
# without bound; the oldest un-awaited outcome is evicted at the cap.
_MAX_UNOBSERVED_OUTCOMES = 1024


# A vow row's initial state: registered, not yet awaited and not yet settled.
_MINTED = object()

# A finalizer cannot report a native release refusal. Same-thread callback
# finalization uses the post-turn queue below; any other refusal transfers into
# this process-level retry owner. Safe Host boundaries claim one finite batch,
# and interpreter shutdown gets the final attempt. The queue deliberately keeps
# the allocator context alive until native release really succeeds.
_deferred_finalizer_states: "deque[_HostFinalizerState]" = deque()
_deferred_finalizer_ids: "set[int]" = set()
_deferred_finalizer_lock = threading.Lock()


class _HostFinalizerState:
    """Raw Host authority that may outlive the Python wrapper.

    The finalizer owns no Host, Session, loop, or behavior closure. The integer
    trampoline ids are enough to retire the process-global registry after the
    native Host has stopped calling it; retaining ``context`` keeps a custom
    allocator alive until that release completes.
    """

    __slots__ = ("raw", "giftables", "displaced", "hosted", "context")

    def __init__(self, raw, giftables, displaced, hosted, context) -> None:
        self.raw = raw
        self.giftables = giftables
        self.displaced = displaced
        self.hosted = hosted
        self.context = context


def _release_finalizer_state(state: _HostFinalizerState, *, checked: bool) -> None:
    """Release one detached Host state, at most once."""
    raw = state.raw
    if not raw:
        return
    rc = _host.pancake_host_release(raw)
    if checked:
        _check_host(rc)
    elif rc != _abi.OK:
        if _inside_turn():
            _parked_releases().append(
                lambda: _release_finalizer_state(state, checked=False)
            )
        else:
            _defer_finalizer_state(state)
        return
    state.raw = None
    behavior_ids = (
        set(state.giftables.values())
        | set(state.displaced)
        | set(state.hosted.values())
    )
    for ctx in behavior_ids:
        _unregister_global_behavior(ctx)
    state.giftables.clear()
    state.displaced.clear()
    state.hosted.clear()
    context = state.context
    state.context = None
    if context is not None:
        context._release_handle()


def _defer_finalizer_state(state: _HostFinalizerState) -> None:
    """Transfer one refused finalizer release to the process retry owner."""
    state_id = id(state)
    with _deferred_finalizer_lock:
        if not state.raw or state_id in _deferred_finalizer_ids:
            return
        _deferred_finalizer_ids.add(state_id)
        _deferred_finalizer_states.append(state)


def _drain_deferred_finalizer_states() -> None:
    """Retry one claimed batch at a boundary where no Host callback is active."""
    if _inside_turn():
        return
    with _deferred_finalizer_lock:
        batch = list(_deferred_finalizer_states)
        _deferred_finalizer_states.clear()
        _deferred_finalizer_ids.clear()
    for state in batch:
        _release_finalizer_state(state, checked=False)


def _pending_finalizer_retry_count() -> int:
    """Internal test observability for the process finalizer retry owner."""
    with _deferred_finalizer_lock:
        return len(_deferred_finalizer_states)


atexit.register(_drain_deferred_finalizer_states)


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

    __slots__ = ("session", "state")

    def __init__(self, session):
        # The session the vow was minted on, for closed-vs-broken
        # classification; None for a vow whose home is not a single session.
        self.session = session
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
    host). ``codec``, ``captp_version``, and ``features`` are the Host's
    signed profile offer. Each session settles version and codec with its
    partner, falling back to v1.0/Syrup when needed, and runs only the
    intersection of the two offered feature sets. Omitted ``features`` means
    the full feature set. ``context`` routes every byte the host owns through a
    caller-supplied allocation scope (:class:`Context`).
    ``local_turn_budget`` is ``0`` for unbounded (the default) or a nonzero
    cap on local-turn amplification per drive (ADR-0076)."""

    def __init__(
        self,
        seed: Optional[bytes] = None,
        *,
        codec: str = "syrup",
        captp_version: str = "v1_0",
        features="full",
        context: "Optional[Context]" = None,
        local_turn_budget: int = 0,
        _adopt_raw: Optional[int] = None,
    ):
        # `_adopt_raw` is the loop tier's adoption seam (ADR-0112): the native
        # driver archive owns the host handle, and this wrapper adopts it for the
        # application verbs. In that mode the C loop is the action drain — the
        # kick verbs nudge a loop step instead of running the Python drain —
        # and release belongs to `DriverLoop.close`.
        self._loop_mode = _adopt_raw is not None
        # The adopting DriverLoop, set by `wrapper_host` so the kick verbs can
        # nudge its step. Typed loosely: `_loop` is binding-internal and the
        # core wrapper must stay importable without it.
        self._driver_loop: "Optional[object]" = None
        _drain_deferred_finalizer_states()
        self._raw: ctypes.c_void_p | None = None
        try:
            durable_seed = (
                bytes(memoryview(seed)) if seed is not None else secrets.token_bytes(32)
            )
        except (BufferError, TypeError, ValueError):
            raise PancakeError(_ERR_INVALID_ARGUMENT, "seed must be 32 bytes") from None
        if len(durable_seed) != 32:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "seed must be 32 bytes")
        # `bytes` is immutable and copies mutable bytes-like caller input, so the
        # native identity and every later designator read the same owned value.
        self._seed = durable_seed
        self.codec = codec
        self.captp_version = captp_version
        self.features = features
        # Host-scoped references outlive the session that delivered them; their
        # finalizer queue therefore belongs here, beside the authority registry.
        self._gc = HostGc()
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = (
                asyncio.get_running_loop()
            )
        except RuntimeError:
            self._loop = None
        self._owner_thread = threading.get_ident()
        self._trace_refresh_pending = False
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
        # A popped DIAL no longer exists in the C action queue. Its executor is
        # therefore Host-owned until it reports success/failure or teardown
        # cancels it; caller cancellation of one drain must not strand a ticket.
        self._dial_tasks: "set[asyncio.Task]" = set()
        # Async teardown retains one join task so a second owner cannot free the
        # native Host while the first owner is still joining its DIAL tasks.
        self._release_task: "Optional[asyncio.Task]" = None
        self._release_started = False
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
        # Strong ownership of process-global callback entries belongs to the
        # Host, not the global lookup. This map may contain a behavior that
        # captures this Host; Python's collector can reclaim that local cycle.
        self._behavior_entries: "dict[int, _BehaviorEntry]" = {}
        # The iroh reachability posture this host uses to redeem a *hint-less*
        # handoff give — one whose exporter location names the exporter by node
        # id alone. Starts at the generated ABI default (Discovery, n0 relays +
        # DNS/pkarr, the maximal-reach choice); a relay-policy deployment
        # lowers it. A hinted give always dials Direct and ignores it. Stored
        # as the numeric value so the core stays free of the optional iroh
        # module.
        self._rendezvous_url = None
        self._signaling = None
        self._redeem_reachability = _abi.IROH_REACH_REDEEM_DEFAULT
        if _adopt_raw is not None:
            self._raw = ctypes.c_void_p(_adopt_raw)
            self._finalizer_state = None
            self._finalizer = None
            _trace._attach_host(self, self.designator())
            bind_host(self._gc, self)
            return
        out = ctypes.c_void_p()
        # The durable identity followed by a session-key root drawn here, at
        # this binding's entropy boundary, because the library draws none
        # (ADR-0097). The root is fresh per process, so every CapTP session
        # signs with its own key and a restart cannot recreate a prior
        # session's handoff names; the durable half stays exactly ``seed``,
        # since a keyed locator's designator derives from it.
        sbuf, sptr = _byte_buf(self._seed + secrets.token_bytes(32))
        if context is not None:
            context_raw = context._acquire_handle()
            try:
                _check_host(
                    _host.pancake_host_new_in(
                        context_raw,
                        sptr,
                        64,
                        _HOST_FRAME_CAP,
                        1,
                        _codec_id(codec),
                        _captp_version_id(captp_version),
                        _feature_mask(features),
                        local_turn_budget,
                        ctypes.byref(out),
                    )
                )
            except BaseException:
                context._release_handle()
                raise
        else:
            _check_host(
                _host.pancake_host_new(
                    sptr,
                    64,
                    _HOST_FRAME_CAP,
                    1,
                    _codec_id(codec),
                    _captp_version_id(captp_version),
                    _feature_mask(features),
                    local_turn_budget,
                    ctypes.byref(out),
                )
            )
        self._raw = out
        self._finalizer_state = _HostFinalizerState(
            out,
            self._giftables,
            self._displaced_giftables,
            self._hosted,
            context,
        )
        self._finalizer = weakref.finalize(
            self,
            _release_finalizer_state,
            self._finalizer_state,
            checked=False,
        )
        # The host's own key designator, which is what a partner names it by:
        # the live trace reports it as this host's endpoint so one peer stays
        # one node in a feed several producers share. The raw-only finalizer is
        # already armed in case this setup call refuses.
        _trace._attach_host(self, self.designator())
        bind_host(self._gc, self)

    @property
    def seed(self) -> bytes:
        """The immutable 32-byte identity seed retained by this Host."""
        return self._seed

    def _adopt_driver_loop(self, loop: object) -> None:
        """Commit native loop ownership after ``pancake_driver_take_host``.

        The native call is the transaction boundary. This method only updates
        Python ownership after that call has returned success, so every failed
        adoption leaves the byte-fed Host and its finalizer untouched.
        """
        if self._loop_mode or self._raw is None or self._release_started:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "host is not adoptable")
        assert self._finalizer is not None
        self._finalizer.detach()
        self._finalizer = None
        self._finalizer_state = None
        self._loop_mode = True
        self._driver_loop = loop

    def _driver_did_release(self) -> None:
        """Finish Python ownership after the driver freed the native Host.

        Host transfer moves the native release authority into ``DriverLoop``,
        but the wrapper still owns callback registrations and the allocation
        context borrow. They must outlive ``pancake_driver_release`` and then
        retire exactly once.
        """
        if self._raw is None:
            return
        _trace._detach_host(self)
        self._raw = None
        self._release_started = True
        self._driver_loop = None
        behavior_ids = (
            set(self._giftables.values())
            | set(self._displaced_giftables)
            | set(self._hosted.values())
        )
        for ctx in behavior_ids:
            _unregister_global_behavior(ctx)
        self._giftables.clear()
        self._displaced_giftables.clear()
        self._hosted.clear()
        self._behavior_entries.clear()
        context = self._context
        self._context = None
        if context is not None:
            context._release_handle()

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHost handle. Binding-internal: :class:`Session`
        mints and drives sessions against it. Raises once the host is
        released, rather than handing out the null the field then holds."""
        self._assert_owner()
        if self._raw is None or self._release_started:
            raise PancakeError(_ERR_CLOSED, "the host has been released")
        return self._raw

    @property
    def raw_or_none(self):
        """Raw handle or ``None`` for the finalizer-safe GC seam."""
        return None if self._release_started else self._raw

    def _on_owner_thread(self) -> bool:
        return threading.get_ident() == self._owner_thread

    def _on_owner_loop(self) -> bool:
        """Whether the current caller may touch this host synchronously.

        A host created outside asyncio is still usable by synchronous setup
        and finalizer paths. Once a running loop drives it, that loop becomes
        part of the host's ownership contract.
        """
        if not self._on_owner_thread():
            return False
        if self._loop is None:
            return True
        try:
            return asyncio.get_running_loop() is self._loop
        except RuntimeError:
            return False

    def _bind_running_loop(self) -> None:
        """Bind a loop-created session to the host's first driving loop."""
        if not self._on_owner_thread():
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event-loop thread",
            )
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            if self._loop is not None:
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "host must be driven from its owning event loop",
                )
            return
        if self._loop is None:
            self._loop = running
        elif running is not self._loop:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event loop",
            )

    def _assert_owner(self) -> None:
        if not self._on_owner_thread():
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event-loop thread",
            )
        self._bind_running_loop()
        if self._trace_refresh_pending:
            _trace._refresh_host(self)

    def _schedule_cleanup(self, run) -> bool:
        """Schedule owner-loop cleanup when the caller is off-loop.

        Returns ``True`` when ``run`` was handed to the owner loop. This seam
        is deliberately for teardown only; operational verbs use
        :meth:`_assert_owner` and fail instead of silently hopping loops.
        """
        if self._on_owner_loop():
            return False
        if self._loop is not None:
            if not self._loop.is_running():
                # A stopped loop accepts call_soon_threadsafe but cannot run
                # the callback. Releasing on the original owner thread, while
                # no other loop is active there, is the only terminal path
                # that neither leaks nor lends authority to another loop.
                if self._on_owner_thread():
                    try:
                        asyncio.get_running_loop()
                    except RuntimeError:
                        self._loop = None
                        return False
                return False
            if self.schedule_on_loop(run):
                return True
            # The loop can stop between is_running() and
            # call_soon_threadsafe. Re-run the owner-thread case rather than
            # claiming cleanup was scheduled when it was not.
            if not self._loop.is_running() and self._on_owner_thread():
                try:
                    asyncio.get_running_loop()
                except RuntimeError:
                    self._loop = None
                    return False
        return False

    @property
    def released(self) -> bool:
        return self._release_started or self._raw is None

    @property
    def gc(self) -> HostGc:
        """Host-owned distributed-GC state. Binding-internal."""
        return self._gc

    def schedule_on_loop(self, run) -> bool:
        """Hop a finalizer drain onto the Host's event loop."""
        loop = self._loop
        if loop is None:
            return False
        try:
            loop.call_soon_threadsafe(run)
            return True
        except RuntimeError:
            return False

    def _run_trace_install(self, install) -> None:
        """Run or schedule trace configuration on this Host's owner thread.

        A Host created outside an event loop cannot be entered from a foreign
        thread. In that case the configuration remains process-global and the
        next owner-thread Host operation reconciles it through
        :meth:`_assert_owner`.
        """
        if self._on_owner_loop():
            install()
            self._trace_refresh_pending = False
            return

        def scheduled() -> None:
            install()
            self._trace_refresh_pending = False

        if not self.schedule_on_loop(scheduled):
            self._trace_refresh_pending = True

    def _defer_turn_to_awaitable(self, turn: int, pending: "Awaitable[object]") -> bool:
        """Binding-internal (the trampoline's async-behavior arm): defer
        ``turn``'s answer onto a fresh resolver vow and settle it when
        ``pending`` does. The settle runs as its own task on the running
        loop — the top-level re-entry the host requires — and carries plain
        data only: a value the settle refuses (a capability, per the off-turn
        contract) breaks the answer with the refusal's reason instead of
        stranding it. False when the deferral itself refused."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            close = getattr(pending, "close", None)
            if close is not None:
                close()
            return False

        resolver_out = ctypes.c_uint64(0)
        if _host.pancake_host_turn_defer(turn, ctypes.byref(resolver_out)) != _abi.OK:
            return False
        resolver = resolver_out.value

        async def settle() -> None:
            try:
                value = await pending
            except asyncio.CancelledError:
                self._break_resolver(resolver, "async behavior cancelled")
                return
            except Exception as error:  # noqa: BLE001 — a raise breaks the answer
                self._break_resolver(resolver, str(error) or type(error).__name__)
                return
            self._settle_resolver(resolver, value)

        task = loop.create_task(settle())
        self._kick_tasks.add(task)
        task.add_done_callback(self._kick_tasks.discard)
        return True

    def _settle_resolver(self, resolver: int, value: Any) -> None:
        self._assert_owner()
        raw = self.raw_or_none
        if not raw:
            return  # a released host freed its resolver rows
        keep: list = []
        try:
            c_arg = _arg_to_c(value, keep)
        except Exception as error:  # noqa: BLE001 — marshalling failure breaks the answer
            self._break_resolver(resolver, str(error) or type(error).__name__)
            return
        if (
            _host.pancake_host_resolver_fulfill(raw, resolver, ctypes.byref(c_arg))
            != _abi.OK
        ):
            self._break_resolver(
                resolver, _host_last_error() or "deferred settle refused"
            )
            return
        self.schedule_kick()

    def _break_resolver(self, resolver: int, message: str) -> None:
        self._assert_owner()
        raw = self.raw_or_none
        if not raw:
            return
        data = message.encode()
        _buf, ptr = _byte_buf(data)
        _check_host(_host.pancake_host_resolver_break(raw, resolver, ptr, len(data)))
        self.schedule_kick()

    def _begin_release(self) -> "list[asyncio.Task]":
        """Cancel Host-owned asynchronous work and close its child resources."""
        if self._release_started or not self._raw:
            return []
        self._release_started = True
        current = None
        try:
            current = asyncio.current_task()
        except RuntimeError:
            pass
        tasks = {
            task for task in self._dial_tasks | self._kick_tasks if task is not current
        }
        for task in tasks:
            task.cancel()
        # Sessions first: each releases its own handle, and a handle
        # outliving the Host it belongs to is a free of freed memory.
        self.close_sessions()
        self._fail_outstanding_vows("host released")
        return list(tasks)

    def _finish_release(self) -> None:
        if not self._raw:
            return
        # A loop-adopted host has no finalizer: the native handle belongs to
        # the DriverLoop, and `_begin_release` already refused this path.
        assert self._finalizer is not None and self._finalizer_state is not None
        self._finalizer.detach()
        _trace._detach_host(self)
        self._raw = None
        state = self._finalizer_state

        def release_host() -> None:
            _release_finalizer_state(state, checked=True)
            self._behavior_entries.clear()

        if _inside_turn():
            self.park_release(release_host)
        else:
            release_host()

    async def _finish_release_after_tasks(self, tasks: "list[asyncio.Task]") -> None:
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._finish_release()

    def _start_release(self) -> "Optional[asyncio.Task]":
        """Make close intent terminal now; join admitted work before native free."""
        task = self._release_task
        if task is not None:
            return task
        if self._release_started:
            return None
        tasks = self._begin_release()
        if not tasks:
            self._finish_release()
            return None
        task = asyncio.get_running_loop().create_task(
            self._finish_release_after_tasks(tasks)
        )
        self._release_task = task
        return task

    async def release_async(self) -> None:
        """Release the Host after joining every Host-owned asynchronous task.

        :meth:`release` remains the synchronous callback-safe teardown lever.
        Async owners use this method so cancellation is not mistaken for task
        completion and the native Host cannot be freed under a still-running
        dial executor, action drain, or listener close. The retained release
        task makes repeated teardown calls idempotent and safe while the first
        call is awaiting cancellation.
        """
        self._assert_owner()
        if self._loop_mode:
            loop = self._driver_loop
            if loop is not None:
                self._request_driver_release(loop)
                await loop.wait_closed()
            return
        task = self._start_release()
        if task is not None:
            await asyncio.shield(task)

    def release(self) -> None:
        """Synchronously release the Host and everything it owns.

        This is the callback-safe teardown lever and preserves the existing
        synchronous API. Async owners must use :meth:`release_async` when the
        Host may have in-flight work, so cancellation and close barriers can be
        joined before native teardown.
        """
        if self._loop_mode:
            loop = self._driver_loop
            if loop is not None:
                self._request_driver_release(loop)
            return
        loop = self._loop
        if loop is not None and self._on_owner_thread() and not loop.is_running():
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                if loop.is_closed():
                    if self._dial_tasks or self._kick_tasks:
                        raise PancakeError(
                            _ERR_INVALID_ARGUMENT,
                            "host owner loop is closed with asynchronous work still active",
                        )
                    self._loop = None
                else:
                    loop.run_until_complete(self.release_async())
                    return
        if self._schedule_cleanup(self.release):
            return
        if not self._on_owner_loop():
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "host release must run on its owning thread",
            )
        if self._loop is not None:
            self._assert_owner()
        self._start_release()

    def _request_driver_release(self, loop: object) -> None:
        """Make transferred driver ownership terminal, callback-safely."""
        if self._release_started or self._raw is None:
            return
        self._release_started = True
        if _inside_turn():
            self.park_release(loop.close)  # type: ignore[attr-defined]
        else:
            loop.close()  # type: ignore[attr-defined]

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
        self._rendezvous_url = None
        self._redeem_reachability = int(reachability)

    @property
    def rendezvous_url(self):
        """How this host reaches a ``keyed-relay`` peer: a callable mapping the
        peer's key designator to the WebSocket URL of the relay rendezvous leg
        that bridges onto its held inbound socket, e.g.
        ``lambda id: f"wss://example/relay?rendezvous={id}"`` (ADR-0088). The
        keyed-relay sibling of :attr:`redeem_reachability`: deployment
        configuration for reaching an exporter that opens no listener. ``None``
        until assigned, and a ``keyed-relay`` dial refuses without it."""
        return self._rendezvous_url

    @rendezvous_url.setter
    def rendezvous_url(self, url) -> None:
        self._rendezvous_url = url

    @property
    def signaling(self):
        """Explicit signaling authority for a signaling byte-channel dial."""
        return self._signaling

    @signaling.setter
    def signaling(self, authority) -> None:
        self._signaling = authority

    async def enliven(self, sturdyref: str) -> "Ref":
        """Enliven a complete sturdyref without naming a session (ADR-0098):
        the host enlivens it over a live session it already dialed to that
        peer, or dials one itself through this host's own DIAL action and
        finishes when the dial reports. :meth:`Session.enliven` is the
        narrower verb -- it never dials, and refuses a sturdyref for another
        peer."""
        from ._promise import _classify_live_ref

        # Select the runtime from the core's normalized plan shape before the
        # action exists. A native provider then owns the original queued DIAL;
        # rendezvous/signaling plans stay on this embedder's channel registry.
        if not self._loop_mode and not self._sessions:
            from ._dial import (
                _HostPortDial,
                _PeerIdDial,
                _RendezvousDial,
                _plan_dial,
                prepare_native_provider,
            )
            from ._locator import parse_sturdyref
            from ._loop import DriverLoop
            from .relay import _route_from_locator

            locator = parse_sturdyref(sturdyref).locator
            plan = _plan_dial(
                locator.transport,
                locator.designator,
                locator.hints.get(_abi.HINT_DIRECT_ADDRESSES, ""),
                _abi.DIAL_POSTURE_REDEEM,
                0,
            )
            relay_route = _route_from_locator(locator)
            if isinstance(plan, (_HostPortDial, _PeerIdDial)) or (
                isinstance(plan, _RendezvousDial) and relay_route is not None
            ):
                loop = DriverLoop.take_host(self)
                try:
                    await prepare_native_provider(loop, plan, locator)
                    await loop.start()
                except BaseException:
                    loop.close()
                    raise

        swiss = sturdyref.encode()
        buf, ptr = _byte_buf(swiss)
        out = ctypes.c_uint64()
        _check_host(
            _host.pancake_host_enliven(self.raw, ptr, len(swiss), ctypes.byref(out))
        )
        vow = out.value
        # The vow may be parked on a dial with no session of its own, which is
        # exactly the ``None`` session row the vow table already admits.
        self.vow_minted(vow, None)
        settled = self.await_vow(vow)
        await self.kick_actions()
        return _classify_live_ref(await settled, sturdyref)

    def set_advertised_locator(self, locator) -> None:
        """Retain a validated clone of this Host's complete location."""
        from ._locator import _OwnedLocator

        with _OwnedLocator.create(locator) as owned:
            _check_host(
                _host.pancake_host_set_advertised_locator(
                    self.raw, owned.borrow_view()
                )
            )

    def ensure_advertised_locator(self, transport: str) -> None:
        """Retain a transport location without displacing an existing one.
        Binding-internal."""
        data = transport.encode()
        buf, ptr = _byte_buf(data)
        _check_host(
            _host.pancake_host_ensure_advertised_locator(self.raw, ptr, len(data))
        )

    def remove_advertised_locator(self, transport: str) -> None:
        """Remove this Host's retained locator for ``transport``."""
        data = transport.encode()
        buf, ptr = _byte_buf(data)
        _check_host(
            _host.pancake_host_remove_advertised_locator(self.raw, ptr, len(data))
        )

    def set_session_limits(
        self,
        max_frame_bytes: int = 0,
        queue_cap: int = 0,
        outbound_high_water_bytes: int = 0,
    ) -> None:
        """Selective session-limit knobs (ADR-0082). Pass 0 to leave a field
        unchanged. Affects peers minted after this call."""
        _check_host(
            _host.pancake_host_set_session_limits(
                self.raw,
                int(max_frame_bytes),
                int(queue_cap),
                int(outbound_high_water_bytes),
            )
        )

    def designator(self) -> str:
        """The canonical key designator (64 lowercase hex digits) for this
        node's identity seed — what a keyed-tcp locator names as its
        designator (ADR-0075)."""
        out = (ctypes.c_ubyte * 64)()
        buf, ptr = _byte_buf(self._seed)
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
        ctx = self._register_behavior(_BehaviorEntry(run=behavior, resolve_local=None))
        data = name.encode()
        buf, ptr = _byte_buf(data)
        try:
            _check_host(
                _host.pancake_host_publish(
                    self.raw,
                    ptr,
                    len(data),
                    _TRAMPOLINE,
                    ctypes.c_void_p(ctx),
                    None,
                )
            )
        except BaseException:
            # free = NULL: the C tier never owns the row, so a refused publish
            # must drop it here or the registry pins the behavior forever.
            self._unregister_behavior(ctx)
            raise
        prior = self._giftables.get(name)
        if prior is not None:
            # Replacement moves discovery only. Existing capabilities and
            # deposited gifts can still call the old actor.
            self._displaced_giftables.append(prior)
        self._giftables[name] = ctx

    def unpublish_giftable(self, name: str) -> bool:
        """Remove the Host-wide alias ``name`` (alias-only).

        A later fetch misses on every session, while issued refs and deposited
        gifts keep the exact actor, whose behavior stays hosted for the Host's
        life. Returns ``False`` when no such alias exists."""
        data = name.encode()
        buf, ptr = _byte_buf(data)
        rc = _host.pancake_host_unpublish(self.raw, ptr, len(data))
        if rc == _abi.ERR_NOT_FOUND:
            return False
        _check_host(rc)
        # The alias is gone but the actor is not: its trampoline row moves to
        # the displaced list, exactly as a replacement displaces one.
        prior = self._giftables.pop(name, None)
        if prior is not None:
            self._displaced_giftables.append(prior)
        self.schedule_kick()
        return True

    def publish_durable(self, behavior: Behavior) -> str:
        """Publish ``behavior`` under a freshly minted durable swiss name and
        return that name — the swiss to place in a sturdyref beside this
        host's own locator (ADR-0098).

        The name is unpredictable, never reassigned, structurally disjoint
        from every mutable alias, and removable only through
        :meth:`remove_durable`. Entropy is drawn here, from the OS RNG."""
        ctx = self._register_behavior(_BehaviorEntry(run=behavior, resolve_local=None))
        entropy = secrets.token_bytes(16)
        ebuf, eptr = _byte_buf(entropy)
        out = (ctypes.c_ubyte * 64)()
        try:
            written = _host.pancake_host_publish_durable(
                self.raw,
                eptr,
                len(entropy),
                _TRAMPOLINE,
                ctypes.c_void_p(ctx),
                None,
                out,
                64,
            )
            if written <= 0:
                _check_host(written)
        except BaseException:
            # free = NULL: the C tier never owns the row, so a refused publish
            # must drop it here or the registry pins the behavior forever.
            self._unregister_behavior(ctx)
            raise
        name = bytes(out[:written]).decode("ascii")
        self._giftables[name] = ctx
        self.schedule_kick()
        return name

    def _register_behavior(self, entry: _BehaviorEntry) -> int:
        """Retain one callback entry for this Host's native lifetime."""
        ctx = _register_global_behavior(entry)
        self._behavior_entries[ctx] = entry
        return ctx

    def _unregister_behavior(self, ctx: int) -> None:
        """Undo a refused callback mint before it joins Host authority."""
        self._behavior_entries.pop(ctx, None)
        _unregister_global_behavior(ctx)

    def remove_durable(self, swiss: str) -> bool:
        """Remove a minted durable publication (ADR-0098).

        The old sturdyref misses from now on, while issued refs and deposited
        gifts keep the exact actor. Returns ``False`` when no such durable
        name exists."""
        data = swiss.encode()
        buf, ptr = _byte_buf(data)
        rc = _host.pancake_host_remove_durable(self.raw, ptr, len(data))
        if rc == _abi.ERR_NOT_FOUND:
            return False
        _check_host(rc)
        prior = self._giftables.pop(swiss, None)
        if prior is not None:
            self._displaced_giftables.append(prior)
        self.schedule_kick()
        return True

    # ── Session registry ────────────────────────────────────────────────────

    def register_session(self, ptr: int, session: "Session") -> None:
        """Track a live session by its session address. Binding-internal: the
        :class:`Session` constructor calls it."""
        self._sessions[ptr] = session

    def unregister_session(self, ptr: int) -> None:
        """Stop tracking a released session. Binding-internal."""
        self._sessions.pop(ptr, None)

    def exporter_for(self, ref: Ref) -> "Optional[Session]":
        """The live :class:`Session` homing remote ``ref``, or ``None`` for a
        local, stale, foreign-Host, or closed-session capability.

        The answer is deterministic (ADR-0088): the reply's own token carries
        which session it lives in, so :meth:`Session.send_redeeming` resolves
        the exact exporter session it should host its back-channel on. There is
        no capture window and no dependence on which dial finished first, so it
        is right with several redeems in flight, and it finds an exporter a
        prior redeem already dialed -- a cache hit that opens no new session.
        :meth:`Session.send_redeeming` suppresses its own sending session and
        surfaces only a different exporter. Binding-internal."""
        c_ref = _ref_to_c(ref._live())
        out = ctypes.c_void_p()
        _check_host(
            _host.pancake_host_reference_exporter(
                self.raw,
                ctypes.byref(c_ref),
                ctypes.byref(out),
            )
        )
        # The handle is host-owned and lives with the exporter session, so the
        # registry lookup is the whole answer: a pointer with no live row is a
        # session this binding no longer holds, which reads as no route.
        found = self._sessions.get(out.value) if out.value else None
        if (
            found is None
            and out.value
            and self._loop_mode
            and self._driver_loop is not None
        ):
            # A loop-owned Host redeems inside its own steps (ADR-0112), so
            # the exporter session it dialed exists with no wrapper yet. Wrap
            # it lazily — the constructor registers it, so a repeat lookup
            # returns this same object — and the loop stays its release
            # authority through the transport's back-reference.
            from ._loop import DriverLoop

            assert isinstance(self._driver_loop, DriverLoop)
            found = self._driver_loop.adopt_session(out.value)
        return found

    def close_sessions(self) -> None:
        """Close every session this Host holds -- the ones an application
        opened and the ones the Host dialed for redeems alike. Each close
        releases that session's handle, so this must run before the Host
        handle goes. Binding-internal: :meth:`release` sweeps them."""
        for session in list(self._sessions.values()):
            session.close_transport()

    # ── The vow table ──────────────────────────────────────────────────────────

    def vow_minted(self, vow: int, session: "Optional[Session]") -> None:
        """Record a freshly minted vow so the drain can route its completion.
        Runs in the same synchronous block as the minting FFI call, so no drain
        can pop the completion first. Binding-internal."""
        self._vows[vow] = _VowRow(session)

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
            future.set_exception(
                PancakeError(
                    _ERR_CLOSED, "the vow's outcome is gone (unobserved past the cap)"
                )
            )
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

    def _fail_outstanding_vows(self, message: str) -> None:
        for row in self._vows.values():
            if isinstance(row.state, asyncio.Future) and not row.state.done():
                row.state.set_exception(PancakeError(_ERR_CLOSED, message))
        self._vows.clear()
        self._unobserved.clear()

    def vow_session_closing(self, vow: int) -> bool:
        """Whether the vow's home connection is tearing down — FAIL arms
        classify those breaks as ERR_CLOSED. Binding-internal."""
        row = self._vows.get(vow)
        return row is not None and row.session is not None and row.session.is_closing

    def get_session(self, ptr: int):
        """Look up a live session by session address. Binding-internal: the
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
        _drain_deferred_finalizer_states()

    def pending_release_count(self) -> int:
        """How many releases are parked — test observability for the mid-turn
        close park. Binding-internal."""
        return len(_parked_releases())

    def schedule_kick(self) -> None:
        """Kick the action drain from a synchronous verb: schedule it as its
        own task, retained until done. Binding-internal. On a loop-adopted
        host the native loop is the one drain, so the kick becomes a
        scheduled loop step."""
        if self._loop_mode:
            loop = self._driver_loop
            if loop is not None:
                loop.schedule_step()  # type: ignore[attr-defined]
            return
        if _inside_turn() or not self._raw or self._release_started:
            return
        if self._schedule_cleanup(self.schedule_kick):
            return
        self._assert_owner()
        try:
            task = asyncio.get_running_loop().create_task(self.kick_actions())
        except RuntimeError:
            # No running loop (a sync teardown path); the next verb drains.
            return
        self._kick_tasks.add(task)
        task.add_done_callback(self._kick_tasks.discard)

    def start_dial_task(self, run: "Callable[[], Coroutine[Any, Any, None]]") -> None:
        """Retain a popped DIAL independently of the drain that discovered it."""
        if not self._raw or self._release_started:
            return
        self._assert_owner()
        task = asyncio.get_running_loop().create_task(run())
        self._dial_tasks.add(task)

        def done(finished: "asyncio.Task") -> None:
            self._dial_tasks.discard(finished)
            # Retrieve terminal exceptions so Host-owned cancellation does not
            # become an unhandled task warning.
            if not finished.cancelled():
                finished.exception()
            if self._raw and not self._release_started:
                self.schedule_kick()

        task.add_done_callback(done)

    async def kick_actions(self) -> None:
        if self._loop_mode:
            # The native loop is the drain; one step flushes what a verb
            # queued.
            loop = self._driver_loop
            if loop is not None:
                loop.step_now()  # type: ignore[attr-defined]
            return
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
        self._assert_owner()
        # Parked releases run first — before the raw-handle check, because a
        # mid-turn Host.release cleared `_raw` while parking the actual free.
        self.drain_parked_releases()
        if not self._raw or self._release_started:
            return
        while True:
            if self._release_started or not self._raw:
                return
            parked, yielded = _park_actions(self)
            if not parked and not yielded:
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
            if yielded:
                # The core ended a finite scheduler slice. Return to asyncio
                # before requesting the next one so ready transports and other
                # hosts share this thread.
                await asyncio.sleep(0)
