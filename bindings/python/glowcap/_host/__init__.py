"""Internal: the CapTP :class:`Host`: multi-session CapTP product over the
byte-fed host family (ADR-0022, loaded from ``libglowcap_host``). The Host
owns ``engine.Node``
(the sans-io handoff router). Goblins ``mycapn`` is two roles: its product maps
to Host. Its router tables map to ``engine.Node``: never a single-type
equation (ADR-0011).

The ``GlowcapHost`` owns every cross-session decision: retained identity, the
live-session directory, routing, transparent three-party redemption, and the
gifter half's origination. Each session owns its own gift and replay authority.
This package owns only what the embedder contract leaves to the binding. Its
root is the concrete Host state and owner-thread seam. ``lifecycle`` owns
adoption and terminal release, ``publication`` owns connector/publication and
session-directory operations, ``progress`` owns the single action drain, and
``vows`` owns vow observation. The action decode+execute switch lives in
:mod:`glowcap._action`. The pump lives in :mod:`glowcap._pump`. The dial
executor lives in :mod:`glowcap._dial`. :mod:`glowcap._session` owns the
:class:`Session` they act on. Import from the :mod:`glowcap` package.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
import threading
import weakref
from typing import (
    TYPE_CHECKING,
    Awaitable,
    Optional,
)

from .. import _constants as _abi
from .._abi_value import (
    _DEFAULT_CAPTP_VERSION,
    _DEFAULT_CODEC,
    _DEFAULT_FEATURES,
    _INTEROP_CAPTP_VERSION,
    _INTEROP_CODEC,
    _OWN_CAPTP_VERSION,
    _OWN_CODEC,
    _captp_version_id,
    _codec_id,
    _feature_mask,
)
from .._errors import (
    GlowcapError,
    _check_host,
    _retain_cleanup_failure,
)
from .. import _trace
from .lifecycle import _LifecycleMixin
from .progress import _ProgressMixin
from .publication import _PublicationMixin
from .vows import VowTable
from .finalizer import (
    _HostFinalizerState,
    _drain_deferred_finalizer_states,
    _release_finalizer_state,
    _release_unpublished_host,
)

if TYPE_CHECKING:
    from .._context import Context
    from .._loop import DriverLoop
    from .._session import Session
    from .._transport import Connector
    from .._trampoline import _BehaviorEntry
from .._ffi_host import _host
from .._ffi_ocapn import _byte_buf
from .._gc import HostGc, bind_host

_ERR_CLOSED = _abi.ERR_CLOSED


_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT

# Every connection's maximum admissible frame; mirrors GLOWCAP_DEFAULT_FRAME_CAP.
_HOST_FRAME_CAP = _abi.DEFAULT_FRAME_CAP


class Host(_LifecycleMixin, _PublicationMixin, _ProgressMixin):
    """The CapTP Host: one identity, one session directory, one routing and redeem
    authority, shared by every session minted against it. It owns
    ``engine.Node`` in the Zig core behind ``libglowcap_host`` (ADR-0022).
    This is the host-idiom residue over it: the :class:`Session` registry,
    the vow table, the action drain that performs the I/O the host asks for
    (dial, flush, settle, entropy), and the iroh redeem posture.

    ``seed`` is the Host's 32-byte Ed25519 identity (``None`` draws a fresh
    random one: entropy at the binding boundary, never inside the sans-io
    host). ``profile`` selects the core-authored ``glowcap`` or ``interop``
    codec/version pair. The individual ``codec`` and ``captp_version`` knobs
    remain available when no profile is named. ``features`` completes the Host's
    signed offer. Each session settles version and codec with its
    partner, falling back to v1.0/Syrup when needed, and runs only the
    intersection of the two offered feature sets. Omitted profile options use
    the generated C ABI defaults. ``context`` routes every byte the host owns
    through a caller-supplied allocation scope (:class:`Context`).
    ``local_turn_budget`` caps local-turn amplification per session
    (ADR-0018): ``0`` applies the Host's finite default, ``0xFFFF_FFFF`` (the C
    ABI's ``GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED``) turns the cap off, and any
    other value is the cap."""

    def __init__(
        self,
        seed: Optional[bytes] = None,
        *,
        profile: Optional[str] = None,
        codec: Optional[str] = None,
        captp_version: Optional[str] = None,
        features=_DEFAULT_FEATURES,
        context: "Optional[Context]" = None,
        local_turn_budget: int = 0,
        _adopt_raw: Optional[int] = None,
        _driver_loop: "Optional[DriverLoop]" = None,
    ):
        # `_adopt_raw` plus `_driver_loop` is the loop tier's adoption seam
        # (ADR-0024): the FFI driver archive owns the host handle, and this
        # wrapper adopts it for the application verbs. In that mode the C loop
        # is the action drain, the kick verbs nudge a loop step instead of
        # running the Python drain, and close belongs to `DriverLoop.close`.
        if _adopt_raw is not None and _driver_loop is None:
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT, "loop adoption requires the DriverLoop"
            )
        if profile not in (None, "interop", "glowcap"):
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT, f"unknown Host profile {profile!r}"
            )
        if profile is not None and (codec is not None or captp_version is not None):
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "Host profile cannot be combined with codec or captp_version",
            )
        codec = (
            _OWN_CODEC
            if profile == "glowcap"
            else _INTEROP_CODEC
            if profile == "interop"
            else (_DEFAULT_CODEC if codec is None else codec)
        )
        captp_version = (
            _OWN_CAPTP_VERSION
            if profile == "glowcap"
            else _INTEROP_CAPTP_VERSION
            if profile == "interop"
            else (_DEFAULT_CAPTP_VERSION if captp_version is None else captp_version)
        )
        self._driver_loop: "Optional[DriverLoop]" = _driver_loop
        _drain_deferred_finalizer_states()
        self._raw: ctypes.c_void_p | None = None
        try:
            durable_seed = (
                bytes(memoryview(seed)) if seed is not None else secrets.token_bytes(32)
            )
        except (BufferError, TypeError, ValueError):
            raise GlowcapError(_ERR_INVALID_ARGUMENT, "seed must be 32 bytes") from None
        if len(durable_seed) != 32:
            raise GlowcapError(_ERR_INVALID_ARGUMENT, "seed must be 32 bytes")
        # `bytes` is immutable and copies mutable bytes-like caller input, so the
        # FFI identity and every later designator read the same owned value.
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
        # Every Host has one diagnostic/allocation owner. A process-supplied
        # Context is retained; otherwise the binding creates the same owner
        # implicitly instead of bypassing the central seam.
        if context is None and _adopt_raw is None:
            from .._context import Context

            context = Context()
        self._context = context
        self._diagnostic_id = 0
        # Every live session by its GlowcapHostSession address, so a FLUSH
        # action routes to the transport that owns the bytes and a dialed
        # exporter stays reachable for teardown.
        self._sessions: "dict[int, Session]" = {}
        # The vow table the drain's SETTLE/FAIL arms settle.
        self._vows = VowTable(self._gc)
        # Host-owned async behavior settlements, retained because the event
        # loop holds tasks only weakly.
        self._behavior_tasks: "set[asyncio.Task]" = set()
        # Exact terminal occurrences in observation order. The shared helper
        # bounds retained objects while preserving the total count.
        self._terminal_failures: "list[BaseException]" = []
        self._terminal_failure_count = 0
        # Every admitted action drain, including directly awaited drains. Host
        # release joins this barrier before invalidating FFI storage.
        self._action_drains: "set[asyncio.Task]" = set()
        # The shared close-activity event (wake-all): a close driver clears it
        # before reading FFI close progress, and every FFI verb that can
        # advance close-relevant state sets it after the verb returns, so a
        # parked driver cannot miss a wakeup.
        self._close_activity = asyncio.Event()
        # A popped DIAL is not in the C action queue. Its executor is
        # therefore Host-owned until it reports success/failure or teardown
        # cancels it; caller cancellation of one drain must not strand a ticket.
        self._dial_tasks: "dict[tuple[int, int], asyncio.Task]" = {}
        # Async teardown retains one join task so a second owner cannot free the
        # FFI Host while the first owner is still joining its DIAL tasks.
        self._release_task: "Optional[asyncio.Task]" = None
        self._release_started = False
        # Trampoline ctx of each Host publication, by published name, so
        # `Session.published_ref` can find the one it must bind. The registry is
        # process-global, not host-scoped, so nothing drops these when the host
        # dies: close() frees them, or one row leaks per Host publication per Host
        # generation.
        self._publications: "dict[str, int]" = {}
        # Every ordinary Session.spawn/publish trampoline on this Host. Actors
        # live in the Host Vat, so closing the Port that first projected one
        # must not unregister behavior another Port can still call.
        self._hosted: "dict[int, int]" = {}
        # Ctx ids a re-publish displaced. Existing capabilities and gifts still
        # reach the old Host-Vat actor, so its trampoline stays registered until status-allow: replacement state identity
        # close() drops it with the rest.
        self._displaced_publications: "list[int]" = []
        # Strong ownership of process-global callback entries belongs to the
        # Host, not the global lookup. This map may contain a behavior that
        # captures this Host; Python's collector can reclaim that local cycle.
        self._behavior_entries: "dict[int, _BehaviorEntry]" = {}
        # Explicit byte-fed connectors retained by transport symbol. A Host
        # never derives one from locator shape; this table is the authority
        # used by handoff redemption after the original connect registered it.
        self._connectors: "dict[str, Connector]" = {}
        if _adopt_raw is not None:
            self._raw = ctypes.c_void_p(_adopt_raw)
            diagnostic_id = ctypes.c_uint64()
            _check_host(
                _host.glowcap_host_diagnostic_id(self._raw, ctypes.byref(diagnostic_id))
            )
            self._diagnostic_id = diagnostic_id.value
            self._finalizer_state = _HostFinalizerState(
                self._raw,
                self._publications,
                self._displaced_publications,
                self._hosted,
                context,
                self._diagnostic_id,
            )
            self._finalizer = None
            assert _driver_loop is not None
            _driver_loop._adopt_host_finalizer_state(self._finalizer_state)
            _trace._attach_host(self, self.designator())
            bind_host(self._gc, self)
            return
        out = ctypes.c_void_p()
        # The durable identity followed by a session-key root drawn here, at
        # this binding's entropy boundary, because the library draws none
        # (ADR-0028). The root is fresh per process, so every CapTP session
        # signs with its own key and a restart cannot recreate a prior
        # session's handoff names; the durable half is ``seed``,
        # since a keyed locator's designator derives from it.
        sbuf, sptr = _byte_buf(self._seed + secrets.token_bytes(32))
        assert context is not None
        context_raw = context._acquire_handle()
        try:
            _check_host(
                _host.glowcap_host_new_in(
                    context_raw,
                    sptr,
                    64,
                    _HOST_FRAME_CAP,
                    1,
                    _codec_id(codec),
                    _captp_version_id(captp_version),
                    _feature_mask(features),
                    local_turn_budget,
                    0,
                    ctypes.byref(out),
                )
            )
        except BaseException:
            context._release_handle()
            raise
        self._raw = out
        diagnostic_id = ctypes.c_uint64()
        try:
            _check_host(
                _host.glowcap_host_diagnostic_id(out, ctypes.byref(diagnostic_id))
            )
        except BaseException as error:
            cleanup = _release_unpublished_host(out, context)
            self._raw = None
            if cleanup is not None:
                _retain_cleanup_failure(error, cleanup)
            raise
        self._diagnostic_id = diagnostic_id.value
        self._finalizer_state = _HostFinalizerState(
            out,
            self._publications,
            self._displaced_publications,
            self._hosted,
            context,
            self._diagnostic_id,
        )
        self._finalizer = weakref.finalize(
            self,
            _release_finalizer_state,
            self._finalizer_state,
            checked=False,
        )
        # The host's own key designator, the name a partner knows it by:
        # the live trace reports it as this host's endpoint so one peer stays
        # one node in a feed several producers share. The raw-only finalizer is
        # already armed in case this setup call refuses.
        _trace._attach_host(self, self.designator())
        bind_host(self._gc, self)

    @property
    def seed(self) -> bytes:
        """The immutable 32-byte identity seed retained by this Host."""
        return self._seed

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw GlowcapHost handle. Binding-internal: :class:`Session`
        mints and drives sessions against it. Raises once the host is
        released, rather than handing out the null the field then holds."""
        self._assert_owner()
        if self._raw is None:
            raise GlowcapError(_ERR_CLOSED, "the host has been released")
        return self._raw

    @property
    def raw_or_none(self):
        """Raw handle or ``None`` for the finalizer-safe GC seam."""
        return self._raw

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
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event-loop thread",
            )
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            if self._loop is not None:
                raise GlowcapError(
                    _ERR_INVALID_ARGUMENT,
                    "host must be driven from its owning event loop",
                )
            return
        if self._loop is None:
            self._loop = running
        elif running is not self._loop:
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event loop",
            )

    def _assert_owner(self) -> None:
        if not self._on_owner_thread():
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "host must be driven from its owning event-loop thread",
            )
        self._bind_running_loop()
        if self._trace_refresh_pending:
            _trace._refresh_host(self)

    def _schedule_cleanup(self, run) -> bool:
        """Schedule owner-loop cleanup when the caller is off-loop.

        Returns ``True`` when ``run`` was handed to the owner loop. This seam
        is for teardown only. Operational verbs use
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
        return self._raw is None

    @property
    def driver_loop(self):
        """The FFI driver loop that owns this Host, or None. Binding-internal."""
        return self._driver_loop

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
        loop, the top-level re-entry the host requires, and carries plain
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
        if _host.glowcap_host_turn_defer(turn, ctypes.byref(resolver_out)) != _abi.OK:
            return False
        resolver = resolver_out.value

        async def settle() -> None:
            try:
                value = await pending
            except asyncio.CancelledError:
                self._break_resolver(resolver, "async behavior cancelled")
                return
            except Exception as error:  # noqa: BLE001 - a raise breaks the answer
                self._break_resolver(resolver, str(error) or type(error).__name__)
                return
            self._settle_resolver(resolver, value)

        self._own_behavior_task(loop.create_task(settle()))
        return True

    def _own_behavior_task(self, task: "asyncio.Task") -> None:
        """Retain one admitted async behavior settlement through shutdown."""
        self._behavior_tasks.add(task)

        def done(finished: "asyncio.Task") -> None:
            self._behavior_tasks.discard(finished)
            if finished.cancelled():
                return
            error = finished.exception()
            if error is not None:
                self._record_terminal_failure(error)
                self.signal_close_activity()

        task.add_done_callback(done)

    async def _join_behavior_tasks(self) -> None:
        """Cancel and join settlements whose FFI resolver owner is closed."""
        current = asyncio.current_task()
        pending = tuple(task for task in self._behavior_tasks if task is not current)
        for task in pending:
            if not task.done():
                task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
            self._behavior_tasks.difference_update(pending)
