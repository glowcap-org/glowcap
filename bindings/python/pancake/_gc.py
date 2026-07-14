"""Internal: distributed GC (ADR-0063), opt-in and off by default. Owns the
per-connection :class:`ConnGc` state, fetch ``track_import`` / verb-head
``drain_gc`` choreography, and ``pancake_host_gc_release``. Session keeps
``with_gc`` as a thin CapTP verb and binds a :class:`GcHandle` so this module
never reaches into Session underscore fields. Binding spine Pass 3b.
"""

from __future__ import annotations

import weakref
from typing import TYPE_CHECKING, Callable, Optional, Protocol

from ._errors import _check_host
from ._ffi_driver import _host
from ._locator import REDEEMED_TOKEN_BASE

if TYPE_CHECKING:
    from ._value import Ref


class GcHandle(Protocol):
    """Session callbacks ConnGc needs without importing Session."""

    @property
    def released(self) -> bool: ...

    @property
    def host_raw(self): ...

    def kick(self) -> None: ...

    def schedule_drain(self, run: Callable[[], None]) -> None: ...


class _SessionGcHandle:
    """GcHandle over Session binding-internal seams — keeps ConnGc free of
    Session underscore reach-ins."""

    __slots__ = ("_s",)

    def __init__(self, session) -> None:
        self._s = session

    @property
    def released(self) -> bool:
        return self._s.released

    @property
    def host_raw(self):
        return self._s.host.raw

    def kick(self) -> None:
        self._s.host.schedule_kick()

    def schedule_drain(self, run: Callable[[], None]) -> None:
        self._s.schedule_on_loop(run)


def bind_session(gc: "ConnGc", session) -> None:
    """Bind ConnGc to a Session through a GcHandle (never the Session itself)."""
    gc.bind(_SessionGcHandle(session))


class ConnGc:
    """Per-session GC state."""

    def __init__(self) -> None:
        self.enabled = False
        self.pending: list[int] = []
        self._h: Optional[GcHandle] = None

    def bind(self, h: GcHandle) -> None:
        """Bind the live Session once so track/drain can kick without Session
        wrappers."""
        self._h = h

    def enable(self) -> None:
        self.enabled = True

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
        wire = ref.far
        if self.enabled and wire is not None and wire.id >= REDEEMED_TOKEN_BASE:
            weakref.finalize(ref, self._on_import_dropped, wire.id)
        return ref

    def _on_import_dropped(self, token: int) -> None:
        # Runs when the last `Ref` is collected, possibly off the loop thread:
        # park the token and hop to the loop to drain it — gc_release never
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
                _check_host(_host.pancake_host_gc_release(h.host_raw, token, 1))
            except Exception:  # noqa: BLE001 — best-effort
                pass
        h.kick()
