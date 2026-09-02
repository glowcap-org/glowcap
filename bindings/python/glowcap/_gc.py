"""Internal: distributed GC (ADR-0063), opt-in and off by default. Owns the
Host-wide :class:`HostGc` state, recursive application-value tracking / verb-head
``drain_gc`` choreography, and ``glowcap_host_ref_release``. Session keeps
``with_gc`` as a thin opt-in; public vow lifetime uses the same Host-owned
finalizer scheduler but is mandatory.
"""

from __future__ import annotations

import weakref
import ctypes
import threading
from typing import Callable, Optional, Protocol

from ._errors import _check_host
from ._abi_value import _ref_to_c
from ._ffi_host import _host

from ._value import Argument, Ref, Set, Struct, Tagged, _ref_from_id


class GcHandle(Protocol):
    """Host callbacks HostGc needs without importing Host."""

    @property
    def released(self) -> bool: ...

    @property
    def host_raw(self): ...

    def kick(self) -> None: ...

    def schedule_drain(self, run: Callable[[], None]) -> None: ...

    def abandon_vow(self, vow: int) -> None: ...


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

    def abandon_vow(self, vow: int) -> None:
        host = self._s()
        if host is not None:
            host.abandon_vow(vow)


def bind_host(gc: "HostGc", host) -> None:
    """Bind HostGc to its Host through the narrow finalizer-safe seam."""
    gc.bind(_HostGcHandle(host))


class HostGc:
    """Host-wide finalizer registry and release queue.

    A projected reference may be homed on a sibling session and may outlive the
    session through which it arrived, so this state follows Host authority.
    """

    def __init__(self) -> None:
        self.pending: list[int] = []
        self.pending_vows: list[int] = []
        self._pending_vow_ids: set[int] = set()
        self._h: Optional[GcHandle] = None
        self._background_failure: Optional[BaseException] = None
        self._lock = threading.Lock()

    def bind(self, h: GcHandle) -> None:
        """Bind the live Host once so track/drain can schedule progress."""
        with self._lock:
            self._h = h

    def retire(self) -> None:
        """Retire queues whose native Host owner has been consumed."""
        with self._lock:
            self._h = None
            self.pending.clear()
            self.pending_vows.clear()
            self._pending_vow_ids.clear()
            self._background_failure = None

    def track_ref(self, ref: "Ref") -> "Ref":
        # Register one projected capability occurrence for GC. The id is an
        # opaque Host-scoped identity (ADR-0096) — the application projection
        # seam scopes tracking, never an id-range branch — and the host
        # resolves it to its home connection and real wire import when the
        # release fires. The finalizer captures only the bare id integer,
        # never the `Ref`, so it cannot resurrect the handle whose death it
        # waits on.
        with self._lock:
            h = self._h
        if h is None:
            return ref
        prior = getattr(ref, "_gc_finalizer", None)
        if prior is not None:
            prior.detach()
        finalizer = weakref.finalize(ref, self._on_capability_dropped, ref.id)
        object.__setattr__(ref, "_gc_finalizer", finalizer)
        return ref

    def track_argument(self, value: "Argument") -> "Argument":
        """Track every capability occurrence in a native-projected value.

        Containers stay intact; only ``Ref`` leaves receive finalizers. Native
        projection minted one Host retain per occurrence, so equal ids in two
        leaves intentionally receive two independent death rites.
        """
        if isinstance(value, Ref):
            return self.track_ref(value)
        if isinstance(value, (list, Set)):
            for item in value:
                self.track_argument(item)
        elif isinstance(value, Tagged):
            for item in value.value:
                self.track_argument(item)
        elif isinstance(value, Struct):
            for _, item in value.entries:
                self.track_argument(item)
        return value

    def track_arguments(self, values: "list[Argument]") -> "list[Argument]":
        for value in values:
            self.track_argument(value)
        return values

    def disarm(self, ref: "Ref") -> None:
        """Disarm a tracked ref after deterministic release committed."""
        finalizer = getattr(ref, "_gc_finalizer", None)
        if finalizer is not None:
            finalizer.detach()

    def _on_capability_dropped(self, token: int) -> None:
        # Runs when the last `Ref` is collected, possibly off the loop thread:
        # park the id and hop to the loop to drain it — ref_release never
        # runs from a finalizer thread.
        with self._lock:
            h = self._h
            if h is None:
                return
            self.pending.append(token)
        h.schedule_drain(self._drain_scheduled)

    def track_vow(self, handle, vow: int):
        """Release one native Host vow when its public wrapper dies."""
        weakref.finalize(handle, self._on_vow_dropped, vow)
        return handle

    def _on_vow_dropped(self, vow: int) -> None:
        self.park_vow(vow)

    def park_vow(self, vow: int) -> None:
        """Transfer one callerless vow release to the Host owner loop."""
        with self._lock:
            h = self._h
            if h is None:
                return
            if vow not in self._pending_vow_ids:
                self._pending_vow_ids.add(vow)
                self.pending_vows.append(vow)
        h.schedule_drain(self._drain_scheduled)

    def drain_gc(self) -> None:
        # Drain the parked GC releases on the loop thread: one release delta
        # per reclaimed token, then a kick so the op:gc-exports flushes. A
        # token leaves the queue only after its native release commits.
        with self._lock:
            failure = self._background_failure
            self._background_failure = None
            h = self._h
            if h is None or (not self.pending and not self.pending_vows) or h.released:
                refs: list[int] = []
                vows: list[int] = []
            else:
                refs = list(self.pending)
                vows = list(self.pending_vows)
        if failure is not None:
            raise failure
        if h is None or (not refs and not vows) or h.released:
            return
        refs_committed = 0
        vows_committed = 0
        try:
            # Bound this pass to the tokens present at entry. A finalizer may
            # append while the loop thread is draining; that work remains for
            # the already-coalesced next pass.
            for token in refs:
                ref = _ref_to_c(_ref_from_id(token))
                _check_host(
                    _host.glowcap_host_ref_release(h.host_raw, ctypes.byref(ref), 1)
                )
                refs_committed += 1
            for vow in vows:
                h.abandon_vow(vow)
                _check_host(_host.glowcap_host_vow_release(h.host_raw, vow))
                vows_committed += 1
        finally:
            with self._lock:
                del self.pending[:refs_committed]
                for index in range(vows_committed):
                    self._pending_vow_ids.discard(self.pending_vows[index])
                del self.pending_vows[:vows_committed]
        h.kick()

    def _drain_scheduled(self) -> None:
        """Run an unowned drain while retaining its first exact refusal."""
        try:
            self.drain_gc()
        except BaseException as failure:
            with self._lock:
                if self._h is not None and self._background_failure is None:
                    self._background_failure = failure


def release_ref(host_raw, ref: Ref) -> None:
    """Release one opaque Host capability deterministically."""
    c_ref = _ref_to_c(ref)
    _check_host(_host.glowcap_host_ref_release(host_raw, ctypes.byref(c_ref), 1))
