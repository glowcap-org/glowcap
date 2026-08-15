"""Internal: the asyncio face of the driver archive (ADR-0112).

One thread drives one native loop, and this wrapper is that thread's
choreography: park the running asyncio loop on the archive's one readiness
descriptor (``add_reader``), step with a zero timeout when it signals, and
drain the one event queue into futures. Provider starts are nonblocking, while
transport completion and CapTP handshakes advance through those steps. Sessions
arrive as OPENED and ACCEPTED events carrying real ``PancakeHostSession``
handles, so every ``pancake_host_*`` verb (bound in :mod:`pancake._ffi_host`
against this same library) works on them unchanged.

This tier drives separately linked provider packages, including sidecar
transports plugged in through the common provider seam. The loop receives a
complete locator and a selected provider; transport validation and realization
remain on the provider side. The byte-fed pump remains for explicit
embedder-supplied connectors and Hosts that already own such channels.
"""

from __future__ import annotations

import asyncio
import atexit
import ctypes
import secrets
import threading
import weakref
from typing import TYPE_CHECKING, Optional, Union

if TYPE_CHECKING:
    from ._host import Host

from . import _constants as _c
from ._codec import _codec_id
from ._errors import _check_host, _retain_terminal_failure, _vow_failure, PancakeError
from ._ffi_driver import (
    _driver,
    _DriverEvent,
    _DriverOptions,
    _TransportProvider,
)
from ._ffi_host import _CloseOptions, _host
from ._host_action_gen import HOST_ACTION_SETTLE, Fail, Settle, decode
from ._failure import FailureLayer, _record_runtime_failure
from ._lifecycle import PendingWork, _close_options
from ._locator import _OwnedLocator, Locator, parse_locator
from ._trampoline import _enter_deliver, _exit_deliver, _inside_turn

# Wakes every parked `accept` when the loop closes, so a server iteration ends
# instead of waiting on a queue nothing will ever feed again.
_ACCEPTS_CLOSED = object()


class _DriverFinalizerState:
    """Raw driver authority held without retaining its wrapper cycle."""

    __slots__ = ("handle", "host_state", "context", "release_failure_reported")

    def __init__(self, handle: int, context=None) -> None:
        self.handle: Optional[ctypes.c_void_p] = ctypes.c_void_p(handle)
        self.host_state = None
        self.context = context
        self.release_failure_reported = False


_deferred_driver_finalizers: list[_DriverFinalizerState] = []
_deferred_driver_finalizers_lock = threading.Lock()


def _release_driver_finalizer_state(state: _DriverFinalizerState) -> None:
    handle = state.handle
    if not handle:
        return
    rc = _driver.pancake_driver_release(handle)
    if rc != _c.OK:
        if not state.release_failure_reported:
            state.release_failure_reported = True
            error = PancakeError(rc, _last_driver_error())
            try:
                if state.context is None:
                    raise RuntimeError("driver finalizer has no surviving Context")
                state.context._report_failure(
                    layer=_c.FAILURE_LAYER_BINDING,
                    scope=_c.FAILURE_SCOPE_CONTEXT,
                    operation="driver-loop.finalize.release",
                    primary_name=type(error).__name__,
                    primary_result=error.code,
                    primary_message=str(error),
                )
            except BaseException as recorder_error:
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    "driver-loop.finalize.release",
                    error,
                )
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    "driver-loop.finalize.release.diagnostic",
                    recorder_error,
                )
        with _deferred_driver_finalizers_lock:
            if state.handle and state not in _deferred_driver_finalizers:
                _deferred_driver_finalizers.append(state)
        return
    state.handle = None
    if state.host_state is not None:
        from ._host import _retire_finalizer_state

        _retire_finalizer_state(state.host_state)
        state.host_state = None
    elif state.context is not None:
        state.context._release_handle()
    state.context = None


def _drain_driver_finalizers() -> None:
    with _deferred_driver_finalizers_lock:
        pending = list(_deferred_driver_finalizers)
        _deferred_driver_finalizers.clear()
    for state in pending:
        _release_driver_finalizer_state(state)


atexit.register(_drain_driver_finalizers)


def _driver_event_failure(event: "LoopEvent", operation: str) -> PancakeError:
    """Project an authoritative driver-event result with its diagnostic."""
    detail = (
        f"{operation} failed: {event.primary_name}"
        if event.primary_name
        else f"{operation} failed"
    )
    error = PancakeError(event.primary_result, detail)
    error.secondary_count = event.secondary_count
    if event.secondary_count:
        error.secondary = (
            PancakeError(event.secondary_result, event.secondary_name or None),
        )
    return error


def _driver_options(
    wire_buffer_bytes: int,
    max_pending_opens: int,
    handshake_ms: int,
    listener_setup_ms: int,
    settle_ms: int,
) -> _DriverOptions:
    fields = (
        ("wire_buffer_bytes", wire_buffer_bytes, ctypes.c_size_t(-1).value),
        ("max_pending_opens", max_pending_opens, ctypes.c_size_t(-1).value),
        ("handshake_ms", handshake_ms, ctypes.c_uint32(-1).value),
        ("listener_setup_ms", listener_setup_ms, ctypes.c_uint32(-1).value),
        ("settle_ms", settle_ms, ctypes.c_uint32(-1).value),
    )
    for name, value, maximum in fields:
        if (
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
            or value > maximum
        ):
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT,
                f"{name} must be an unsigned integer representable by the C field",
            )
    return _DriverOptions(
        _c.DRIVER_OPTIONS_ABI_VERSION,
        ctypes.sizeof(_DriverOptions),
        wire_buffer_bytes,
        max_pending_opens,
        handshake_ms,
        listener_setup_ms,
        settle_ms,
    )


def _last_driver_error() -> Optional[str]:
    buf = ctypes.create_string_buffer(512)
    n = _driver.pancake_driver_last_error(buf, len(buf))
    if n == 0:
        return None
    return buf.raw[: min(n, len(buf))].split(b"\x00", 1)[0].decode("utf-8", "replace")


def _check(rc: int) -> None:
    if rc != _c.OK:
        raise PancakeError(rc, _last_driver_error())


def _as_driver_error(error: BaseException) -> PancakeError:
    if isinstance(error, PancakeError):
        return error
    return PancakeError(_c.ERR_INTERNAL, f"driver loop failed: {error}")


class _StepDeliverContext:
    """What a loop step's behavior callbacks read as the arriving deliver
    context. The byte-fed pump brackets its synchronous feed with the arriving
    :class:`Session`, and the trampoline reads ``.host`` off that bracket to
    latch the turn to its Host (turn-time spawn) and to own an async
    behavior's deferral. A loop step is the feed here, so it brackets itself
    with this carrier over the loop's adopted wrapper Host."""

    __slots__ = ("host",)

    def __init__(self, host) -> None:
        self.host = host


class LoopEvent:
    """One drained loop event, in owned form (the C views die at the next
    pop, so byte payloads are copied out here)."""

    __slots__ = (
        "kind",
        "primary_result",
        "secondary_result",
        "secondary_count",
        "operation_id",
        "listener_id",
        "session",
        "primary_name",
        "secondary_name",
        "settled_ok",
        "decoded",
    )

    def __init__(
        self,
        kind: int,
        primary_result: int,
        secondary_result: int,
        secondary_count: int,
        operation_id: int,
        listener_id: int,
        session: Optional[int],
        primary_name: str = "",
        secondary_name: str = "",
        settled_ok: bool = False,
        decoded: object = None,
    ) -> None:
        self.kind = kind
        self.primary_result = primary_result
        self.secondary_result = secondary_result
        self.secondary_count = secondary_count
        self.operation_id = operation_id
        self.listener_id = listener_id
        self.session = session
        self.primary_name = primary_name
        self.secondary_name = secondary_name
        self.settled_ok = settled_ok
        self.decoded = decoded


class ListenerOwner:
    """Ownership of exactly one native driver listener.

    The owner closes admission for its listener and releases only accepted
    handles that have not crossed into a public Session. It never owns the
    loop, Host, or sibling listeners.
    """

    __slots__ = ("_loop", "listener", "_closed", "_ready", "_failure")

    def __init__(self, loop: "DriverLoop", listener: int) -> None:
        self._loop = loop
        self.listener = listener
        self._closed = False
        self._ready = False
        self._failure: Optional[PancakeError] = None

    @property
    def ready(self) -> bool:
        """Whether the provider has completed listener construction."""
        return self._ready

    @property
    def failure(self) -> Optional[PancakeError]:
        """The terminal setup failure, if construction was rejected."""
        return self._failure

    def _mark_ready(self) -> None:
        self._ready = True

    def _mark_failed(self, error: PancakeError) -> None:
        self._failure = error
        self._closed = True

    def close(self) -> None:
        if self._closed:
            return
        if self._loop._released:
            self._closed = True
            return
        self._loop.close_listener(self.listener)


class DriverLoop:
    """One stepping native loop over one multi-session host.

    Construct with :meth:`open` on the asyncio thread that will drive it,
    ``start()`` to park on the readiness descriptor, and ``close()`` before
    dropping it. ``host`` is a real ``PancakeHost`` handle
    for every application verb.
    """

    def __init__(self, handle: int, host: int, context=None) -> None:
        self._h = ctypes.c_void_p(handle)
        self._host = ctypes.c_void_p(host)
        self._aio: Optional[asyncio.AbstractEventLoop] = None
        self._fd: Optional[int] = None
        self._stepping = False
        self._pending_dials: dict[int, asyncio.Future[int]] = {}
        self._progress_timer: Optional[asyncio.TimerHandle] = None
        self._completions: dict[int, asyncio.Future[bool]] = {}
        self._accepts: "dict[int, asyncio.Queue[Union[int, object]]]" = {}
        self._listeners: dict[int, ListenerOwner] = {}
        self._listener_waiters: dict[int, asyncio.Future[None]] = {}
        # Event-delivered handles not yet wrapped. The pair preserves both
        # terminal state and its exact failure when SESSION_CLOSED follows an
        # OPENED/ACCEPTED event in the same drain.
        self._unclaimed_sessions: dict[int, tuple[bool, Optional[PancakeError]]] = {}
        self._session_closes: dict[int, asyncio.Future[None]] = {}
        self._wrapper: "Optional[Host]" = None
        self._seed_material: Optional[bytes] = None
        self._codec = "syrup"
        self._released = False
        self._release_attempted = False
        self._terminal_failure: "Optional[PancakeError]" = None
        self._terminal_failures: "list[BaseException]" = []
        self._terminal_failure_count = 0
        self._closing = False
        self._close_task: "Optional[asyncio.Task[None]]" = None
        self._close_error: "Optional[BaseException]" = None
        self._started = False
        self._closed_event = asyncio.Event()
        # The shared loop-activity notifier (wake-all): a close driver clears
        # it before stepping, and every path that steps the loop or drains its
        # events sets it after running work. Mirrors the byte-fed Host tier's
        # close-activity event one tier down.
        self._loop_activity = asyncio.Event()
        # Session close drivers, retained strongly for their lifetime because
        # asyncio holds tasks weakly.
        self._session_close_tasks: set["asyncio.Task[None]"] = set()
        self._finalizer_state = _DriverFinalizerState(handle, context)
        self._finalizer = weakref.finalize(
            self, _release_driver_finalizer_state, self._finalizer_state
        )

    def _adopt_host_finalizer_state(self, state) -> None:
        """Transfer detached Host bookkeeping to this loop's raw finalizer."""
        current = self._finalizer_state.host_state
        if current is not None and current is not state:
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT, "driver loop already owns a Host wrapper"
            )
        self._finalizer_state.host_state = state
        self._finalizer_state.context = None

    # ── Lifecycle ────────────────────────────────────────────────────────────

    @classmethod
    def open(
        cls,
        seed: Optional[bytes] = None,
        *,
        codec: str = "syrup",
        frame_cap: int = 1 << 16,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        listener_setup_ms: int = _c.DRIVER_DEFAULT_LISTENER_SETUP_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Create the loop. ``seed`` is the host constructor's 64-byte
        contract (durable identity, then a fresh session-key root); ``None``
        draws both halves fresh."""
        options = _driver_options(
            wire_buffer_bytes,
            max_pending_opens,
            handshake_ms,
            listener_setup_ms,
            settle_ms,
        )
        material = seed if seed is not None else secrets.token_bytes(64)
        if len(material) != 64:
            raise PancakeError(_c.ERR_INVALID_ARGUMENT, "seed must be 64 bytes")
        from ._context import Context

        context = Context()
        context_raw = context._acquire_handle()
        host = ctypes.c_void_p(None)
        try:
            _check_host(
                _host.pancake_host_new_in(
                    context_raw,
                    material,
                    len(material),
                    frame_cap,
                    1,
                    _codec_id(codec),
                    _c.CAPTP_V1_0,
                    _c.FEATURE_FULL,
                    0,
                    ctypes.byref(host),
                )
            )
        except BaseException:
            context._release_handle()
            raise
        assert host.value is not None
        slot = ctypes.c_void_p(None)
        try:
            _check(
                _driver.pancake_driver_take_host(
                    host,
                    ctypes.byref(options),
                    ctypes.byref(slot),
                )
            )
        except BaseException:
            _host.pancake_host_release(host)
            context._release_handle()
            raise
        assert slot.value is not None
        loop = cls(slot.value, host.value, context)
        loop._seed_material = material
        loop._codec = codec
        return loop

    @classmethod
    def take_host(
        cls,
        host: "Host",
        *,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        listener_setup_ms: int = _c.DRIVER_DEFAULT_LISTENER_SETUP_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Transfer a byte-fed Host into a native driver transactionally.

        ``pancake_driver_take_host`` is called before the Python Host changes
        state. On failure the caller still owns the original Host; on success
        this exact Host wrapper becomes the loop's application face and the
        loop becomes its sole native release authority.
        """
        if host.driver_loop is not None:
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT, "host already belongs to a driver loop"
            )
        raw = host.raw
        options = _driver_options(
            wire_buffer_bytes,
            max_pending_opens,
            handshake_ms,
            listener_setup_ms,
            settle_ms,
        )
        out = ctypes.c_void_p(None)
        _check(
            _driver.pancake_driver_take_host(
                raw,
                ctypes.byref(options),
                ctypes.byref(out),
            )
        )
        assert out.value is not None
        assert raw.value is not None
        loop = cls(out.value, raw.value)
        loop._codec = host.codec
        loop._wrapper = host
        loop._adopt_host_finalizer_state(host._adopt_driver_loop(loop))
        return loop

    @property
    def host(self) -> ctypes.c_void_p:
        """The wrapped ``PancakeHost`` handle for ``pancake_host_*`` verbs.
        Never release it separately; ``close`` releases the loop and the
        host together."""
        return self._host

    def schedule_step(self) -> None:
        """Schedule one loop step soon, from the driving thread — how a
        wrapper verb's kick reaches the drain. A thread-driven loop (no
        :meth:`start`) pumps continuously and needs no nudge."""
        if self._released or self._terminal_failure is not None:
            return
        if self._aio is not None:
            try:
                self._aio.call_soon(self._step_background)
            except BaseException as error:
                self._fail_background(error)
                failure = self._terminal_failure
                assert failure is not None
                raise failure from error

    def _step_background(self) -> None:
        """Drive one scheduled step and terminalize any uncaught failure."""
        try:
            self.step_now()
        except BaseException as error:
            self._fail_background(error)

    def _fail_background(self, error: BaseException) -> None:
        """Complete every binding waiter before releasing a failed loop."""
        if self._terminal_failure is not None:
            self._record_terminal_failure(error)
            return
        failure = _as_driver_error(error)
        self._terminal_failure = failure
        self._close_error = failure
        self._record_terminal_failure(failure)
        if self._aio is not None and self._fd is not None:
            self._aio.remove_reader(self._fd)
        if self._progress_timer is not None:
            self._progress_timer.cancel()
            self._progress_timer = None
        for dial_future in self._pending_dials.values():
            if not dial_future.done():
                dial_future.set_exception(failure)
        self._pending_dials.clear()
        for listener_future in self._listener_waiters.values():
            if not listener_future.done():
                listener_future.set_exception(failure)
        self._listener_waiters.clear()
        for completion_future in self._completions.values():
            if not completion_future.done():
                completion_future.set_exception(failure)
        self._completions.clear()
        for close_future in self._session_closes.values():
            if not close_future.done():
                close_future.set_exception(failure)
        self._session_closes.clear()
        for owner in self._listeners.values():
            owner._mark_failed(failure)
        for accepts in self._accepts.values():
            accepts.put_nowait(failure)
        self._listeners.clear()
        self._unclaimed_sessions.clear()
        if self._wrapper is not None:
            self._wrapper._driver_failed(failure)
        if self._release_attempted:
            self._closed_event.set()
            return
        self._release_attempted = True
        try:
            _check(_driver.pancake_driver_release(self._h))
        except BaseException as release_error:
            self._record_terminal_failure(release_error)
            self._closed_event.set()
            return
        self._released = True
        self._finalizer_state.handle = None
        self._finalizer.detach()
        if self._wrapper is not None:
            self._wrapper._driver_did_release()
        self._closed_event.set()

    def _record_terminal_failure(self, error: BaseException) -> None:
        self._terminal_failure_count = _retain_terminal_failure(
            self._terminal_failures, self._terminal_failure_count, error
        )

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        """Loop-owned terminal failures in observation order."""
        return tuple(self._terminal_failures)

    @property
    def terminal_failure_count(self) -> int:
        """Total distinct terminal occurrences, including bounded overflow."""
        return self._terminal_failure_count

    def _native_session_release(self, ptr: ctypes.c_void_p) -> None:
        value = ptr.value
        if self._released:
            return
        _check(_driver.pancake_driver_session_release(self._h, ptr))
        if value is not None:
            self._unclaimed_sessions.pop(value, None)
        # The final application-owned release is what lets a retiring loop
        # reach CLOSED; wake any parked close driver to re-read progress.
        self._signal_loop_activity()

    def request_close(self) -> None:
        """Retire this loop after its application-owned sessions close.

        The driver seals admission and owns the final-session transition.
        This binding only starts the task that drives the native barrier.
        """
        if self._released or self._closing:
            return
        _check(_driver.pancake_driver_retire(self._h))
        # Retire changes what a step can conclude while a close driver may
        # already be parked; wake it so it re-reads progress.
        self._signal_loop_activity()
        self._closing = True
        self._start_close_driver()

    async def connect_session(
        self,
        locator: Union[Locator, str],
    ):
        """Dial through the loop and wrap the opened session as the public
        :class:`pancake.Session`, over the adopted wrapper Host: every session
        verb, promise, and trampoline works on it, with the native loop as
        the transport and the drain."""
        ptr = await self.dial(locator)
        return self.adopt_session(ptr)

    def adopt_session(self, ptr: int):
        """Transfer one event-delivered native handle into a Session wrapper."""
        from ._session import Session

        host = self.wrapper_host()
        existing = host.get_session(ptr)
        if existing is not None:
            return existing
        closed, failure = self._unclaimed_sessions.get(ptr, (False, None))
        transport = _LoopTransport(self, ptr)
        session = Session(ctypes.c_void_p(ptr), host, transport)
        self._unclaimed_sessions.pop(ptr, None)
        if closed:
            if failure is None:
                transport.mark_closed()
            else:
                transport.mark_failed(failure)
            session.close_transport()
        return session

    def wrapper_host(self) -> "Host":
        """The public :class:`pancake.Host` wrapper adopted over this loop's
        native host (ADR-0112): application verbs, publish trampolines, and
        ``RemotePromise`` settles all work on it, while the loop stays the one
        action drain and the one release authority. Built on first call; call
        it on the driving thread."""
        if self._wrapper is None:
            from ._host import Host

            assert self._seed_material is not None
            self._wrapper = Host(
                seed=self._seed_material[:32],
                codec=self._codec,
                _adopt_raw=self.host.value,
                _driver_loop=self,
                context=self._finalizer_state.context,
            )
        return self._wrapper

    def close(self, options: "Optional[_CloseOptions]" = None) -> None:
        """Begin or escalate the core-owned native close barrier."""
        if self._released:
            return
        if options is None:
            options = _close_options(PendingWork.CANCEL)
        _check(_driver.pancake_driver_close(self._h, ctypes.byref(options)))
        # The close call escalates pending-work policy and may install a new
        # finite deadline while a close driver is already parked without a
        # timer; wake it so it re-reads the wait budget.
        self._signal_loop_activity()
        self._closing = True
        self._start_close_driver()

    def _start_close_driver(self) -> None:
        if self._close_task is not None:
            return
        if self._aio is None:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                asyncio.run(self._drive_close())
                return
        else:
            loop = self._aio
        self._close_task = loop.create_task(self._drive_close())

    def serve_session(self, ptr: int) -> None:
        """Announce the embedder is serving the session at ``ptr``: post-open
        setup is done, so the loop may deliver its inbound (bytes that arrived
        early replay in order). Idempotent; the loop tier's spelling of the
        byte-fed rule that ``serve`` resumes frames held behind the
        handshake."""
        if self._terminal_failure is not None:
            raise self._terminal_failure
        if self._released or not ptr:
            return
        _check(_driver.pancake_driver_session_serve(self._h, ctypes.c_void_p(ptr)))
        self.schedule_step()

    def _arm_loop_activity(self) -> None:
        """Arm the shared loop-activity waiter. A close driver arms before it
        steps (the lost-wakeup discipline): progress landing after the arm
        sets the event and wakes :meth:`_wait_step_wake`, and progress landing
        before it is visible to the lifecycle read that follows."""
        self._loop_activity.clear()

    def _signal_loop_activity(self) -> None:
        """Wake every parked close driver. Called after any path that steps
        the loop or drains its events ran work, and after a close verb that
        may install a new deadline. Over-signaling is harmless because the
        drivers re-check progress; a missed source is a hang."""
        self._loop_activity.set()

    def _step_wait_ms(self) -> int:
        """The longest a close driver may park before stepping again:
        milliseconds until the nearest pending-work deadline (the close grace,
        a session's close grace, a dial or listener setup budget), clamped at
        zero, or -1 when no finite deadline is pending and readiness alone
        advances the loop."""
        if self._released:
            return 0
        out = ctypes.c_int32()
        _check(_driver.pancake_driver_step_wait_ms(self._h, ctypes.byref(out)))
        return out.value

    async def _wait_step_wake(self) -> None:
        """Park a close driver until loop activity or the nearest pending-work
        deadline. A grace expiry takes effect only inside a step, so the
        deadline half of this wait is what turns an expired grace into the
        escalating step. The caller armed the activity event before its
        progress read."""
        wait_ms = self._step_wait_ms()
        if self._aio is None:
            # No readiness reader is armed, so this driver is the loop's only
            # pump: park inside the native step, which itself wakes on
            # readiness and honors the deadline bound.
            self.step(wait_ms)
            return
        if wait_ms < 0:
            # With no finite deadline pending, readiness wakes the armed
            # reader, whose step signals activity.
            await self._loop_activity.wait()
            return
        try:
            await asyncio.wait_for(self._loop_activity.wait(), wait_ms / 1_000)
        except TimeoutError:
            pass

    async def _drive_close(self) -> None:
        try:
            close_code = _c.OK
            while True:
                # Arm before stepping (the lost-wakeup discipline): a step that
                # ran work sets the armed event, so the wait below returns at
                # once and the loop re-checks instead of parking over undrained
                # work.
                self._arm_loop_activity()
                self.step_now()
                self._dispatch_many(self._pop_events())
                for session in list(self._session_closes):
                    self._finish_session_close(session)
                state = ctypes.c_uint32()
                rc = _driver.pancake_driver_lifecycle_state(
                    self._h, ctypes.byref(state)
                )
                if rc not in (_c.OK, _c.ERR_TIMEOUT):
                    _check(rc)
                close_code = rc
                if state.value == _c.LIFECYCLE_CLOSED:
                    break
                await self._wait_step_wake()
            self._finish_close(close_code)
        except BaseException as error:
            self._fail_background(error)

    def _finish_close(self, close_code: int) -> None:
        if self._aio is not None and self._fd is not None:
            self._aio.remove_reader(self._fd)
        if self._progress_timer is not None:
            self._progress_timer.cancel()
            self._progress_timer = None
        try:
            self._release_attempted = True
            try:
                _check(_driver.pancake_driver_release(self._h))
            except BaseException as error:
                self._record_terminal_failure(error)
                raise
            self._released = True
            self._finalizer_state.handle = None
            self._finalizer.detach()
            for accepts in self._accepts.values():
                accepts.put_nowait(_ACCEPTS_CLOSED)
            for owner in self._listeners.values():
                owner._closed = True
            self._listeners.clear()
            self._accepts.clear()
            closed = PancakeError(_c.ERR_CLOSED, "the driver loop is closed")
            for dial_future in self._pending_dials.values():
                if not dial_future.done():
                    dial_future.set_exception(closed)
            self._pending_dials.clear()
            for listener_future in self._listener_waiters.values():
                if not listener_future.done():
                    listener_future.set_exception(closed)
            self._listener_waiters.clear()
            for close_future in self._session_closes.values():
                if not close_future.done():
                    close_future.set_exception(closed)
            self._session_closes.clear()
            self._unclaimed_sessions.clear()
            if self._wrapper is not None:
                # Native release is the transfer's terminal boundary. Retire
                # wrapper-owned callbacks and its Context borrow only after
                # every native allocation has reached that allocator's free.
                self._wrapper._driver_did_release()
        finally:
            if close_code == _c.ERR_TIMEOUT:
                self._close_error = PancakeError(
                    _c.ERR_TIMEOUT, "finish close exhausted its grace period"
                )
            self._closed_event.set()

    async def wait_closed(self) -> None:
        """Wait until native loop and resident ownership have been released."""
        await self._closed_event.wait()
        if self._close_error is not None:
            raise self._close_error

    def session_release(self, session: int) -> None:
        """Release one loop-owned session: the loop spelling of
        ``pancake_host_session_release``, which must not be called on
        sessions this loop minted."""
        _check(
            _driver.pancake_driver_session_release(self._h, ctypes.c_void_p(session))
        )

    def claim_reference_exporter(self, reference) -> Optional[int]:
        """Resolve and claim the exporter session named by one Host capability."""
        out = ctypes.c_void_p()
        _check(
            _driver.pancake_driver_claim_reference_exporter(
                self._h,
                ctypes.byref(reference),
                ctypes.byref(out),
            )
        )
        return out.value

    async def close_session(
        self, session: ctypes.c_void_p, options: _CloseOptions
    ) -> None:
        """Close one loop-owned session through the native completion barrier."""
        aio = self._started_loop()
        key = session.value
        if key is None:
            return
        future = self._session_closes.get(key)
        created = future is None
        if future is None:
            future = aio.create_future()
            self._session_closes[key] = future
        try:
            _check(
                _driver.pancake_driver_session_close(
                    self._h,
                    session,
                    ctypes.byref(options),
                )
            )
        except BaseException:
            if created:
                self._session_closes.pop(key, None)
                future.cancel()
            raise
        # The close call escalates pending-work policy and may install a new
        # finite deadline while a close driver (this session's or the loop's)
        # is already parked; wake it so it re-reads the wait budget.
        self._signal_loop_activity()
        self._finish_session_close(key)
        if created and self._session_closes.get(key) is future:
            task = aio.create_task(self._drive_session_close(key, future))
            self._session_close_tasks.add(task)
            task.add_done_callback(self._session_close_tasks.discard)
        await asyncio.shield(future)

    async def _drive_session_close(
        self, session: int, future: "asyncio.Future[None]"
    ) -> None:
        """The deadline-stepper behind one session's native close barrier: a
        grace expiry takes effect only inside a step, so this driver steps on
        every loop-activity or deadline wake until the session's lifecycle
        turns terminal. Escalating repeats of :meth:`close_session` share
        it."""
        try:
            while not self._released and self._session_closes.get(session) is future:
                # Arm before stepping (the lost-wakeup discipline); loop-wide
                # activity or another owner's deadline waking this driver
                # early is harmless because it re-checks.
                self._arm_loop_activity()
                self.step_now()
                self._finish_session_close(session)
                if self._session_closes.get(session) is not future:
                    break
                await self._wait_step_wake()
        except BaseException as error:
            self._fail_background(error)

    def _finish_session_close(self, session: int) -> None:
        future = self._session_closes.get(session)
        if future is None:
            return
        state = ctypes.c_uint32()
        rc = _driver.pancake_driver_session_lifecycle_state(
            self._h,
            ctypes.c_void_p(session),
            ctypes.byref(state),
        )
        if rc not in (_c.OK, _c.ERR_TIMEOUT):
            self._session_closes.pop(session, None)
            future.set_exception(PancakeError(rc, "native session close failed"))
            return
        if state.value != _c.LIFECYCLE_CLOSED:
            return
        self._session_closes.pop(session, None)
        if rc == _c.ERR_TIMEOUT:
            future.set_exception(
                PancakeError(_c.ERR_TIMEOUT, "finish close exhausted its grace period")
            )
        else:
            future.set_result(None)

    # ── Extension transports ────────────────────────────────────────────────

    def _install_provider(self, prepare) -> None:
        """Install one package while its archive-owned construction owner is live.

        ``prepare`` receives a registrar valid only for the dynamic extent of
        this call, so copied callback tables cannot escape independently of
        the object they borrow.
        """
        registered = False
        active = True

        def register(package: _TransportProvider) -> None:
            nonlocal registered
            if not active or registered:
                raise RuntimeError("provider registrar is no longer active")
            _check(_driver.pancake_driver_add_provider(self._h, ctypes.byref(package)))
            registered = True

        try:
            prepare(register)
            if not registered:
                raise RuntimeError("provider installer did not register a package")
        finally:
            active = False

    def _has_transport(self, transport: Union[str, bytes]) -> bool:
        """Ask the native provider registry whether ``transport`` is owned."""
        name = transport.encode() if isinstance(transport, str) else transport
        present = ctypes.c_uint8(0)
        _check(
            _driver.pancake_driver_has_transport(
                self._h, name, len(name), ctypes.byref(present)
            )
        )
        return present.value != 0

    # ── Parking and stepping ─────────────────────────────────────────────────

    def start(self) -> None:
        """Arm the readiness descriptor and park the running asyncio loop on
        it. From here the loop steps whenever native work is ready."""
        if self._started:
            return
        self._aio = asyncio.get_running_loop()
        fd = ctypes.c_int32(-1)
        _check(_driver.pancake_driver_readiness_fd(self._h, ctypes.byref(fd)))
        self._fd = fd.value
        self._aio.add_reader(self._fd, self._on_ready)
        self._started = True

    def _started_loop(self) -> asyncio.AbstractEventLoop:
        loop = self._aio
        if loop is None:
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT,
                "call DriverLoop.start() before using asynchronous loop operations",
            )
        return loop

    def _on_ready(self) -> None:
        if self._stepping or self._released or _inside_turn():
            return
        self._step_background()

    def step_now(self) -> None:
        """Drain zero-timeout steps and events through quiescence on the loop
        thread. Call after ``pancake_host_*`` verbs so queued flushes reach the
        wire before the next park."""
        self.step(0)

    def step(self, timeout_ms: int) -> None:
        """Wait up to ``timeout_ms``, then drain steps and events through
        quiescence. This is the whole pump for a loop driven by a plain thread
        instead of asyncio (a server that never calls :meth:`start`)."""
        if self._terminal_failure is not None:
            raise self._terminal_failure
        if self._released or self._stepping or _inside_turn():
            return
        self._stepping = True
        # Whether any step observed work. This is the loop tier's one step
        # funnel — the readiness reader, `schedule_step`, the progress timer,
        # and the close drivers all step through here — so signaling on
        # progress here is what wakes a close driver parked on loop activity.
        # Signaling only when work ran keeps a close driver's own quiescent
        # steps from waking the waiter it just armed.
        progressed = False
        try:
            wait_ms = timeout_ms
            while self._step_native(wait_ms):
                progressed = True
                self._dispatch_many(self._pop_events())
                if self._wrapper is not None:
                    self._wrapper.drain_parked_releases()
                if self._released:
                    return
                wait_ms = 0
        finally:
            self._stepping = False
            if progressed:
                self._signal_loop_activity()
        self._rearm_progress_timer()

    def _step_native(self, timeout_ms: int) -> bool:
        """One native step, bracketed as the deliver it is: behaviors fire
        inside it, and the trampoline reads the bracket to latch their turns
        to this loop's wrapper Host. ``False`` is successful quiescence."""
        if self._wrapper is None:
            rc = _driver.pancake_driver_step(self._h, timeout_ms)
        else:
            prior = _enter_deliver(_StepDeliverContext(self._wrapper))
            try:
                rc = _driver.pancake_driver_step(self._h, timeout_ms)
            finally:
                _exit_deliver(prior)
        if rc == _c.WOULD_BLOCK:
            return False
        _check(rc)
        return True

    def _pop_events(self) -> list[LoopEvent]:
        out: list[LoopEvent] = []
        event = _DriverEvent()
        while True:
            rc = _driver.pancake_driver_next_event(self._h, ctypes.byref(event))
            if rc == _c.WOULD_BLOCK:
                return out
            _check(rc)
            primary_name = ""
            secondary_name = ""
            settled_ok = False
            operation_id = event.operation_id
            listener_id = event.listener_id
            if (
                event.kind
                in (
                    _c.DRIVER_EVENT_OPEN_FAILED,
                    _c.DRIVER_EVENT_LISTENER_FAILED,
                    _c.DRIVER_EVENT_SESSION_CLOSED,
                )
                and event.primary_name
            ):
                primary_name = ctypes.string_at(
                    event.primary_name, event.primary_name_len
                ).decode(
                    "utf-8", "replace"
                )
                if event.secondary_name:
                    secondary_name = ctypes.string_at(
                        event.secondary_name, event.secondary_name_len
                    ).decode("utf-8", "replace")
            decoded: object = None
            if event.kind == _c.DRIVER_EVENT_COMPLETION:
                settled_ok = event.action.kind == HOST_ACTION_SETTLE
                # Decode into owned Python values while the C views are live
                # (they die at the next pop): the same generated decoder the
                # byte-fed drain uses, so a wrapper-routed settle carries the
                # same value shapes.
                decoded = decode(event.action)
                if not settled_ok and event.action.message:
                    primary_name = ctypes.string_at(
                        event.action.message, event.action.message_len
                    ).decode("utf-8", "replace")
            out.append(
                LoopEvent(
                    event.kind,
                    event.primary_result,
                    event.secondary_result,
                    event.secondary_count,
                    operation_id,
                    listener_id,
                    event.session,
                    primary_name,
                    secondary_name,
                    settled_ok,
                    decoded,
                )
            )

    def _dispatch_many(self, events: list[LoopEvent]) -> None:
        for event in events:
            self._dispatch(event)
        if self._wrapper is not None and events:
            # A behavior that closed its session inside a step parked the
            # release (the C tier refuses mid-callback); the loop is the
            # feed here, so it drains the park the way the pump does.
            self._wrapper.drain_parked_releases()
        if events:
            # A drain outside `step` still advances close-relevant state
            # (session closes, releases); wake any parked close driver.
            self._signal_loop_activity()

    def _dispatch(self, event: LoopEvent) -> None:
        if event.kind == _c.DRIVER_EVENT_OPENED:
            future = self._pending_dials.pop(event.operation_id, None)
            if future is not None and not future.done():
                assert event.session is not None
                self._unclaimed_sessions[event.session] = (False, None)
                future.set_result(event.session)
            elif event.session is not None:
                self._unclaimed_sessions[event.session] = (False, None)
                self._native_session_release(ctypes.c_void_p(event.session))
        elif event.kind == _c.DRIVER_EVENT_OPEN_FAILED:
            future = self._pending_dials.pop(event.operation_id, None)
            if future is not None and not future.done():
                future.set_exception(
                    _driver_event_failure(event, "dial")
                )
        elif event.kind == _c.DRIVER_EVENT_LISTENER_READY:
            listener = self._listeners.get(event.listener_id)
            if listener is None or listener._closed:
                return
            listener._mark_ready()
            waiter = self._listener_waiters.pop(event.listener_id, None)
            if waiter is not None and not waiter.done():
                waiter.set_result(None)
        elif event.kind == _c.DRIVER_EVENT_LISTENER_FAILED:
            listener = self._listeners.get(event.listener_id)
            if listener is None:
                return
            failure = _driver_event_failure(event, "listener")
            self._finish_listener_close(event.listener_id, failure)
        elif event.kind == _c.DRIVER_EVENT_ACCEPTED:
            if event.session is not None:
                accepts = self._accepts.get(event.listener_id)
                if accepts is not None:
                    self._unclaimed_sessions[event.session] = (False, None)
                    accepts.put_nowait(event.session)
                else:
                    self._unclaimed_sessions[event.session] = (False, None)
                    self._native_session_release(ctypes.c_void_p(event.session))
                    raise PancakeError(
                        _c.ERR_INTERNAL,
                        f"accepted session names unknown listener {event.listener_id}",
                    )
        elif event.kind == _c.DRIVER_EVENT_SESSION_CLOSED:
            if event.session is not None:
                session_failure = (
                    _driver_event_failure(event, "session")
                    if event.primary_result != _c.OK
                    else None
                )
                # Observe the native barrier before Session.close_transport()
                # releases the opaque handle below.
                self._finish_session_close(event.session)
                wrapped = (
                    self._wrapper.get_session(event.session)
                    if self._wrapper is not None
                    else None
                )
                if wrapped is not None:
                    # The pump's EOF choreography, one tier up: end the
                    # serve task, then release the dead
                    # session so a later verb refuses ERR_CLOSED instead
                    # of minting a vow nothing can settle. The native
                    # side already broke the far vows in its close.
                    wrapped.closing_flag = True
                    transport = wrapped.transport
                    if isinstance(transport, _LoopTransport):
                        if session_failure is None:
                            transport.mark_closed()
                        else:
                            transport.mark_failed(session_failure)
                    wrapped.close_transport()
                elif event.session in self._unclaimed_sessions:
                    self._unclaimed_sessions[event.session] = (True, session_failure)
                else:
                    self._unclaimed_sessions[event.session] = (True, session_failure)
                    self._native_session_release(ctypes.c_void_p(event.session))
        elif event.kind == _c.DRIVER_EVENT_COMPLETION:
            if self._wrapper is not None and isinstance(event.decoded, (Settle, Fail)):
                host = self._wrapper
                if isinstance(event.decoded, Settle):
                    host.settle_vow(event.decoded.ticket, True, event.decoded.value)
                else:
                    host.settle_vow(
                        event.decoded.ticket,
                        False,
                        _vow_failure(event.decoded.result, event.decoded.message),
                    )
            if isinstance(event.decoded, (Settle, Fail)):
                done = self._completions.pop(event.decoded.ticket, None)
                if done is not None and not done.done():
                    if event.settled_ok:
                        done.set_result(True)
                    else:
                        assert isinstance(event.decoded, Fail)
                        done.set_exception(
                            _vow_failure(event.decoded.result, event.decoded.message)
                        )

    # ── Dial, accept, listen ─────────────────────────────────────────────────

    async def dial(
        self,
        locator: Union[Locator, str],
    ) -> int:
        """Begin a nonblocking dial and await its session handle. Connect
        completion and the handshake advance through zero-timeout native steps
        on the event-loop thread."""
        aio = self._started_loop()
        owned = (
            parse_locator(locator)
            if isinstance(locator, str)
            else Locator(
                locator.transport,
                locator.designator,
                dict(locator.hints),
                locator.hint_wire_form,
            )
        )
        future: asyncio.Future[int] = aio.create_future()
        self._begin_dial(owned, future)
        self.schedule_step()
        self._rearm_progress_timer()
        return await future

    def _begin_dial(
        self,
        locator: Locator,
        future: "asyncio.Future[int]",
    ) -> None:
        operation_id = ctypes.c_uint64(0)
        with _OwnedLocator.create(locator) as owned:
            _check(
                _driver.pancake_driver_dial(
                    self._h, owned.borrow_view(), None, ctypes.byref(operation_id)
                )
            )
        self._pending_dials[operation_id.value] = future

    def _rearm_progress_timer(self) -> None:
        """Project pancake's nearest pending-work deadline onto asyncio.

        The native driver owns which operation is due and all timeout policy;
        this binding owns only the scheduler timer that calls the next step.
        """
        if self._progress_timer is not None:
            self._progress_timer.cancel()
            self._progress_timer = None
        if (
            self._aio is None
            or self._released
            or self._terminal_failure is not None
        ):
            return
        wait_ms = self._step_wait_ms()
        if wait_ms < 0:
            return

        def tick() -> None:
            self._progress_timer = None
            if self._released or self._terminal_failure is not None:
                return
            self._step_background()

        try:
            self._progress_timer = self._aio.call_later(wait_ms / 1000, tick)
        except BaseException as error:
            self._fail_background(error)
            failure = self._terminal_failure
            assert failure is not None
            raise failure from error

    async def accept(self, listener: int) -> int:
        """Await the next accepted session handle (bind a listener first).
        Raises the typed ``ERR_CLOSED`` once the loop closes, so a server
        iteration ends rather than parking forever."""
        ready = self._take_accept_nowait(listener)
        if ready is not None:
            return ready
        accepts = self._accepts.get(listener)
        if accepts is None:
            raise PancakeError(_c.ERR_CLOSED, "the listener is closed")
        if self._released:
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        item = await accepts.get()
        if isinstance(item, PancakeError):
            accepts.put_nowait(item)
            raise item
        if not isinstance(item, int):
            # The close sentinel: re-arm it so every sibling accept ends too.
            accepts.put_nowait(_ACCEPTS_CLOSED)
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        return item

    def _take_accept_nowait(self, listener: int) -> Optional[int]:
        accepts = self._accepts.get(listener)
        if accepts is None:
            raise PancakeError(_c.ERR_CLOSED, "the listener is closed")
        if self._released:
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        try:
            item = accepts.get_nowait()
        except asyncio.QueueEmpty:
            return None
        if isinstance(item, PancakeError):
            accepts.put_nowait(item)
            raise item
        if not isinstance(item, int):
            accepts.put_nowait(_ACCEPTS_CLOSED)
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        return item

    def try_accept(self, listener: Union[int, "ListenerOwner"]) -> Optional[int]:
        """Claim one already-dispatched accepted handle without parking.

        This is the accept face for callers that drive :meth:`step` from a
        plain thread. ``None`` means another step or partner is needed.
        """
        return self._take_accept_nowait(self._listener_id(listener))

    def listen(
        self, transport: Union[str, bytes], designator: Union[str, bytes]
    ) -> "ListenerOwner":
        transport_b = transport.encode() if isinstance(transport, str) else transport
        designator_b = (
            designator.encode() if isinstance(designator, str) else designator
        )
        listener = ctypes.c_uint64(0)
        _check(
            _driver.pancake_driver_listen(
                self._h,
                transport_b,
                len(transport_b),
                designator_b,
                len(designator_b),
                None,
                ctypes.byref(listener),
            )
        )
        owner = ListenerOwner(self, listener.value)
        self._listeners[listener.value] = owner
        self._accepts[listener.value] = asyncio.Queue()
        return owner

    def _listener_id(self, listener: Union[int, "ListenerOwner"]) -> int:
        return listener.listener if isinstance(listener, ListenerOwner) else listener

    def listener_locator(self, listener: Union[int, "ListenerOwner"]) -> Locator:
        """Copy the listener's complete typed OCapN locator."""
        listener = self._listener_id(listener)
        from ._ffi_ocapn import _LocatorView

        view = _LocatorView()
        _check(
            _driver.pancake_driver_listener_locator(
                self._h, listener, ctypes.byref(view)
            )
        )
        with _OwnedLocator.clone_view(
            ctypes.cast(ctypes.byref(view), ctypes.c_void_p)
        ) as owned:
            return owned.value()

    def listener_restoration_state(
        self, listener: Union[int, "ListenerOwner"]
    ) -> bytes:
        """Copy opaque provider state used to restore a listener's local address.

        The driver owns the provider state and exposes only its size/copy ABI;
        this binding keeps the result as bytes and does not interpret transport
        vocabulary. A provider that has no restoration state raises its driver
        error instead of manufacturing one from the public locator.
        """
        listener = self._listener_id(listener)
        needed = ctypes.c_size_t()
        rc = _driver.pancake_driver_listener_restoration_state(
            self._h, listener, None, 0, ctypes.byref(needed)
        )
        if rc not in (_c.OK, _c.ERR_BUFFER_TOO_SMALL):
            _check(rc)
        if needed.value == 0:
            return b""
        buffer = (ctypes.c_uint8 * needed.value)()
        copied = ctypes.c_size_t()
        _check(
            _driver.pancake_driver_listener_restoration_state(
                self._h,
                listener,
                ctypes.cast(buffer, ctypes.c_void_p),
                needed.value,
                ctypes.byref(copied),
            )
        )
        if copied.value != needed.value:
            raise PancakeError(
                _c.ERR_INTERNAL,
                "driver listener restoration state changed during copy",
            )
        return bytes(buffer)

    def advertise_listener(
        self, listener: Union[int, "ListenerOwner"], locator: Union[Locator, str]
    ) -> None:
        """Replace this listener's advertised locator through its native owner."""
        listener = self._listener_id(listener)
        parsed = parse_locator(locator) if isinstance(locator, str) else locator
        with _OwnedLocator.create(parsed) as owned:
            _check(
                _driver.pancake_driver_listener_advertise(
                    self._h, listener, owned.borrow_view()
                )
            )

    def select_listener(self, listener: Union[int, "ListenerOwner"]) -> None:
        """Select this listener's locator as the Host's acceptable location."""
        _check(
            _driver.pancake_driver_listener_select(self._h, self._listener_id(listener))
        )

    def close_listener(self, listener: Union[int, "ListenerOwner"]) -> None:
        """Stop one listener after preserving already committed accepts."""
        listener = self._listener_id(listener)
        # A terminal setup event may already be queued while the caller is
        # cancelling its waiter. Consume it before asking native code to
        # cancel; a failed setup has already retired its native identity.
        self._dispatch_many(self._pop_events())
        owner = self._listeners.get(listener)
        if owner is None:
            return
        _check(_driver.pancake_driver_listener_close(self._h, listener))
        owner._closed = True
        try:
            self._dispatch_many(self._pop_events())
        finally:
            self._finish_listener_close(listener)

    def _finish_listener_close(
        self, listener: int, failure: Optional[PancakeError] = None
    ) -> None:
        """Retire every binding-owned row for one terminal listener."""
        owner = self._listeners.pop(listener, None)
        if owner is not None:
            if failure is not None:
                owner._mark_failed(failure)
            else:
                owner._closed = True
        waiter = self._listener_waiters.pop(listener, None)
        if waiter is not None and not waiter.done():
            if failure is not None:
                waiter.set_exception(failure)
            else:
                waiter.cancel()
        accepts = self._accepts.get(listener)
        if accepts is not None:
            self._release_unclaimed(listener)
            accepts.put_nowait(failure if failure is not None else _ACCEPTS_CLOSED)
            del self._accepts[listener]

    async def wait_listener(
        self, listener: Union[int, "ListenerOwner"]
    ) -> "ListenerOwner":
        """Await provider construction and return the stable listener owner.

        ``listen`` has already returned the identity before setup runs. This
        boundary is the only place high-level async constructors wait for the
        provider's READY/FAILED outcome.
        """
        aio = self._started_loop()
        owner = (
            listener
            if isinstance(listener, ListenerOwner)
            else self._listeners.get(listener)
        )
        if owner is None:
            raise PancakeError(_c.ERR_CLOSED, "the listener is closed")
        if owner.failure is not None:
            raise owner.failure
        if owner.ready:
            return owner
        if owner._closed:
            raise PancakeError(_c.ERR_CLOSED, "the listener is closed")
        waiter = self._listener_waiters.get(owner.listener)
        if waiter is None:
            waiter = aio.create_future()
            self._listener_waiters[owner.listener] = waiter
        self.schedule_step()
        self._rearm_progress_timer()
        try:
            await waiter
        except asyncio.CancelledError:
            self.close_listener(owner)
            raise
        if owner.failure is not None:
            raise owner.failure
        if not owner.ready:
            raise PancakeError(
                _c.ERR_INTERNAL,
                "listener became ready without a READY event",
            )
        return owner

    def _release_unclaimed(self, listener: int) -> None:
        accepts = self._accepts.get(listener)
        if accepts is None:
            return
        while True:
            try:
                item = accepts.get_nowait()
            except asyncio.QueueEmpty:
                return
            if isinstance(item, int):
                self._native_session_release(ctypes.c_void_p(item))

    # ── Vows ─────────────────────────────────────────────────────────────────

    def completion(self, vow: int) -> "asyncio.Future[bool]":
        """A future settled by the vow's COMPLETION event (True on SETTLE;
        FAIL raises). Register before the next step."""
        aio = self._started_loop()
        future: asyncio.Future[bool] = aio.create_future()
        if self._terminal_failure is not None:
            future.set_exception(self._terminal_failure)
            return future
        self._completions[vow] = future
        return future

    async def accept_session(self, listener: Union[int, "ListenerOwner"]):
        """Await the next accepted session, wrapped as the public
        :class:`pancake.Session` over the adopted wrapper Host — the
        accept-side twin of :meth:`connect_session`. The handshake already
        ran inside the accepting step; the session arrives open."""
        ptr = await self.accept(self._listener_id(listener))
        return self.adopt_session(ptr)


class _LoopTransport:
    """The loop-backed :class:`pancake.Session` transport duck: no byte verbs
    (the native loop owns the wire), one closed event the serve task and
    ``wait_closed`` share, and the back-reference `Session`'s branched arms
    dispatch on. Constructed on the asyncio thread that drives the loop."""

    def __init__(self, driver_loop: DriverLoop, ptr: int) -> None:
        self._driver_loop = driver_loop
        self._ptr = ptr
        self._closed = asyncio.Event()
        self._failure: "Optional[PancakeError]" = None

    def mark_closed(self) -> None:
        self._closed.set()

    def close(self) -> None:
        self._closed.set()

    def mark_failed(self, error: PancakeError) -> None:
        self._failure = error
        self._closed.set()

    async def wait_closed(self) -> None:
        await self._closed.wait()
        if self._failure is not None:
            raise self._failure


async def dial_shared_loop(
    driver_loop: "DriverLoop",
    locator: Locator,
):
    """Begin one dial through an already-composed provider package."""
    return await driver_loop.connect_session(locator)
