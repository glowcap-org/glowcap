"""Internal driver-loop dialing owner."""

from __future__ import annotations

import asyncio
import ctypes
from typing import Union

from .._ffi_driver import _driver
from .._locator import _OwnedLocator, Locator, parse_locator

from .errors import _check
from .state import DriverLoopMixinBase


class _DialingMixin(DriverLoopMixinBase):
    _progress_timer: "asyncio.TimerHandle | None"

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
        if self._aio is None or self._released or self._terminal_failure is not None:
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
