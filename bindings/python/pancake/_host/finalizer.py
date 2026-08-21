"""Implicit Host release ownership that survives its Python wrapper."""

from __future__ import annotations

import atexit
import threading
from collections import deque
from typing import Callable, Optional

from .. import _constants as _abi
from .._errors import _host_error
from .._failure import FailureLayer, _record_runtime_failure
from .._ffi_host import _host
from .._lifecycle import _release_consumed
from .._trampoline import (
    _inside_turn,
    _unregister_behavior as _unregister_global_behavior,
)

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

    __slots__ = (
        "raw",
        "giftables",
        "displaced",
        "hosted",
        "context",
        "diagnostic_id",
    )

    def __init__(
        self, raw, giftables, displaced, hosted, context, diagnostic_id
    ) -> None:
        self.raw = raw
        self.giftables = giftables
        self.displaced = displaced
        self.hosted = hosted
        self.context = context
        self.diagnostic_id = diagnostic_id


def _release_finalizer_state(state: _HostFinalizerState, *, checked: bool) -> None:
    """Release one detached Host state, at most once."""
    raw = state.raw
    if not raw:
        return
    rc = _host.pancake_host_release(raw)
    if rc == _abi.OK:
        _retire_finalizer_state(state)
        return
    failure = _host_error(rc)
    # INVALID_ARGUMENT is the only pre-consumption refusal. Every other
    # status is a completed teardown outcome; retrying it would call through a
    # dangling Host pointer.
    if not _release_consumed(rc):
        if checked:
            raise failure
        if _inside_turn():
            _parked_releases().append(
                lambda: _release_finalizer_state(state, checked=False)
            )
        else:
            _defer_finalizer_state(state)
        return
    if not checked:
        _report_finalizer_release_failure(state, failure)
    _retire_finalizer_state(state)
    if checked:
        raise failure


def _report_finalizer_release_failure(
    state: _HostFinalizerState, failure: BaseException
) -> None:
    """Retain a consumed finalizer failure at the surviving diagnostic owner."""
    context = state.context
    if context is None:
        _record_runtime_failure(FailureLayer.BINDING, "host.finalizer.release", failure)
        return
    try:
        context._report_failure(
            layer=_abi.FAILURE_LAYER_BINDING,
            scope=_abi.FAILURE_SCOPE_HOST,
            scope_id=state.diagnostic_id,
            operation="host.finalizer.release",
            primary_name=type(failure).__name__,
            primary_result=getattr(failure, "code", _abi.ERR_INTERNAL),
            primary_message=str(failure),
        )
    except BaseException as recorder_error:
        _record_runtime_failure(FailureLayer.BINDING, "host.finalizer.release", failure)
        _record_runtime_failure(
            FailureLayer.BINDING,
            "host.finalizer.release.diagnostic",
            recorder_error,
        )


def _retire_finalizer_state(state: _HostFinalizerState) -> None:
    """Retire wrapper state after its driver already released the native Host."""
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


def _release_unpublished_host(raw, context) -> Optional[BaseException]:
    """Release construction-owned Host authority without orphaning its Context."""
    state = _HostFinalizerState(raw, {}, [], {}, context, 0)
    rc = _host.pancake_host_release(raw)
    if _release_consumed(rc):
        _retire_finalizer_state(state)
    else:
        # The failed construction has no wrapper that can retry. Transfer the
        # still-live Host and its allocation policy to the process retry owner.
        _defer_finalizer_state(state)
    return None if rc == _abi.OK else _host_error(rc)


def _drain_deferred_finalizer_states() -> None:
    """Retry one claimed Host and driver batch outside every native callback."""
    if _inside_turn():
        return
    with _deferred_finalizer_lock:
        batch = list(_deferred_finalizer_states)
        _deferred_finalizer_states.clear()
        _deferred_finalizer_ids.clear()
    for state in batch:
        _release_finalizer_state(state, checked=False)
    # Import only at the safe boundary: the driver leaf imports Host retirement
    # lazily after a consuming release, so module construction stays acyclic.
    from .._driver.finalizer import _drain_driver_finalizers

    _drain_driver_finalizers()


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
