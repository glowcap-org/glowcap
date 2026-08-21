"""Argument marshalling ownership checks."""

from __future__ import annotations

import ctypes

from pancake._abi_value import _arg_to_c
from pancake._ffi_ocapn import _byte_buf

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
