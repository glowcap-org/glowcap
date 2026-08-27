"""Internal driver-loop lifecycle owner."""

from __future__ import annotations

import asyncio
import ctypes
from typing import TYPE_CHECKING, Optional

from .. import _constants as _c
from .._errors import PancakeError, _retain_terminal_failure
from .._ffi_driver import _driver
from .._lifecycle import PendingWork, _close_options, _lifecycle_closed

from .errors import _check
from .listeners import _ACCEPTS_CLOSED
from .state import DriverLoopMixinBase

if TYPE_CHECKING:
    from .._ffi_host import _CloseOptions


class _LifecycleMixin(DriverLoopMixinBase):
    _terminal_failure_count: int
    _closing: bool
    _close_task: "asyncio.Task[None] | None"
    _close_error: BaseException | None
    _progress_timer: "asyncio.TimerHandle | None"

    def _record_terminal_failure(self, error: BaseException) -> None:
        self._terminal_failure_count = _retain_terminal_failure(
            self._terminal_failures, self._terminal_failure_count, error
        )

    def _retire_wrapper(self) -> None:
        """Retire the adopted Host and claim its session cleanup outcomes."""
        wrapper = self._wrapper
        if wrapper is None:
            return
        wrapper._driver_did_release()
        for error in wrapper.terminal_failures:
            self._record_terminal_failure(error)

    def _retire_native_release(self, release_error: Optional[BaseException]) -> None:
        """Commit wrapper ownership after a consuming driver release."""
        self._released = True
        if release_error is not None:
            self._record_terminal_failure(release_error)
        try:
            self._retire_wrapper()
        except BaseException as wrapper_error:
            self._record_terminal_failure(wrapper_error)

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
                if _lifecycle_closed(state.value):
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
            release_attempt = self._release_owner.release(
                "driver-loop.close.release", self._retire_native_release
            )
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
            for listener_close_future in self._listener_close_waiters.values():
                if not listener_close_future.done():
                    listener_close_future.set_result(None)
            self._listener_close_waiters.clear()
            self._closing_listeners.clear()
            for close_future in self._session_closes.values():
                if not close_future.done():
                    close_future.set_exception(closed)
            self._session_closes.clear()
            self._unclaimed_sessions.clear()
            # Native release is the transfer's terminal boundary. Retire
            # wrapper-owned callbacks and its Context borrow only after every
            # native allocation has reached that allocator's free, then claim
            # physical session cleanup at this loop's close barrier.
            if release_attempt.error is not None:
                error = release_attempt.error
                if not release_attempt.consumed:
                    self._record_terminal_failure(error)
                self._close_error = error
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
