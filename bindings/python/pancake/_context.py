"""Internal: the allocation :class:`Context`.

An allocation scope peers and netlayers can be created in, routing every
allocation through host-supplied callables (or the default allocator). Holds the
``CFUNCTYPE`` trampolines alive for as long as the library can call them.
Re-exported from the :mod:`pancake` package; import from there.
"""

from __future__ import annotations

from typing import Callable, Optional

import ctypes

from ._errors import _check
from ._ffi_ocapn import _AllocFn, _Allocator, _FreeFn, _lib

class Context:
    """An allocation scope. Peers and netlayers created *in* a context route
    every allocation through it. The context must outlive every handle created
    in it: release the handles first, then the context. Released on
    :meth:`close` / context exit / GC.

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

        def _alloc(_user_data, size, alignment):
            return alloc(size, alignment) or 0

        def _free(_user_data, ptr, size, alignment):
            free(ptr or 0, size, alignment)

        # Hold the CFUNCTYPE trampolines (and the Python callables they close
        # over) alive for as long as the context can call them.
        alloc_cb = _AllocFn(_alloc)
        free_cb = _FreeFn(_free)
        self._callbacks = (alloc_cb, free_cb, alloc, free)
        allocator = _Allocator(alloc_cb, free_cb, None)

        out = ctypes.c_void_p()
        _check(_lib.pancake_context_new_with_allocator(ctypes.byref(allocator), ctypes.byref(out)))
        self._raw = out
        return self

    def __enter__(self) -> "Context":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        # Release the context first — it frees its tables through the allocator
        # — then drop the callbacks the trampolines borrowed.
        if self._raw:
            _lib.pancake_context_release(self._raw)
            self._raw = None
        self._callbacks = ()

    def release(self) -> None:
        """Alias for :meth:`close`."""
        self.close()

    def __del__(self):
        self.close()
