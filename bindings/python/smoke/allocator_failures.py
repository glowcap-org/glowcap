"""Python allocator callbacks retain failures without fabricating ownership."""

from __future__ import annotations

import ctypes

import pancake
from pancake import Context, PancakeError


def _callback_exceptions_are_contained() -> None:
    pancake.take_runtime_failures()
    alloc_error = RuntimeError("allocator refused")

    def fail_alloc(_size: int, _alignment: int) -> int:
        raise alloc_error

    try:
        Context.with_allocator(fail_alloc, lambda *_args: None)
    except PancakeError:
        pass
    else:
        raise AssertionError("null allocator result must refuse Context construction")
    failures = pancake.take_runtime_failures()
    assert len(failures) == 1, failures
    assert failures[0].operation == "context.allocator.alloc", failures
    assert failures[0].primary_message == str(alloc_error), failures

    live = {}
    free_error = RuntimeError("allocator free refused")

    def allocate(size: int, alignment: int) -> int:
        backing = (ctypes.c_uint8 * (size + alignment))()
        base = ctypes.addressof(backing)
        address = (base + alignment - 1) & ~(alignment - 1) if alignment > 1 else base
        live[address] = backing
        return address

    def fail_free(_address: int, _size: int, _alignment: int) -> None:
        raise free_error

    context = Context.with_allocator(allocate, fail_free)
    context.close()
    failures = pancake.take_runtime_failures()
    assert failures, "free callback exception disappeared"
    assert failures[0].operation == "context.allocator.free", failures
    assert failures[0].primary_message == str(free_error), failures
    assert live, "failed free fabricated successful ownership release"
