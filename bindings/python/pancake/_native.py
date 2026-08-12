"""Lifetime primitives for blocking native handles.

``ctypes.CDLL`` releases the GIL around foreign calls.  A wrapper therefore
cannot free a native handle merely because Python assigned ``None`` to its
pointer: another thread may still be using that storage.  ``NativeHandle``
implements the C archives' shutdown, join, release contract once for every
blocking transport binding.
"""

from __future__ import annotations

import threading
import weakref
from contextlib import contextmanager
from functools import partial
from typing import Callable, Iterator


def _release_retaining_parent(
    release: Callable[[object], None], raw: object, _keepalive: object
) -> None:
    """Release a raw handle while its finalizer state retains the parent."""
    release(raw)


class NativeHandle:
    """Own one native handle across calls that may release the GIL.

    Closing first interrupts blocking operations, waits for every operation
    lease to return, and only then frees the handle.  The synchronous wait is
    intentional: ``close`` does not return while foreign code can still touch
    the storage it owns.
    """

    def __init__(
        self,
        raw: object,
        release: Callable[[object], None],
        shutdown: Callable[[object], None] | None = None,
        *,
        label: str = "native",
        keepalive: object | None = None,
    ) -> None:
        self._raw = raw
        self._release = release
        self._shutdown = shutdown
        self._label = label
        self._active = 0
        self._closing = False
        self._released = False
        self._condition = threading.Condition()
        release_once: Callable[[], None] = (
            partial(release, raw)
            if keepalive is None
            else partial(_release_retaining_parent, release, raw, keepalive)
        )
        self._finalizer = weakref.finalize(self, release_once)

    @contextmanager
    def lease(self) -> Iterator[object]:
        with self._condition:
            if self._closing or not self._raw:
                raise RuntimeError(f"{self._label} handle is closed")
            raw = self._raw
            self._active += 1
        try:
            yield raw
        finally:
            with self._condition:
                self._active -= 1
                if self._active == 0:
                    self._condition.notify_all()

    @property
    def closed(self) -> bool:
        with self._condition:
            return self._closing

    def close(self) -> None:
        """Shut the resource down, then drop this handle's reference."""
        self._retire(shutdown=True)

    def drop_reference(self) -> None:
        """Drop this handle's reference without shutting the resource down.

        This is the ownership-transfer operation for a native object whose
        new owner has already retained an independent reference.
        """
        self._retire(shutdown=False)

    def _retire(self, *, shutdown: bool) -> None:
        with self._condition:
            if self._closing:
                while not self._released:
                    self._condition.wait()
                return
            self._closing = True
            raw = self._raw

        failure: BaseException | None = None
        if shutdown and raw and self._shutdown is not None:
            try:
                self._shutdown(raw)
            except BaseException as error:
                failure = error

        with self._condition:
            while self._active != 0:
                self._condition.wait()
            claimed = self._raw
            if claimed:
                self._finalizer.detach()
                self._raw = None

        try:
            if claimed:
                self._release(claimed)
        except BaseException as error:
            if failure is None:
                failure = error
        finally:
            with self._condition:
                self._released = True
                self._condition.notify_all()

        if failure is not None:
            raise failure
