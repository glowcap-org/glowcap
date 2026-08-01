"""Internal: distributed GC (ADR-0063), opt-in and off by default. Owns the
Host-wide :class:`HostGc` state, fetch ``track_import`` / verb-head
``drain_gc`` choreography, and ``pancake_host_ref_release``. Session keeps
``with_gc`` as a thin opt-in; the Host owns the finalizer state. Binding spine
Pass 3b.
"""

from __future__ import annotations

import weakref
import ctypes
from typing import Callable, Optional, Protocol

from ._errors import _check_host
from ._codec import _ref_to_c
from ._ffi_host import _host

from ._value import Ref, _ref_from_id


class GcHandle(Protocol):
    """Host callbacks HostGc needs without importing Host."""

    @property
    def released(self) -> bool: ...

    @property
    def host_raw(self): ...

    def kick(self) -> None: ...

    def schedule_drain(self, run: Callable[[], None]) -> None: ...


class _HostGcHandle:
    """GcHandle over Host binding-internal seams."""

    __slots__ = ("_s",)

    def __init__(self, host) -> None:
        self._s = weakref.ref(host)

    @property
    def released(self) -> bool:
        host = self._s()
        return host is None or host.released

    @property
    def host_raw(self):
        host = self._s()
        return None if host is None else host.raw_or_none

    def kick(self) -> None:
        host = self._s()
        if host is not None:
            host.schedule_kick()

    def schedule_drain(self, run: Callable[[], None]) -> None:
        host = self._s()
        if host is not None:
            host.schedule_on_loop(run)


def bind_host(gc: "HostGc", host) -> None:
    """Bind HostGc to its Host through the narrow finalizer-safe seam."""
    gc.bind(_HostGcHandle(host))


class HostGc:
    """Host-wide finalizer registry and release queue.

    A fetched reference may be homed on a sibling session and may outlive the
    session through which it arrived, so this state follows Host authority.
    """

    def __init__(self) -> None:
        self.pending: list[int] = []
        self._h: Optional[GcHandle] = None

    def bind(self, h: GcHandle) -> None:
        """Bind the live Host once so track/drain can schedule progress."""
        self._h = h

    def track_import(self, ref: "Ref") -> "Ref":
        # Register a fetched capability for GC when enabled. The `Ref` holds a
        # node-unique token (ADR-0069) — only ids in the token range are
        # tracked — and the host resolves the token to its home connection and
        # real wire import when the release fires. The finalizer captures only
        # the bare token integer, never the `Ref`, so it cannot resurrect the
        # handle whose death it waits on.
        h = self._h
        if h is None:
            return ref
        prior = getattr(ref, "_gc_finalizer", None)
        if prior is not None:
            prior.detach()
        finalizer = weakref.finalize(ref, self._on_import_dropped, ref.id)
        object.__setattr__(ref, "_gc_finalizer", finalizer)
        return ref

    def disarm(self, ref: "Ref") -> None:
        """Disarm a tracked ref after deterministic release committed."""
        finalizer = getattr(ref, "_gc_finalizer", None)
        if finalizer is not None:
            finalizer.detach()

    def _on_import_dropped(self, token: int) -> None:
        # Runs when the last `Ref` is collected, possibly off the loop thread:
        # park the id and hop to the loop to drain it — ref_release never
        # runs from a finalizer thread.
        h = self._h
        if h is None:
            return
        self.pending.append(token)
        h.schedule_drain(self.drain_gc)

    def drain_gc(self) -> None:
        # Drain the parked GC releases on the loop thread: one release delta
        # per reclaimed token, then a kick so the op:gc-exports flushes.
        # Best-effort — a refused release strands a partner export reclaimed at
        # teardown, never a fault.
        h = self._h
        if h is None or not self.pending or h.released:
            return
        pending, self.pending = self.pending, []
        for token in pending:
            try:
                ref = _ref_to_c(_ref_from_id(token))
                _check_host(_host.pancake_host_ref_release(h.host_raw, ctypes.byref(ref), 1))
            except Exception:  # noqa: BLE001 — best-effort
                pass
        h.kick()


def release_ref(host_raw, ref: Ref) -> None:
    """Release one opaque Host capability deterministically."""
    c_ref = _ref_to_c(ref)
    _check_host(_host.pancake_host_ref_release(host_raw, ctypes.byref(c_ref), 1))
