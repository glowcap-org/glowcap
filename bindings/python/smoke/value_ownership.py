"""Argument marshalling ownership checks."""

from __future__ import annotations

import array
import ctypes

from glowcap._abi_value import _arg_to_c
from glowcap._ffi_ocapn import _byte_buf

_PyBytes_AsString = ctypes.pythonapi.PyBytes_AsString
_PyBytes_AsString.argtypes = [ctypes.py_object]
_PyBytes_AsString.restype = ctypes.c_void_p


def _addr(ptr) -> int:
    return ctypes.cast(ptr, ctypes.c_void_p).value or 0


def run() -> None:
    payload = b"a\0bc"
    keep: list = []
    c_arg = _arg_to_c(payload, keep)
    assert _addr(c_arg.bytes) == _PyBytes_AsString(payload)
    assert ctypes.string_at(c_arg.bytes, c_arg.bytes_len) == payload
    _owner, ptr = _byte_buf(payload)
    assert _addr(ptr) == _PyBytes_AsString(payload)

    mutable = bytearray(b"owned")
    keep = []
    c_arg = _arg_to_c(mutable, keep)
    mutable[:] = b"muted"
    assert ctypes.string_at(c_arg.bytes, c_arg.bytes_len) == b"owned"

    words = array.array("q", [-(2**63), 0, 2**63 - 1])
    keep = []
    c_arg = _arg_to_c(words, keep)
    assert _addr(c_arg.bytes) == words.buffer_info()[0]
    assert c_arg.bytes_len == len(words) * 8
    borrowed = ctypes.cast(c_arg.bytes, ctypes.POINTER(ctypes.c_int64))
    assert [borrowed[i] for i in range(len(words))] == list(words)
    try:
        words.append(7)
    except BufferError:
        pass
    else:
        raise AssertionError("a borrowed integer array must refuse resize")
    keep.clear()
    words.append(7)
    assert words[-1] == 7

    empty = array.array("q")
    keep = []
    c_arg = _arg_to_c(empty, keep)
    assert _addr(c_arg.bytes) == 0 and c_arg.bytes_len == 0
    assert not keep
    empty.append(7)
