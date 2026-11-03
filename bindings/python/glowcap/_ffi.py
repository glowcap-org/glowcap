"""Lifetime primitives for blocking FFI handles.

``ctypes.CDLL`` releases the GIL around foreign calls.  A wrapper therefore
cannot free an FFI handle merely because Python assigned ``None`` to its
pointer: another thread may still be using that storage.  ``FfiHandle``
implements the C archives' shutdown, join, release contract once for every
blocking transport binding.
"""

from __future__ import annotations

import threading
import weakref
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from functools import partial
from typing import Generic, Protocol, Self, TypeVar

from ._failure import FailureLayer, _record_runtime_failure


def _release_finalized(label: str, release_once: Callable[[], None]) -> None:
    try:
        release_once()
    except BaseException as error:
        _record_runtime_failure(FailureLayer.BINDING, f"{label}.finalize", error)


def _release_retaining_parent(release: Callable[[object], None], raw: object, _keepalive: object) -> None:
    """Release a raw handle while its finalizer state retains the parent."""
    release(raw)


class FfiHandle:
    """Own one FFI handle across calls that may release the GIL.

    Closing first interrupts blocking operations, waits for every operation
    lease to return, and only then frees the handle.  The synchronous wait
    ensures ``close`` does not return while foreign code can still touch
    the storage it owns.
    """

    def __init__(
        self,
        raw: object,
        release: Callable[[object], None],
        shutdown: Callable[[object], None] | None = None,
        *,
        label: str = "ffi",
        keepalive: object | None = None,
    ) -> None:
        self._raw = raw
        self._release = release
        self._shutdown = shutdown
        self._label = label
        self._active = 0
        self._closing = False
        self._released = False
        self._terminal_failures: list[BaseException] = []
        self._condition = threading.Condition()
        release_once: Callable[[], None] = (
            partial(release, raw) if keepalive is None else partial(_release_retaining_parent, release, raw, keepalive)
        )
        self._finalizer = weakref.finalize(self, _release_finalized, label, release_once)

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

        This is the ownership-transfer operation for an FFI object whose
        new owner has already retained an independent reference.
        """
        self._retire(shutdown=False)

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        """Explicit retirement failures in operation order."""
        with self._condition:
            return tuple(self._terminal_failures)

    def _retire(self, *, shutdown: bool) -> None:
        with self._condition:
            if self._closing:
                while not self._released:
                    self._condition.wait()
                terminal_failures = tuple(self._terminal_failures)
                if terminal_failures:
                    raise terminal_failures[0]
                return
            self._closing = True
            raw = self._raw

        failures: list[BaseException] = []
        if shutdown and raw and self._shutdown is not None:
            try:
                self._shutdown(raw)
            except BaseException as error:
                failures.append(error)

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
            if not any(retained is error for retained in failures):
                failures.append(error)
        finally:
            with self._condition:
                self._terminal_failures.extend(failures)
                self._released = True
                self._condition.notify_all()

        if failures:
            raise failures[0]


class _Closable(Protocol):
    def close(self) -> None: ...


_Child = TypeVar("_Child", bound=_Closable)


class _FfiHandleOwner:
    """Shared diagnostics projection for wrappers owning ``self._ffi``."""

    _ffi: FfiHandle

    @property
    def terminal_failures(self) -> tuple[BaseException, ...]:
        return self._ffi.terminal_failures


class _ChildRetiringNetlayer(_FfiHandleOwner, Generic[_Child]):
    """A netlayer whose connections and listeners borrow its backend.

    A child registers through :meth:`_adopt` and leaves through :meth:`_forget`.
    A weak set lets each child retain the owner without an ownership cycle, and
    :meth:`release` retires every live child before the backend. Once release is
    requested no child is adopted, so a dial that races the release fails closed
    instead of outliving its backend. The subclass calls :meth:`_init_children`
    once ``self._ffi`` is set."""

    _children: weakref.WeakSet[_Child]
    _children_lock: threading.Lock
    _release_lock: threading.Lock
    _release_requested: bool

    def _init_children(self) -> None:
        self._children = weakref.WeakSet()
        self._children_lock = threading.Lock()
        self._release_lock = threading.Lock()
        self._release_requested = False

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        with self._release_lock:
            with self._children_lock:
                if self._release_requested:
                    children = []
                else:
                    self._release_requested = True
                    children = list(self._children)
            for child in children:
                child.close()
            self._ffi.close()

    def _adopt(self, child: _Child) -> bool:
        with self._children_lock:
            if self._release_requested:
                return False
            self._children.add(child)
            return True

    def _forget(self, child: _Child) -> None:
        with self._children_lock:
            self._children.discard(child)

    def _relinquish_provider_reference(self) -> None:
        """Transfer runtime lifetime to an already-retained provider lease."""
        with self._release_lock:
            with self._children_lock:
                if self._release_requested or self._children:
                    raise RuntimeError(f"{self._ffi._label} is not transferable")
                self._release_requested = True
            self._ffi.drop_reference()
