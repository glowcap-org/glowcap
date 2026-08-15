"""Internal: the allocation :class:`Context`.

An allocation scope Hosts and netlayers can be created in, routing every
allocation through host-supplied callables (or the default allocator). Holds the
``CFUNCTYPE`` trampolines alive for as long as the library can call them.
Re-exported from the :mod:`pancake` package; import from there.
"""

from __future__ import annotations

from typing import Callable

import ctypes

from . import _constants as _abi
from ._errors import PancakeError, _check, last_error
from ._failure import (
    FailureEvent,
    FailureLayer,
    _layer,
    _record_runtime_failure,
    _scope,
)
from ._ffi_ocapn import (
    _AllocFn,
    _Allocator,
    _FailureEvent,
    _FailureReport,
    _FreeFn,
    _lib,
)


class Context:
    """An allocation scope. Hosts and netlayers created *in* a context route
    every allocation through it. :meth:`close` immediately refuses new handles
    and releases the native context after every existing handle family has
    finished with it. Released on :meth:`close` / context exit / GC.

    :meth:`Context.with_allocator` takes two callables backing the context:

        alloc(size: int, alignment: int) -> int     # address, or 0 on failure
        free(address: int, size: int, alignment: int) -> None

    The callables own the memory they hand out; the library calls them from any
    thread that touches a handle in the context, so they must be thread-safe.
    """

    def __init__(self):
        out = ctypes.c_void_p()
        _check(_lib.pancake_context_new(ctypes.byref(out)))
        self._raw = out
        self._handle_count = 0
        self._release_requested = False
        # No callbacks for the default-allocator path.
        self._callbacks: tuple = ()

    @classmethod
    def with_allocator(
        cls,
        alloc: "Callable[[int, int], int]",
        free: "Callable[[int, int, int], None]",
    ) -> "Context":
        """A context that routes every allocation through host callables.

        ``alloc(size, alignment)`` returns the address of a fresh block (or 0 on
        failure); ``free(ptr, size, alignment)`` releases one."""
        self = cls.__new__(cls)
        self._raw = None
        self._handle_count = 0
        self._release_requested = False

        def _alloc(_user_data, size, alignment):
            try:
                return alloc(size, alignment) or 0
            except BaseException as error:
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    "context.allocator.alloc",
                    error,
                )
                return 0

        def _free(_user_data, ptr, size, alignment):
            try:
                free(ptr or 0, size, alignment)
            except BaseException as error:
                # The callback cannot return a failure through C. Keep the
                # process alive and retain the exact callerless fact; the
                # allocation may leak, but ownership is never fabricated.
                _record_runtime_failure(
                    FailureLayer.BINDING,
                    "context.allocator.free",
                    error,
                )

        # Hold the CFUNCTYPE trampolines (and the Python callables they close
        # over) alive for as long as the context can call them.
        alloc_cb = _AllocFn(_alloc)
        free_cb = _FreeFn(_free)
        self._callbacks = (alloc_cb, free_cb, alloc, free)
        allocator = _Allocator(alloc_cb, free_cb, None)

        out = ctypes.c_void_p()
        _check(
            _lib.pancake_context_new_with_allocator(
                ctypes.byref(allocator), ctypes.byref(out)
            )
        )
        self._raw = out
        return self

    def __enter__(self) -> "Context":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._release_requested:
            return
        self._release_requested = True
        if self._handle_count == 0:
            self._release_now()

    def next_failure(self) -> FailureEvent | None:
        """Atomically claim the oldest unreturnable failure in this context.

        Returned exceptions, callback replies, and close-barrier failures do
        not also appear here. A claimed event cannot reappear.
        """
        if not self._raw:
            raise RuntimeError("pancake Context is released")
        event = _FailureEvent()
        required = ctypes.c_size_t()
        payload = None
        while True:
            capacity = 0 if payload is None else ctypes.sizeof(payload)
            pointer = None if payload is None else payload
            rc = _lib.pancake_context_next_failure(
                self._raw,
                ctypes.byref(event),
                pointer,
                capacity,
                ctypes.byref(required),
            )
            if rc == _abi.WOULD_BLOCK:
                return None
            if rc == _abi.ERR_BUFFER_TOO_SMALL:
                payload = ctypes.create_string_buffer(required.value)
                continue
            if rc != _abi.OK:
                raise PancakeError(rc, last_error())
            break

        def text(pointer: int | None, length: int) -> str:
            if not pointer or length == 0:
                return ""
            return ctypes.string_at(pointer, length).decode(errors="replace")

        return FailureEvent(
            sequence=event.sequence,
            dropped_before=event.dropped_before,
            layer=_layer(event.layer),
            scope=_scope(event.scope_kind),
            scope_id=event.scope_id,
            operation_id=event.operation_id,
            primary_result=event.primary_result,
            secondary_result=event.secondary_result,
            secondary_count=event.secondary_count,
            truncated_fields=event.flags,
            operation=text(event.operation, event.operation_len),
            primary_name=text(event.primary_name, event.primary_name_len),
            primary_message=text(event.primary_message, event.primary_message_len),
            secondary_name=text(event.secondary_name, event.secondary_name_len),
            secondary_message=text(
                event.secondary_message, event.secondary_message_len
            ),
        )

    def take_failures(self) -> tuple[FailureEvent, ...]:
        """Claim every unreturnable failure currently retained, in order."""
        failures = []
        while (failure := self.next_failure()) is not None:
            failures.append(failure)
        return tuple(failures)

    def _report_failure(
        self,
        *,
        layer: int,
        scope: int,
        operation: str,
        primary_name: str,
        primary_result: int,
        primary_message: str = "",
        scope_id: int = 0,
        operation_id: int = 0,
        secondary_result: int = 0,
        secondary_name: str = "",
        secondary_message: str = "",
        secondary_count: int = 0,
    ) -> None:
        """Record a callerless failure from a binding-owned callback seam."""
        if not self._raw:
            raise RuntimeError("pancake Context is released")

        def encoded(text: str):
            data = text.encode()
            buffer = ctypes.create_string_buffer(data or b"\0", len(data) or 1)
            return buffer, ctypes.cast(buffer, ctypes.c_void_p), len(data)

        operation_buf, operation_ptr, operation_len = encoded(operation)
        primary_name_buf, primary_name_ptr, primary_name_len = encoded(primary_name)
        primary_message_buf, primary_message_ptr, primary_message_len = encoded(
            primary_message
        )
        secondary_name_buf, secondary_name_ptr, secondary_name_len = encoded(
            secondary_name
        )
        secondary_message_buf, secondary_message_ptr, secondary_message_len = encoded(
            secondary_message
        )
        keepalive = (
            operation_buf,
            primary_name_buf,
            primary_message_buf,
            secondary_name_buf,
            secondary_message_buf,
        )
        report = _FailureReport(
            1,
            ctypes.sizeof(_FailureReport),
            layer,
            scope,
            scope_id,
            operation_id,
            primary_result,
            secondary_result,
            secondary_count,
            operation_ptr,
            operation_len,
            primary_name_ptr,
            primary_name_len,
            primary_message_ptr,
            primary_message_len,
            secondary_name_ptr,
            secondary_name_len,
            secondary_message_ptr,
            secondary_message_len,
        )
        _check(_lib.pancake_context_report_failure(self._raw, ctypes.byref(report)))
        # Make the synchronous borrow obvious to static readers.
        _ = keepalive

    def _acquire_handle(self):
        """Borrow the allocation policy for one native handle family."""
        if self._release_requested or not self._raw:
            raise RuntimeError("pancake Context is released")
        self._handle_count += 1
        return self._raw

    def _release_handle(self) -> None:
        """End one native handle family's borrow."""
        if self._handle_count == 0:
            raise RuntimeError("pancake Context ownership underflow")
        self._handle_count -= 1
        if self._handle_count == 0 and self._release_requested:
            self._release_now()

    def _release_now(self) -> None:
        # Release the context first — it frees its own storage through the
        # allocator — then drop the callback trampolines that policy borrowed.
        if self._raw:
            _lib.pancake_context_release(self._raw)
            self._raw = None
        self._callbacks = ()

    def release(self) -> None:
        """Alias for :meth:`close`."""
        self.close()

    def __del__(self):
        self.close()
