"""Terminal native driver lease and its wrapper-completion obligation."""

from __future__ import annotations

import weakref
from dataclasses import dataclass
from typing import Callable, Optional

from .._driver_failure import _release
from .._ffi_driver import _driver
from .._lifecycle import _release_consumed
from .finalizer import (
    _defer_live_driver_release,
    _DriverFinalizerState,
    _release_driver_finalizer_state,
)


@dataclass(frozen=True)
class _ReleaseAttempt:
    """One release result, including whether native authority was consumed."""

    consumed: bool
    error: Optional[BaseException]


class _DriverReleaseOwner:
    """Own one raw driver until native release consumes it.

    A refusal transfers this owner and the live wrapper's completion callback
    to the process retry queue. The queue retains both until a later ordinary
    safe boundary consumes the native lease. GC is only the fallback entry.
    """

    def __init__(self, wrapper, handle: int, context=None) -> None:
        self._state = _DriverFinalizerState(handle, context)
        self._finalizer = weakref.finalize(
            wrapper, _release_driver_finalizer_state, self._state
        )
        self._completion: "Optional[Callable[[Optional[BaseException]], None]]" = (
            None
        )

    @property
    def context(self):
        return self._state.context

    def adopt_host_state(self, state) -> None:
        current = self._state.host_state
        if current is not None and current is not state:
            raise RuntimeError("driver release already owns a Host wrapper")
        self._state.host_state = state
        self._state.context = None

    def release(
        self,
        operation: str,
        completion: "Callable[[Optional[BaseException]], None]",
    ) -> _ReleaseAttempt:
        handle = self._state.handle
        if not handle:
            raise RuntimeError("driver release authority was already consumed")
        outcome = _release(_driver, handle, operation)
        consumed = _release_consumed(outcome.code)
        if consumed:
            self._state.handle = None
            self._finalizer.detach()
            completion(outcome.error)
            self._state.host_state = None
            self._state.context = None
        else:
            self._completion = completion
            _defer_live_driver_release(
                self._state, operation, self._finish_deferred_release
            )
        return _ReleaseAttempt(consumed, outcome.error)

    def _finish_deferred_release(self, error: Optional[BaseException]) -> None:
        """Finish the wrapper exactly once after a retry consumes the lease."""
        self._finalizer.detach()
        completion = self._completion
        self._completion = None
        if completion is None:
            raise RuntimeError("deferred driver release lost its completion owner")
        completion(error)
        self._state.host_state = None
        self._state.context = None
