"""Surviving authority for implicit native driver retirement."""

from __future__ import annotations

import atexit
import ctypes
import threading
from typing import Callable, Optional

from .. import _constants as _c
from .._driver_failure import _release, _report_fields
from .._failure import FailureLayer, _record_runtime_failure
from .._ffi_driver import _driver
from .._lifecycle import _release_consumed


class _DriverFinalizerState:
    """Raw driver authority. Only a refused live release retains completion."""

    __slots__ = (
        "handle",
        "host_state",
        "context",
        "release_failure_reported",
        "operation",
        "completion",
    )

    def __init__(self, handle: int, context=None) -> None:
        self.handle: Optional[ctypes.c_void_p] = ctypes.c_void_p(handle)
        self.host_state = None
        self.context = context
        self.release_failure_reported = False
        self.operation = "driver-loop.finalize.release"
        self.completion: "Optional[Callable[[Optional[BaseException]], None]]" = None


_deferred_driver_finalizers: list[_DriverFinalizerState] = []
_deferred_driver_finalizers_lock = threading.Lock()


def _release_driver_finalizer_state(state: _DriverFinalizerState) -> None:
    handle = state.handle
    if not handle:
        return
    outcome = _release(_driver, handle, state.operation)
    rc = outcome.code
    if outcome.error is not None:
        if not state.release_failure_reported:
            state.release_failure_reported = True
            error = outcome.error
            try:
                if state.context is None:
                    raise RuntimeError("driver finalizer has no surviving Context")
                state.context._report_failure(
                    layer=_c.FAILURE_LAYER_BINDING,
                    scope=_c.FAILURE_SCOPE_CONTEXT,
                    **_report_fields(outcome, state.operation),
                )
            except BaseException as recorder_error:
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    state.operation,
                    error,
                )
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    f"{state.operation}.diagnostic",
                    recorder_error,
                )
        if not _release_consumed(rc):
            with _deferred_driver_finalizers_lock:
                if state.handle and state not in _deferred_driver_finalizers:
                    _deferred_driver_finalizers.append(state)
            return
    state.handle = None
    completion = state.completion
    state.completion = None
    if completion is not None:
        completion(outcome.error)
        return
    if state.host_state is not None:
        from .._host.finalizer import _retire_finalizer_state

        _retire_finalizer_state(state.host_state)
        state.host_state = None
    elif state.context is not None:
        state.context._release_handle()
    state.context = None


def _defer_live_driver_release(
    state: _DriverFinalizerState,
    operation: str,
    completion: "Callable[[Optional[BaseException]], None]",
) -> None:
    """Transfer a refused live-loop release to the process retry owner."""
    if not state.handle:
        raise RuntimeError("cannot defer a consumed driver release")
    if state.completion is not None:
        raise RuntimeError("driver release already has a completion owner")
    state.operation = operation
    state.completion = completion
    # The live loop retains the first refusal in its ordered terminal chain.
    # A later refusal is the same still-live lease, not a new occurrence.
    state.release_failure_reported = True
    with _deferred_driver_finalizers_lock:
        if state not in _deferred_driver_finalizers:
            _deferred_driver_finalizers.append(state)


def _drain_driver_finalizers() -> None:
    with _deferred_driver_finalizers_lock:
        pending = list(_deferred_driver_finalizers)
        _deferred_driver_finalizers.clear()
    for state in pending:
        _release_driver_finalizer_state(state)


def _pending_driver_finalizer_retry_count() -> int:
    """Internal test observability for the process driver retry owner."""
    with _deferred_driver_finalizers_lock:
        return len(_deferred_driver_finalizers)


atexit.register(_drain_driver_finalizers)
