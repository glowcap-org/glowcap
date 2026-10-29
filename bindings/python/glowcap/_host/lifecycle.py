"""Internal Host adoption, failure retention, and terminal release."""

from __future__ import annotations

import asyncio
import ctypes
from typing import TYPE_CHECKING, Any, Optional, cast

from .. import _constants as _abi
from .. import _trace
from .._abi_value import _arg_to_c
from .._errors import (
    GlowcapError,
    _check_host,
    _host_last_error,
    _retain_terminal_failure,
)
from .._failure import FailureLayer, _record_runtime_failure
from .._ffi_host import _host
from .._ffi_ocapn import _byte_buf
from .._lifecycle import (
    PendingWork,
    _UNSET,
    _close_options,
    _lifecycle_closed,
    _monotonic_ms,
)
from .._trampoline import _inside_turn
from .finalizer import (
    _HostFinalizerState,
    _release_finalizer_state,
    _retire_finalizer_state,
)
from .state import HostMixinBase

if TYPE_CHECKING:
    from .._loop import DriverLoop
    from . import Host


_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


class _LifecycleMixin(HostMixinBase):
    _driver_loop: "Optional[DriverLoop]"
    _raw: Optional[ctypes.c_void_p]
    _release_started: bool
    _finalizer: Any
    _finalizer_state: Optional[_HostFinalizerState]
    _release_task: "Optional[asyncio.Task]"
    _loop: Optional[asyncio.AbstractEventLoop]

    def _adopt_driver_loop(self, loop: "DriverLoop") -> _HostFinalizerState:
        """Commit driver loop ownership after ``glowcap_driver_take_host``.

        The FFI call is the transaction boundary. This method only updates
        Python ownership after that call has returned success, so every failed
        adoption leaves the byte-fed Host and its finalizer untouched.
        """
        if self._driver_loop is not None or self._raw is None or self._release_started:
            raise GlowcapError(_ERR_INVALID_ARGUMENT, "host is not adoptable")
        assert self._finalizer is not None
        self._finalizer.detach()
        self._finalizer = None
        self._driver_loop = loop
        assert self._finalizer_state is not None
        return self._finalizer_state

    def _driver_did_release(self) -> None:
        """Finish Python ownership after the driver freed the FFI Host.

        Host transfer moves the FFI release authority into ``DriverLoop``,
        but the wrapper still owns callback registrations and the allocation
        context borrow. They must outlive ``glowcap_driver_release`` and then
        retire exactly once.
        """
        if self._raw is None:
            return
        self._release_started = True
        for session in list(self._sessions.values()):
            session._ffi_owner_did_release()
        self._sessions.clear()
        _trace._detach_host(self)
        self._gc.retire()
        self._raw = None
        self._driver_loop = None
        state = self._finalizer_state
        if state is not None:
            _retire_finalizer_state(state)
        self._publications.clear()
        self._displaced_publications.clear()
        self._hosted.clear()
        self._connectors.clear()
        self._vows.clear()
        self._behavior_entries.clear()

    def _track_session_retirement_failure(self, error: BaseException) -> None:
        """Retain a session cleanup consequence once Host/loop close owns it."""
        if self._release_started:
            self._record_terminal_failure(error)

    def take_failures(self):
        """Claim callerless failures retained by this Host's Context."""
        if self._context is None:
            return ()
        return self._context.take_failures()

    def _record_callerless_failure(self, operation: str, error: BaseException) -> None:
        """Retain a callback failure with no deterministic return recipient."""
        context = self._context
        if context is None:
            _record_runtime_failure(FailureLayer.APPLICATION_OBSERVER, operation, error)
            return
        result = getattr(error, "code", _abi.ERR_INTERNAL)
        if not isinstance(result, int):
            result = _abi.ERR_INTERNAL
        try:
            context._report_failure(
                layer=_abi.FAILURE_LAYER_APPLICATION_OBSERVER,
                scope=_abi.FAILURE_SCOPE_HOST,
                scope_id=self._diagnostic_id,
                operation=operation,
                primary_name=type(error).__name__,
                primary_result=result,
                primary_message=str(error),
            )
        except BaseException as recorder_error:
            # Recording is observational, but failure of the preferred owner is
            # not permission to lose either fact. The process queue survives a
            # dead/broken Context and uses the same bounded schema.
            _record_runtime_failure(FailureLayer.APPLICATION_OBSERVER, operation, error)
            _record_runtime_failure(
                FailureLayer.BINDING,
                f"{operation}.diagnostic",
                recorder_error,
            )

    def _driver_failed(self, error: GlowcapError) -> None:
        """Fail loop-projected waits before driver teardown clears them."""
        self._vows.fail_all(error)
        for session in tuple(self._sessions.values()):
            mark_failed = getattr(session.transport, "mark_failed", None)
            if mark_failed is not None:
                mark_failed(error)

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
        """Owned terminal failures in observation order."""
        return tuple(getattr(self, "_terminal_failures", ()))

    @property
    def terminal_failure_count(self) -> int:
        """Total distinct terminal occurrences, including bounded overflow."""
        return getattr(self, "_terminal_failure_count", 0)

    def _raise_terminal_failure(self) -> None:
        failures = self.terminal_failures
        if failures:
            raise failures[0]

    def _settle_resolver(self, resolver: int, value: Any) -> None:
        self._assert_owner()
        raw = self.raw_or_none
        if not raw:
            return  # a released host freed its resolver rows
        keep: list = []
        try:
            c_arg = _arg_to_c(value, keep)
        except Exception as error:  # noqa: BLE001 - marshalling failure breaks the answer
            self._break_resolver(resolver, str(error) or type(error).__name__)
            return
        if (
            _host.glowcap_host_resolver_fulfill(raw, resolver, ctypes.byref(c_arg))
            != _abi.OK
        ):
            self._break_resolver(
                resolver, _host_last_error() or "deferred settle refused"
            )
            return
        self.signal_close_activity()
        self.schedule_kick()

    def _break_resolver(self, resolver: int, message: str) -> None:
        self._assert_owner()
        raw = self.raw_or_none
        if not raw:
            return
        data = message.encode()
        _buf, ptr = _byte_buf(data)
        # The awaitable can finish after its calling session retired the answer.
        _check_host(_host.glowcap_host_resolver_abandon(raw, resolver, ptr, len(data)))
        self.signal_close_activity()
        self.schedule_kick()

    def _finish_release(self) -> None:
        if not self._raw:
            return
        # A loop-adopted host has no finalizer: the FFI handle belongs to
        # the DriverLoop, and `_begin_release` already refused this path.
        assert self._finalizer is not None and self._finalizer_state is not None
        finalizer = self._finalizer
        state = self._finalizer_state

        def release_host() -> None:
            try:
                _release_finalizer_state(state, checked=True)
            finally:
                # A teardown failure consumes the FFI Host. Only a
                # pre-commit INVALID_ARGUMENT refusal leaves state.raw live.
                if not state.raw:
                    finalizer.detach()
                    _trace._detach_host(self)
                    self._gc.retire()
                    self._raw = None
                    self._connectors.clear()
                    self._behavior_entries.clear()

        if _inside_turn():
            self.park_release(release_host)
        else:
            release_host()

    def arm_close_activity(self) -> None:
        """Arm the shared close-activity waiter. A close driver arms before it
        reads FFI progress (the lost-wakeup discipline): a state advance
        landing after the arm sets the event and wakes :meth:`wait_close_wake`,
        and one landing before it is visible to the progress read that
        follows. Wake-all: setting the event wakes every parked driver.
        Binding-internal."""
        self._close_activity.clear()

    def signal_close_activity(self) -> None:
        """Wake every parked close driver. Called after an FFI verb that can
        advance close-relevant state returns: a byte feed, a drained action
        batch, a resolver settle, a close call (escalation), or a session
        release. Over-signaling is harmless because the drivers re-check
        progress. A missed source is a hang. Binding-internal."""
        self._close_activity.set()

    def _close_wait_ms(self) -> int:
        """The longest a close driver may wait before re-polling progress:
        milliseconds to the nearest FFI FINISH grace deadline (the Host's
        own or any session's), or -1 when none is pending and only activity
        can advance terminal progress."""
        raw = self._raw
        if not raw:
            return 0
        out = ctypes.c_int64()
        _check_host(
            _host.glowcap_host_close_wait_ms(raw, _monotonic_ms(), ctypes.byref(out))
        )
        return out.value

    async def wait_close_wake(self) -> None:
        """Park a close driver until host activity or the nearest FFI
        FINISH grace deadline. With no finite deadline pending the driver
        parks on activity alone. The caller armed the activity event before
        its progress read. Binding-internal: :meth:`_drive_release` and the
        byte-fed session close drive wait through it."""
        wait_ms = self._close_wait_ms()
        if wait_ms < 0:
            await self._close_activity.wait()
            return
        try:
            await asyncio.wait_for(self._close_activity.wait(), wait_ms / 1_000)
        except TimeoutError:
            pass

    async def _drive_release(self) -> None:
        raw = self._raw
        if not raw:
            return
        timed_out = False
        while True:
            # Arm before anything else in the iteration (the lost-wakeup
            # discipline): an advance landing after this line wakes the wait
            # below, and one landing before it is visible to the progress read.
            self.arm_close_activity()
            await self.kick_actions()
            state = ctypes.c_uint32()
            rc = _host.glowcap_host_close_progress(
                raw, _monotonic_ms(), ctypes.byref(state)
            )
            if rc not in (_abi.OK, _abi.ERR_TIMEOUT):
                _check_host(rc)
            if rc == _abi.ERR_TIMEOUT and not timed_out:
                timed_out = True
                self._record_terminal_failure(
                    GlowcapError(
                        _abi.ERR_TIMEOUT, "finish close exhausted its grace period"
                    )
                )
            if _lifecycle_closed(state.value):
                break
            # A spent grace escalates inside the progress call and queues
            # teardown actions; drain them before parking. A drain that ran
            # work sets the armed event, so the wait below returns at once and
            # the loop re-checks instead of parking over undrained work.
            await self.kick_actions()
            await self.wait_close_wake()
        await self._join_action_drains()
        await self._join_session_writers()
        await self._join_behavior_tasks()
        self._vows.clear()
        self._finish_release()
        self._raise_terminal_failure()

    async def _drive_owned_release(self) -> None:
        """Drive byte-fed release and retain its exact terminal failure."""
        try:
            await self._drive_release()
        except BaseException as error:
            self._record_terminal_failure(error)
            raise

    def _start_release(self, options=None) -> "Optional[asyncio.Task]":
        """Forward close intent and retain the one effect-driving task."""
        if options is None:
            options = _close_options(PendingWork.CANCEL)
        raw = self._raw
        if raw is None:
            # The release already reached its terminal outcome. Hand back the
            # retained driver task so a repeated close observes that outcome,
            # re-raising a recorded timeout instead of silently succeeding
            # (ADR-0030: repeated close observes the existing barrier).
            return self._release_task
        _check_host(
            _host.glowcap_host_close(raw, ctypes.byref(options), _monotonic_ms())
        )
        # A repeated close escalates the pending-work policy while the close
        # driver may already be parked; wake it so it re-reads progress.
        self.signal_close_activity()
        task = self._release_task
        if task is not None:
            return task
        if self._release_started:
            return None
        self._release_started = True
        task = asyncio.get_running_loop().create_task(self._drive_owned_release())
        self._release_task = task
        return task

    async def close(
        self,
        pending: PendingWork = PendingWork.CANCEL,
        *,
        grace: object = _UNSET,
    ) -> None:
        """Close through the core-owned pending-work policy and completion barrier."""
        self._assert_owner()
        options = _close_options(pending, grace)
        driver_loop = self._driver_loop
        if driver_loop is not None:
            self._request_driver_release(driver_loop, options)
            try:
                await driver_loop.wait_closed()
            except BaseException as wait_error:
                self._record_terminal_failure(wait_error)
            for index, error in enumerate(driver_loop.terminal_failures):
                self._record_terminal_failure(error)
            await self._join_behavior_tasks()
            self._raise_terminal_failure()
            return
        task = self._start_release(options)
        if task is not None:
            await asyncio.shield(task)

    async def __aenter__(self) -> "Host":
        return cast("Host", self)

    async def __aexit__(self, *exc) -> None:
        await self.close()

    def _request_close(self) -> None:
        """Request callback-safe teardown for finalizers and internal owners."""
        driver_loop = self._driver_loop
        if driver_loop is not None:
            self._request_driver_release(
                driver_loop, _close_options(PendingWork.CANCEL)
            )
            return
        owner_loop = self._loop
        if (
            owner_loop is not None
            and self._on_owner_thread()
            and not owner_loop.is_running()
        ):
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                if owner_loop.is_closed():
                    if (
                        self._dial_tasks
                        or self._behavior_tasks
                        or self._action_drains
                        or self._session_writers
                    ):
                        raise GlowcapError(
                            _ERR_INVALID_ARGUMENT,
                            "host owner loop is closed with asynchronous work still active",
                        )
                    self._loop = None
                else:
                    owner_loop.run_until_complete(self.close())
                    return
        if self._schedule_cleanup(self._request_close):
            return
        if not self._on_owner_loop():
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "host close must run on its owning thread",
            )
        if self._loop is not None:
            self._assert_owner()
        self._start_release()

    def _request_driver_release(self, loop: "DriverLoop", options) -> None:
        """Make transferred driver ownership terminal, callback-safely."""
        if self._raw is None:
            return
        self._release_started = True
        loop.close(options)
