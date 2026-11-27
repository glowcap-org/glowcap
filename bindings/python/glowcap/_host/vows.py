"""Internal: Host vow rows and late-observation retention."""

from __future__ import annotations

import asyncio
from collections import OrderedDict

from .. import _constants as _abi
from .._errors import GlowcapError

_ERR_CLOSED = _abi.ERR_CLOSED

# Cap on stored outcomes whose vow is never awaited, so the store cannot grow
# without bound; the oldest un-awaited outcome is evicted at the cap.
_MAX_UNOBSERVED_OUTCOMES = _abi.BINDING_UNOBSERVED_OUTCOME_CAP

# A vow row's initial state: registered, not yet awaited and not yet settled.
_MINTED = object()


class _VowRow:
    """A host vow row, registered the instant the vow is minted."""

    __slots__ = ("state", "track_gc")

    def __init__(self, track_gc: bool = False):
        # One of three shapes, so "settled with a live waiter" cannot
        # exist: _MINTED (registered), an asyncio.Future (a parked waiter), or
        # an (ok, payload) tuple (a settled outcome).
        self.state = _MINTED
        self.track_gc = track_gc


class VowTable:
    """Host-owned vow rows, waiters, and bounded late outcomes."""

    __slots__ = ("_gc", "_rows", "_terminal_failure", "_unobserved")

    def __init__(self, gc):
        self._gc = gc
        self._rows: dict[int, _VowRow] = {}
        self._terminal_failure: GlowcapError | None = None
        self._unobserved: OrderedDict[int, None] = OrderedDict()

    def clear(self) -> None:
        for vow in tuple(self._unobserved):
            self.abandon(vow)
        self._rows.clear()

    def fail_all(self, error: GlowcapError) -> None:
        self._terminal_failure = error
        for vow in tuple(self._rows):
            self.settle(vow, False, error)

    def minted(self, vow: int, *, track_gc: bool = False) -> None:
        """Record a freshly minted vow so the drain can route its completion."""
        self._rows[vow] = _VowRow(track_gc)

    def abandon(self, vow: int) -> None:
        """Drop binding-side observation after the public wrapper dies."""
        row = self._rows.pop(vow, None)
        if row is None:
            return
        if isinstance(row.state, asyncio.Future):
            row.state.cancel()
        elif isinstance(row.state, tuple):
            self._unobserved.pop(vow, None)
            ok, payload = row.state
            if ok:
                self._gc.discard_argument(payload)

    def await_vow(self, vow: int) -> asyncio.Future:
        """Return a future for the vow's eventual outcome."""
        future = asyncio.get_running_loop().create_future()
        row = self._rows.get(vow)
        if row is None:
            if self._terminal_failure is not None:
                future.set_exception(self._terminal_failure)
                return future
            # Evicted (never awaited until past the cap) or never minted here.
            future.set_exception(GlowcapError(_ERR_CLOSED, "the vow's outcome is gone (unobserved past the cap)"))
            return future
        if not isinstance(row.state, tuple):
            # Minted or re-awaited: park (or replace) the waiter. Replacing a
            # prior future matches the previous overwrite.
            row.state = future
            return future
        del self._rows[vow]
        del self._unobserved[vow]
        ok, payload = row.state
        if ok:
            future.set_result(payload)
        else:
            future.set_exception(payload)
        return future

    def settle(self, vow: int, ok: bool, payload) -> None:
        # The drain's settle arms: fire the waiter, or record the outcome for a
        # late observation (bounded FIFO: an outcome nobody ever awaits is
        # evicted at the cap).
        row = self._rows.get(vow)
        if row is None:
            if ok:
                self._gc.discard_argument(payload)
            return
        if ok and row.track_gc:
            try:
                self._gc.track_argument(payload)
            except BaseException as failure:
                self._gc.discard_after_failure(payload, failure)
                raise
        previous = row.state
        if isinstance(previous, asyncio.Future):
            del self._rows[vow]
            if previous.done():
                if ok:
                    self._gc.discard_argument(payload)
            elif ok:
                previous.set_result(payload)
            else:
                previous.set_exception(payload)
            return
        row.state = (ok, payload)
        self._unobserved[vow] = None
        if len(self._unobserved) > _MAX_UNOBSERVED_OUTCOMES:
            oldest, _ = self._unobserved.popitem(last=False)
            self.abandon(oldest)
        if isinstance(previous, tuple) and previous[0]:
            self._gc.discard_argument(previous[1])
