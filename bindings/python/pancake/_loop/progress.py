"""Internal driver-loop progress owner."""

from __future__ import annotations

import asyncio
import ctypes

from .. import _constants as _c
from .._errors import PancakeError, _vow_failure
from .._driver_failure import _driver_event_failure
from .._driver.transport import _LoopTransport
from .._carrier_failure import _decode as _decode_carrier
from .._driver_event import LoopEvent
from .._ffi_driver import _driver, _DriverEvent
from .._host_action_gen import HOST_ACTION_SETTLE, Fail, Settle, decode
from .._trampoline import _enter_deliver, _exit_deliver, _inside_turn

from .errors import _check
from .state import DriverLoopMixinBase


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


class _ProgressMixin(DriverLoopMixinBase):
    _aio: "asyncio.AbstractEventLoop | None"
    _fd: int | None
    _progress_timer: "asyncio.TimerHandle | None"
    _started: bool
    _stepping: bool

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
            if event.kind not in (
                _c.DRIVER_EVENT_OPENED,
                _c.DRIVER_EVENT_OPEN_FAILED,
                _c.DRIVER_EVENT_ACCEPTED,
                _c.DRIVER_EVENT_SESSION_CLOSED,
                _c.DRIVER_EVENT_COMPLETION,
                _c.DRIVER_EVENT_LISTENER_READY,
                _c.DRIVER_EVENT_LISTENER_FAILED,
            ):
                raise PancakeError(
                    _c.ERR_INTERNAL,
                    f"pancake ABI returned unknown loop event kind {event.kind}",
                )
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
                ).decode("utf-8", "replace")
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
                try:
                    decoded = decode(event.action)
                except BaseException as error:
                    raise PancakeError(
                        _c.ERR_INTERNAL,
                        f"pancake ABI returned an invalid completion action: {error}",
                    ) from error
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
                    carrier_failure=_decode_carrier(
                        event.carrier_phase,
                        event.carrier_detail_flags,
                        event.carrier_verification_flags,
                        event.carrier_peer_alert,
                        event.carrier_engine_code,
                    ),
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
                future.set_exception(_driver_event_failure(event, "dial"))
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
        else:
            raise PancakeError(
                _c.ERR_INTERNAL,
                f"pancake ABI returned unknown loop event kind {event.kind}",
            )
