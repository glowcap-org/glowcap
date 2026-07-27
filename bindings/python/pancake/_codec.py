"""Internal: the ctypes argument codec.

Marshals the value vocabulary to and from the C ABI ``_Argument`` / ``_Reference``
structs: ``_arg_to_c`` / ``_args_to_c`` / ``_ref_to_c`` on the way out (pinning
each backing buffer on a caller-supplied ``keepalive`` list for the duration of
the synchronous C call), ``_arg_from_c`` / ``_ref_from_c`` on the way back.
Re-exported from the :mod:`pancake` package; import from there.
"""

from __future__ import annotations

import ctypes

from . import _constants as _abi
from ._errors import PancakeError
from ._ffi_ocapn import _Argument, _Reference
from ._value import (
    Argument,
    Broken,
    Far,
    Keyword,
    Near,
    Promise,
    Reference,
    Set,
    Sturdy,
    Symbol,
    Tagged,
)

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE

_REF_NEAR, _REF_FAR, _REF_PROMISE, _REF_STURDY, _REF_BROKEN = (
    _abi.REF_NEAR,
    _abi.REF_FAR,
    _abi.REF_PROMISE,
    _abi.REF_STURDY,
    _abi.REF_BROKEN,
)
_REF_SUB_OBJECT, _REF_SUB_PROMISE = _abi.REF_SUB_OBJECT, _abi.REF_SUB_PROMISE

_ARG_INTEGER, _ARG_FLOAT64, _ARG_BOOLEAN, _ARG_BYTES = (
    _abi.ARG_INTEGER,
    _abi.ARG_FLOAT64,
    _abi.ARG_BOOLEAN,
    _abi.ARG_BYTES,
)
_ARG_STRING, _ARG_SYMBOL, _ARG_VOID, _ARG_REFERENCE, _ARG_LIST = (
    _abi.ARG_STRING,
    _abi.ARG_SYMBOL,
    _abi.ARG_VOID,
    _abi.ARG_REFERENCE,
    _abi.ARG_LIST,
)
_ARG_SET, _ARG_TAGGED, _ARG_KEYWORD = _abi.ARG_SET, _abi.ARG_TAGGED, _abi.ARG_KEYWORD
_ARG_BIG_INTEGER = _abi.ARG_BIG_INTEGER

def _codec_id(codec: str) -> int:
    """The ``PANCAKE_CODEC_*`` id for a codec name, the selector
    ``pancake_host_new`` and the blocking transport endpoints take."""
    if codec == "syrup":
        return _abi.CODEC_SYRUP
    if codec == "capnp":
        return _abi.CODEC_CAPNP
    raise ValueError(f"unknown OCapN codec {codec!r}")


def _ref_to_c(ref: Reference) -> _Reference:
    if isinstance(ref, Near):
        sub = _REF_SUB_PROMISE if ref.promise else _REF_SUB_OBJECT
        return _Reference(_REF_NEAR, sub, ref.id)
    if isinstance(ref, Far):
        sub = _REF_SUB_PROMISE if ref.promise else _REF_SUB_OBJECT
        return _Reference(_REF_FAR, sub, ref.id)
    if isinstance(ref, Promise):
        return _Reference(_REF_PROMISE, 0, ref.answer)
    raise PancakeError(_ERR_UNSUPPORTED_VALUE, "sturdy/broken ref not carried on send")


def _arg_to_c(value: Argument, keepalive: list) -> _Argument:
    a = _Argument()
    if isinstance(value, bool):  # before int; bool is an int subclass
        a.kind, a.boolean = _ARG_BOOLEAN, 1 if value else 0
    elif isinstance(value, int):
        # ctypes silently wraps an out-of-range int mod 2**64; OCapN integers are
        # bignums, so refuse anything the C ABI int64 cannot carry rather than
        # send a corrupted value.
        if not (-(2**63) <= value < 2**63):
            # Outside the C ABI int64: ARG_BIG_INTEGER carries the canonical
            # decimal digits in bytes/bytes_len and the sign in boolean (ADR-0049).
            _set_bytes(a, _ARG_BIG_INTEGER, str(abs(value)).encode(), keepalive)
            a.boolean = 1 if value < 0 else 0
        else:
            a.kind, a.integer = _ARG_INTEGER, value
    elif isinstance(value, float):
        a.kind, a.float64 = _ARG_FLOAT64, value
    elif isinstance(value, Symbol):  # before str
        _set_bytes(a, _ARG_SYMBOL, value.encode(), keepalive)
    elif isinstance(value, Keyword):  # before str
        _set_bytes(a, _ARG_KEYWORD, value.encode(), keepalive)
    elif isinstance(value, str):
        _set_bytes(a, _ARG_STRING, value.encode(), keepalive)
    elif isinstance(value, (bytes, bytearray)):
        _set_bytes(a, _ARG_BYTES, bytes(value), keepalive)
    elif value is None:
        a.kind = _ARG_VOID
    elif isinstance(value, (Near, Far, Promise, Sturdy, Broken)):
        a.kind, a.reference = _ARG_REFERENCE, _ref_to_c(value)
    elif isinstance(value, Tagged):
        _set_bytes(a, _ARG_TAGGED, value.tag.encode(), keepalive)
        a.items, a.items_len = _args_to_c(list(value.value), keepalive)
    elif isinstance(value, Set):  # before list
        a.kind = _ARG_SET
        a.items, a.items_len = _args_to_c(list(value), keepalive)
    elif isinstance(value, list):
        a.kind = _ARG_LIST
        a.items, a.items_len = _args_to_c(value, keepalive)
    else:
        raise PancakeError(_ERR_UNSUPPORTED_VALUE, "unsupported argument value")
    return a


def _set_bytes(a: _Argument, kind: int, data: bytes, keepalive: list) -> None:
    buf = ctypes.create_string_buffer(data, len(data))
    keepalive.append(buf)
    a.kind = kind
    a.bytes = ctypes.cast(buf, ctypes.c_void_p)
    a.bytes_len = len(data)


def _args_to_c(args: list, keepalive: list):
    n = len(args)
    arr = (_Argument * n)(*[_arg_to_c(v, keepalive) for v in args])
    keepalive.append(arr)
    return (arr if n else None, n)


def _ref_from_c(r: _Reference) -> Reference:
    promise = r.sub_kind == _REF_SUB_PROMISE
    if r.kind == _REF_NEAR:
        return Near(r.id, promise)
    if r.kind == _REF_FAR:
        return Far(r.id, promise)
    if r.kind == _REF_PROMISE:
        return Promise(r.id)
    if r.kind == _REF_STURDY:
        return Sturdy()
    return Broken()


def _bytes_from_c(a: _Argument) -> bytes:
    if not a.bytes or a.bytes_len == 0:
        return b""
    return ctypes.string_at(a.bytes, a.bytes_len)


def _arg_from_c(a: _Argument) -> Argument:
    if a.kind == _ARG_INTEGER:
        return a.integer
    if a.kind == _ARG_FLOAT64:
        return a.float64
    if a.kind == _ARG_BOOLEAN:
        return a.boolean != 0
    if a.kind == _ARG_BYTES:
        return _bytes_from_c(a)
    # Syrup strings/symbols are unchecked partner bytes; decode leniently so a
    # hostile non-UTF-8 payload surfaces as a value (matching Rust's
    # from_utf8_lossy and Deno's non-fatal TextDecoder) instead of crashing the
    # poll with UnicodeDecodeError.
    if a.kind == _ARG_STRING:
        return _bytes_from_c(a).decode(errors="replace")
    if a.kind == _ARG_SYMBOL:
        return Symbol(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_REFERENCE:
        return _ref_from_c(a.reference)
    if a.kind == _ARG_LIST:
        return [_arg_from_c(a.items[i]) for i in range(a.items_len)]
    if a.kind == _ARG_SET:
        return Set(_arg_from_c(a.items[i]) for i in range(a.items_len))
    if a.kind == _ARG_TAGGED:
        return Tagged(_bytes_from_c(a).decode(errors="replace"), [_arg_from_c(a.items[i]) for i in range(a.items_len)])
    if a.kind == _ARG_KEYWORD:
        return Keyword(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_VOID:
        return None
    if a.kind == _ARG_BIG_INTEGER:
        # Canonical decimal digits + sign flag back to a native int (ADR-0049).
        magnitude = int(_bytes_from_c(a))
        return -magnitude if a.boolean != 0 else magnitude
    raise PancakeError(_ERR_INVALID_ARGUMENT, "unrecognized arg kind")
