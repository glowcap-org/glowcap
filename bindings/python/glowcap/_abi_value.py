"""Internal: the ctypes ABI value and option projection.

Marshals the value vocabulary to and from the C ABI ``_Argument`` / ``_Reference``
structs: ``_arg_to_c`` / ``_args_to_c`` / ``_ref_to_c`` on the way out
(retaining each borrowed byte owner on a caller-supplied ``keepalive`` list for
the duration of the synchronous C call), ``_arg_from_c`` / ``_ref_from_c`` on
the way back.
This module does not encode or decode CapTP frames; Zig owns both wire codecs
and every protocol decision. Re-exported value types come from :mod:`glowcap`.
"""

from __future__ import annotations

import ctypes

from . import _constants as _abi
from ._errors import GlowcapError
from ._ffi_ocapn import _Argument, _Reference, _borrowed_byte_ptr
from ._value import Argument, ErrorValue, Keyword, Ref, Set, Struct, Symbol, Tagged, _ref_from_id

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_ERR_INTERNAL = _abi.ERR_INTERNAL
_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE

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
_ARG_STRUCT = _abi.ARG_STRUCT
_ARG_ERROR = _abi.ARG_ERROR
_FEATURE_FULL = _abi.FEATURE_FULL


def _codec_name(codec: int, source: str | None = None) -> str:
    if codec == _abi.CODEC_SYRUP:
        return "syrup"
    if codec == _abi.CODEC_CAPNP:
        return "capnp"
    if source is not None:
        raise RuntimeError(f"glowcap ABI returned unknown {source} codec {codec!r}")
    raise RuntimeError(f"glowcap ABI generated unknown default codec {codec!r}")


def _captp_version_name(version: int, source: str | None = None) -> str:
    if version == _abi.CAPTP_V1_0:
        return "v1_0"
    if version == _abi.CAPTP_NEXT:
        return "next"
    if source is not None:
        raise RuntimeError(
            f"glowcap ABI returned unknown {source} CapTP version {version!r}"
        )
    raise RuntimeError(
        f"glowcap ABI generated unknown default CapTP version {version!r}"
    )


def _feature_name(features: int):
    if features == _abi.FEATURE_FULL:
        return "full"
    if features == _abi.FEATURE_BASELINE:
        return "baseline"
    if features == _abi.FEATURE_MINIMUM:
        return "minimum"
    return features


_DEFAULT_CODEC = _codec_name(_abi.DEFAULT_CODEC)
_DEFAULT_CAPTP_VERSION = _captp_version_name(_abi.DEFAULT_CAPTP_VERSION)
_DEFAULT_FEATURES = _feature_name(_abi.DEFAULT_FEATURES)
_INTEROP_CODEC = _codec_name(_abi.INTEROP_CODEC)
_INTEROP_CAPTP_VERSION = _captp_version_name(_abi.INTEROP_CAPTP_VERSION)
_NATIVE_CODEC = _codec_name(_abi.NATIVE_CODEC)
_NATIVE_CAPTP_VERSION = _captp_version_name(_abi.NATIVE_CAPTP_VERSION)


def _captp_version_id(version: str) -> int:
    """The ``GLOWCAP_CAPTP_*`` id for a CapTP profile name (ADR-0003).
    ``v1_0`` is the interop floor a Goblins vat speaks; ``next`` is the
    glowcap-to-glowcap track ``Offer.native`` prefers with Cap'n Proto."""
    if version == "v1_0":
        return _abi.CAPTP_V1_0
    if version == "next":
        return _abi.CAPTP_NEXT
    raise ValueError(f'captp_version must be "v1_0" or "next", got {version!r}')


def _codec_id(codec: str) -> int:
    """The ``GLOWCAP_CODEC_*`` id for a codec name, the selector
    ``glowcap_host_new`` and the blocking transport connections take."""
    if codec == "syrup":
        return _abi.CODEC_SYRUP
    if codec == "capnp":
        return _abi.CODEC_CAPNP
    raise ValueError(f"unknown OCapN codec {codec!r}")


def _feature_mask(features) -> int:
    """The ``GLOWCAP_FEATURE_*`` bitmask for a Host feature offer."""
    if features == "full":
        return _abi.FEATURE_FULL
    if features == "baseline":
        return _abi.FEATURE_BASELINE
    if features == "minimum":
        return _abi.FEATURE_MINIMUM
    if isinstance(features, int) and not isinstance(features, bool):
        if features < 0 or features & ~_FEATURE_FULL:
            raise ValueError(f"unknown OCapN feature mask {features!r}")
        return features
    mask = 0
    for feature in features:
        if feature == "pipelining":
            mask |= _abi.FEATURE_PIPELINING
        elif feature == "handoff":
            mask |= _abi.FEATURE_HANDOFF
        elif feature == "wire_delta":
            mask |= _abi.FEATURE_WIRE_DELTA
        elif feature == "sturdyref":
            mask |= _abi.FEATURE_STURDYREF
        elif feature == "untag":
            mask |= _abi.FEATURE_UNTAG
        elif feature == "multi_location":
            mask |= _abi.FEATURE_MULTI_LOCATION
        else:
            raise ValueError(f"unknown OCapN feature {feature!r}")
    return mask


def _ref_to_c(ref: Ref) -> _Reference:
    return _Reference(ref._live().id)


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
    elif isinstance(value, ErrorValue):
        _set_bytes(a, _ARG_ERROR, value.message.encode(), keepalive)
    elif isinstance(value, str):
        _set_bytes(a, _ARG_STRING, value.encode(), keepalive)
    elif isinstance(value, (bytes, bytearray)):
        _set_bytes(a, _ARG_BYTES, bytes(value), keepalive)
    elif value is None:
        a.kind = _ARG_VOID
    elif isinstance(value, Ref):
        a.kind, a.reference = _ARG_REFERENCE, _ref_to_c(value)
    elif isinstance(value, Tagged):
        _set_bytes(a, _ARG_TAGGED, value.tag.encode(), keepalive)
        a.items, a.items_len = _args_to_c(list(value.value), keepalive)
    elif isinstance(value, Struct):
        a.kind = _ARG_STRUCT
        a.items, a.items_len = _struct_entries_to_c(value.entries, keepalive)
    elif isinstance(value, Set):  # before list
        a.kind = _ARG_SET
        a.items, a.items_len = _args_to_c(list(value), keepalive)
    elif isinstance(value, list):
        a.kind = _ARG_LIST
        a.items, a.items_len = _args_to_c(value, keepalive)
    else:
        raise GlowcapError(_ERR_UNSUPPORTED_VALUE, "unsupported argument value")
    return a


def _set_bytes(a: _Argument, kind: int, data: bytes, keepalive: list) -> None:
    owner, ptr = _borrowed_byte_ptr(data)
    keepalive.append(owner)
    a.kind = kind
    a.bytes = ptr
    a.bytes_len = len(data)


def _args_to_c(args: list, keepalive: list):
    n = len(args)
    if n == 0:
        return (None, 0)
    arr = (_Argument * n)()
    for i, value in enumerate(args):
        arr[i] = _arg_to_c(value, keepalive)
    keepalive.append(arr)
    return (arr, n)


def _struct_entries_to_c(entries: list[tuple[str, Argument]], keepalive: list):
    n = len(entries) * 2
    if n == 0:
        return (None, 0)
    arr = (_Argument * n)()
    for i, (key, value) in enumerate(entries):
        if not isinstance(key, str) or isinstance(key, (Symbol, Keyword)):
            raise GlowcapError(_ERR_UNSUPPORTED_VALUE, "Struct entries must be String/value pairs")
        key_arg = _Argument()
        _set_bytes(key_arg, _ARG_STRING, key.encode(), keepalive)
        arr[i * 2] = key_arg
        arr[i * 2 + 1] = _arg_to_c(value, keepalive)
    keepalive.append(arr)
    return (arr, n)


def _ref_from_c(r: _Reference) -> Ref:
    return _ref_from_id(r.id)


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
    if a.kind == _ARG_ERROR:
        return ErrorValue(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_REFERENCE:
        return _ref_from_c(a.reference)
    if a.kind == _ARG_LIST:
        return [_arg_from_c(a.items[i]) for i in range(a.items_len)]
    if a.kind == _ARG_SET:
        return Set(_arg_from_c(a.items[i]) for i in range(a.items_len))
    if a.kind == _ARG_TAGGED:
        return Tagged(
            _bytes_from_c(a).decode(errors="replace"),
            [_arg_from_c(a.items[i]) for i in range(a.items_len)],
        )
    if a.kind == _ARG_KEYWORD:
        return Keyword(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_VOID:
        return None
    if a.kind == _ARG_BIG_INTEGER:
        # Canonical decimal digits + sign flag back to a native int (ADR-0049).
        magnitude = int(_bytes_from_c(a))
        return -magnitude if a.boolean != 0 else magnitude
    if a.kind == _ARG_STRUCT:
        if a.items_len % 2:
            raise GlowcapError(_ERR_INTERNAL, "glowcap ABI returned an odd Struct item count")
        entries: list[tuple[str, Argument]] = []
        for i in range(0, a.items_len, 2):
            key_arg = a.items[i]
            if key_arg.kind != _ARG_STRING:
                raise GlowcapError(_ERR_INTERNAL, "glowcap ABI returned a non-String Struct key")
            key = _bytes_from_c(key_arg).decode(errors="replace")
            entries.append((key, _arg_from_c(a.items[i + 1])))
        return Struct(entries)
    raise GlowcapError(
        _ERR_INTERNAL,
        f"glowcap ABI returned unknown argument kind {a.kind}",
    )
