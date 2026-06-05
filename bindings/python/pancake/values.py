"""Typed CapTP value marshalling across the C ABI.

Mirrors the tagged-union shapes in ``crates/ffi/pancake-ffi-runtime/include/
pancake.h``:

* ``PancakeReference`` — ``{u32 kind, u32 pad, payload[32]}``
* ``PancakeArgument``  — ``{u32 kind, u32 pad, payload[40]}``
* ``PancakeResolution``— ``{u32 kind, u32 pad, payload[48]}``

The payload is a fixed-size byte buffer sized for the largest variant on
LP64; variant data is written / read at offset 8 via explicit offsets (the
same discipline the proven Racket binding uses). ``Far`` / ``Sturdy``
payloads are ``{ptr, len, u64}`` triples.

Send side: build a Python :class:`Reference` / :class:`Argument` /
:class:`Resolution`, then ``marshal_*`` projects it into a ctypes struct,
copying every leaf into a caller-owned buffer kept alive in a ``keepalive``
list for the duration of the FFI call (pancake copies-on-push, so the
buffers may be released once the call returns).

Receive side: ``project_*`` reads the bytes pancake wrote into out-params.
The caller is responsible for invoking the matching ``pancake_typed_*_free``
after projecting (the Rust side owns those allocations) — :mod:`pancake.host`
wires that up.
"""

from __future__ import annotations

import ctypes
from ctypes import (
    addressof,
    c_char_p,
    c_int64,
    c_size_t,
    c_uint8,
    c_uint32,
    c_uint64,
    c_void_p,
    memmove,
    sizeof,
    string_at,
)
from dataclasses import dataclass
from typing import Any, List, Optional, Tuple

from .constants import (
    PANCAKE_ARG_BOOL,
    PANCAKE_ARG_BYTES,
    PANCAKE_ARG_INTEGER,
    PANCAKE_ARG_LIST,
    PANCAKE_ARG_REFERENCE,
    PANCAKE_ARG_STRING,
    PANCAKE_ARG_SYMBOL,
    PANCAKE_ARG_VOID,
    PANCAKE_REF_BROKEN,
    PANCAKE_REF_FAR,
    PANCAKE_REF_NEAR,
    PANCAKE_REF_PROMISE,
    PANCAKE_REF_STURDY,
    PANCAKE_RES_BREAK,
    PANCAKE_RES_FULFILL,
)

# ─── ctypes struct mirrors ────────────────────────────────────────────────

PANCAKE_REFERENCE_PAYLOAD_SIZE = 32
PANCAKE_ARGUMENT_PAYLOAD_SIZE = 40
PANCAKE_RESOLUTION_PAYLOAD_SIZE = 48

_PAYLOAD_OFFSET = 8  # kind (u32) + pad (u32)


class PancakeReference(ctypes.Structure):
    _fields_ = [
        ("kind", c_uint32),
        ("_pad", c_uint32),
        ("payload", c_uint8 * PANCAKE_REFERENCE_PAYLOAD_SIZE),
    ]


class PancakeArgument(ctypes.Structure):
    _fields_ = [
        ("kind", c_uint32),
        ("_pad", c_uint32),
        ("payload", c_uint8 * PANCAKE_ARGUMENT_PAYLOAD_SIZE),
    ]


class PancakeResolution(ctypes.Structure):
    _fields_ = [
        ("kind", c_uint32),
        ("_pad", c_uint32),
        ("payload", c_uint8 * PANCAKE_RESOLUTION_PAYLOAD_SIZE),
    ]


class PancakeStepOutcome(ctypes.Structure):
    _fields_ = [
        ("kind", c_uint32),
        ("next_deadline_ms", c_uint64),
    ]


class PancakeOcapnUri(ctypes.Structure):
    _fields_ = [
        ("transport_cstr", c_char_p),
        ("designator_cstr", c_char_p),
        ("swissnum_bytes", c_void_p),
        ("swissnum_len", c_size_t),
    ]


# ─── Python-side projections ──────────────────────────────────────────────


@dataclass
class Reference:
    """A typed CapTP reference.

    Payload by kind:

    * ``PANCAKE_REF_NEAR``    → ``export_id`` (int)
    * ``PANCAKE_REF_FAR``     → ``(peer_id_bytes, import_id)``
    * ``PANCAKE_REF_PROMISE`` → ``(answer_id, pipeline_path_len)`` (receive-only)
    * ``PANCAKE_REF_STURDY``  → ``(peer_id_bytes_or_None, swissnum_bytes)``
    * ``PANCAKE_REF_BROKEN``  → ``reason`` (str) (receive-only)
    """

    kind: int
    payload: Any


@dataclass
class Argument:
    """A typed positional argument.

    Payload by kind: symbol→str, bytes→bytes, reference→:class:`Reference`,
    integer→int, bool→bool, string→str, void→None, list→``List[Argument]``.
    """

    kind: int
    payload: Any


@dataclass
class Resolution:
    """A typed CapTP resolution.

    Payload by kind: fulfill→:class:`Argument`, break→str.
    """

    kind: int
    payload: Any


# Reference constructors.
def ref_near(export_id: int) -> Reference:
    return Reference(PANCAKE_REF_NEAR, int(export_id))


def ref_far(peer_id_bytes: bytes, import_id: int) -> Reference:
    if not isinstance(peer_id_bytes, (bytes, bytearray)) or len(peer_id_bytes) != 32:
        raise ValueError(f"peer_id_bytes must be exactly 32 bytes; got {peer_id_bytes!r}")
    return Reference(PANCAKE_REF_FAR, (bytes(peer_id_bytes), int(import_id)))


def ref_sturdy(peer_id_bytes: Optional[bytes], swissnum_bytes: bytes) -> Reference:
    return Reference(PANCAKE_REF_STURDY, (peer_id_bytes, bytes(swissnum_bytes)))


# Argument constructors.
def arg_symbol(s: str) -> Argument:
    return Argument(PANCAKE_ARG_SYMBOL, s)


def arg_bytes(b: bytes) -> Argument:
    return Argument(PANCAKE_ARG_BYTES, bytes(b))


def arg_reference(r: Reference) -> Argument:
    return Argument(PANCAKE_ARG_REFERENCE, r)


def arg_integer(i: int) -> Argument:
    return Argument(PANCAKE_ARG_INTEGER, int(i))


def arg_bool(b: bool) -> Argument:
    return Argument(PANCAKE_ARG_BOOL, bool(b))


def arg_string(s: str) -> Argument:
    return Argument(PANCAKE_ARG_STRING, s)


def arg_void() -> Argument:
    return Argument(PANCAKE_ARG_VOID, None)


def arg_list(items: List[Argument]) -> Argument:
    return Argument(PANCAKE_ARG_LIST, list(items))


# Resolution constructors.
def res_fulfill(arg: Argument) -> Resolution:
    return Resolution(PANCAKE_RES_FULFILL, arg)


def res_break(reason: str) -> Resolution:
    return Resolution(PANCAKE_RES_BREAK, reason)


# ─── Low-level write helpers ──────────────────────────────────────────────


def _set(struct: ctypes.Structure, offset: int, ctype, value) -> None:
    ctype.from_buffer(struct, offset).value = value


def _keep_bytes(keepalive: list, data: Optional[bytes]) -> int:
    """Copy ``data`` into a kept-alive buffer; return its address (0 if empty)."""
    if not data:
        return 0
    buf = (c_uint8 * len(data)).from_buffer_copy(bytes(data))
    keepalive.append(buf)
    return addressof(buf)


# ─── Send-side marshalling (Python → ctypes struct) ──────────────────────


def marshal_reference(ref: Reference, keepalive: list) -> PancakeReference:
    s = PancakeReference()
    s.kind = ref.kind
    s._pad = 0
    base = _PAYLOAD_OFFSET
    if ref.kind == PANCAKE_REF_NEAR:
        _set(s, base, c_uint64, int(ref.payload))
    elif ref.kind == PANCAKE_REF_FAR:
        peer_id, import_id = ref.payload
        _set(s, base, c_void_p, _keep_bytes(keepalive, peer_id))
        _set(s, base + 8, c_size_t, len(peer_id))
        _set(s, base + 16, c_uint64, int(import_id))
    elif ref.kind == PANCAKE_REF_STURDY:
        peer_id, swissnum = ref.payload
        if peer_id and len(peer_id) == 32:
            _set(s, base, c_void_p, _keep_bytes(keepalive, peer_id))
            _set(s, base + 8, c_size_t, 32)
        else:
            _set(s, base, c_void_p, 0)
            _set(s, base + 8, c_size_t, 0)
        _set(s, base + 16, c_void_p, _keep_bytes(keepalive, swissnum))
        _set(s, base + 24, c_size_t, len(swissnum))
    else:
        raise ValueError(
            f"unsupported reference kind {ref.kind} on the send side "
            "(Promise / Broken are receive-only)"
        )
    return s


def marshal_argument(arg: Argument, keepalive: list) -> PancakeArgument:
    s = PancakeArgument()
    s.kind = arg.kind
    s._pad = 0
    base = _PAYLOAD_OFFSET
    if arg.kind in (PANCAKE_ARG_SYMBOL, PANCAKE_ARG_STRING):
        data = arg.payload.encode("utf-8")
        _set(s, base, c_void_p, _keep_bytes(keepalive, data))
        _set(s, base + 8, c_size_t, len(data))
    elif arg.kind == PANCAKE_ARG_BYTES:
        data = bytes(arg.payload)
        _set(s, base, c_void_p, _keep_bytes(keepalive, data))
        _set(s, base + 8, c_size_t, len(data))
    elif arg.kind == PANCAKE_ARG_REFERENCE:
        inner = marshal_reference(arg.payload, keepalive)
        keepalive.append(inner)
        memmove(addressof(s) + base, addressof(inner), sizeof(PancakeReference))
    elif arg.kind == PANCAKE_ARG_INTEGER:
        _set(s, base, c_int64, int(arg.payload))
    elif arg.kind == PANCAKE_ARG_BOOL:
        _set(s, base, c_uint8, 1 if arg.payload else 0)
    elif arg.kind == PANCAKE_ARG_VOID:
        _set(s, base, c_uint64, 0)
    elif arg.kind == PANCAKE_ARG_LIST:
        arr, count = marshal_arguments(arg.payload, keepalive)
        _set(s, base, c_void_p, addressof(arr) if arr is not None else 0)
        _set(s, base + 8, c_size_t, count)
    else:
        raise ValueError(f"unsupported argument kind {arg.kind}")
    return s


def marshal_arguments(
    args: List[Argument], keepalive: list
) -> Tuple[Optional[ctypes.Array], int]:
    """Project a list of :class:`Argument` into a contiguous ctypes array.

    Returns ``(array_or_None, count)``. The array (and every leaf buffer) is
    kept alive in ``keepalive``.
    """
    n = len(args)
    if n == 0:
        return None, 0
    arr = (PancakeArgument * n)()
    item_size = sizeof(PancakeArgument)
    for i, a in enumerate(args):
        src = marshal_argument(a, keepalive)
        memmove(addressof(arr) + i * item_size, addressof(src), item_size)
    keepalive.append(arr)
    return arr, n


def marshal_resolution(res: Resolution, keepalive: list) -> PancakeResolution:
    s = PancakeResolution()
    s.kind = res.kind
    s._pad = 0
    base = _PAYLOAD_OFFSET
    if res.kind == PANCAKE_RES_FULFILL:
        inner = marshal_argument(res.payload, keepalive)
        keepalive.append(inner)
        memmove(addressof(s) + base, addressof(inner), sizeof(PancakeArgument))
    elif res.kind == PANCAKE_RES_BREAK:
        data = res.payload.encode("utf-8")
        _set(s, base, c_void_p, _keep_bytes(keepalive, data))
        _set(s, base + 8, c_size_t, len(data))
    else:
        raise ValueError(f"unsupported resolution kind {res.kind}")
    return s


# ─── Receive-side projection (ctypes struct / address → Python) ──────────


def _read_bytes(ptr: int, length: int) -> bytes:
    if not ptr or length == 0:
        return b""
    return string_at(ptr, length)


def project_reference_addr(addr: int) -> Reference:
    kind = c_uint32.from_address(addr).value
    p = addr + _PAYLOAD_OFFSET
    if kind == PANCAKE_REF_NEAR:
        return Reference(kind, c_uint64.from_address(p).value)
    if kind == PANCAKE_REF_FAR:
        peer_ptr = c_void_p.from_address(p).value or 0
        peer_len = c_size_t.from_address(p + 8).value
        import_id = c_uint64.from_address(p + 16).value
        return Reference(kind, (_read_bytes(peer_ptr, peer_len), import_id))
    if kind == PANCAKE_REF_PROMISE:
        answer_id = c_uint64.from_address(p).value
        path_len = c_size_t.from_address(p + 8).value
        return Reference(kind, (answer_id, path_len))
    if kind == PANCAKE_REF_STURDY:
        peer_ptr = c_void_p.from_address(p).value or 0
        peer_len = c_size_t.from_address(p + 8).value
        swiss_ptr = c_void_p.from_address(p + 16).value or 0
        swiss_len = c_size_t.from_address(p + 24).value
        peer = _read_bytes(peer_ptr, peer_len) if peer_len else None
        return Reference(kind, (peer, _read_bytes(swiss_ptr, swiss_len)))
    if kind == PANCAKE_REF_BROKEN:
        reason_ptr = c_void_p.from_address(p).value or 0
        reason_len = c_size_t.from_address(p + 8).value
        return Reference(kind, _read_bytes(reason_ptr, reason_len).decode("utf-8", "replace"))
    raise ValueError(f"unknown reference kind {kind}")


def project_reference(struct: PancakeReference) -> Reference:
    return project_reference_addr(addressof(struct))


def project_argument_addr(addr: int) -> Argument:
    kind = c_uint32.from_address(addr).value
    p = addr + _PAYLOAD_OFFSET
    if kind in (PANCAKE_ARG_SYMBOL, PANCAKE_ARG_STRING):
        ptr = c_void_p.from_address(p).value or 0
        length = c_size_t.from_address(p + 8).value
        return Argument(kind, _read_bytes(ptr, length).decode("utf-8", "replace"))
    if kind == PANCAKE_ARG_BYTES:
        ptr = c_void_p.from_address(p).value or 0
        length = c_size_t.from_address(p + 8).value
        return Argument(kind, _read_bytes(ptr, length))
    if kind == PANCAKE_ARG_REFERENCE:
        return Argument(kind, project_reference_addr(p))
    if kind == PANCAKE_ARG_INTEGER:
        return Argument(kind, c_int64.from_address(p).value)
    if kind == PANCAKE_ARG_BOOL:
        return Argument(kind, c_uint8.from_address(p).value != 0)
    if kind == PANCAKE_ARG_VOID:
        return Argument(kind, None)
    if kind == PANCAKE_ARG_LIST:
        items_ptr = c_void_p.from_address(p).value or 0
        count = c_size_t.from_address(p + 8).value
        if not items_ptr or count == 0:
            return Argument(kind, [])
        item_size = sizeof(PancakeArgument)
        return Argument(
            kind,
            [project_argument_addr(items_ptr + i * item_size) for i in range(count)],
        )
    raise ValueError(f"unknown argument kind {kind}")


def project_argument(struct: PancakeArgument) -> Argument:
    return project_argument_addr(addressof(struct))


def project_resolution_addr(addr: int) -> Resolution:
    kind = c_uint32.from_address(addr).value
    p = addr + _PAYLOAD_OFFSET
    if kind == PANCAKE_RES_FULFILL:
        return Resolution(kind, project_argument_addr(p))
    if kind == PANCAKE_RES_BREAK:
        ptr = c_void_p.from_address(p).value or 0
        length = c_size_t.from_address(p + 8).value
        return Resolution(kind, _read_bytes(ptr, length).decode("utf-8", "replace"))
    raise ValueError(f"unknown resolution kind {kind}")


def project_resolution(struct: PancakeResolution) -> Resolution:
    return project_resolution_addr(addressof(struct))


# ─── Structural helper (for assertions / pretty-printing) ─────────────────


def to_native(arg: Argument):
    """Convert an :class:`Argument` tree to a tagged Python structure."""
    if arg.kind == PANCAKE_ARG_LIST:
        return ("list", [to_native(a) for a in arg.payload])
    if arg.kind == PANCAKE_ARG_STRING:
        return ("string", arg.payload)
    if arg.kind == PANCAKE_ARG_SYMBOL:
        return ("symbol", arg.payload)
    if arg.kind == PANCAKE_ARG_INTEGER:
        return ("integer", arg.payload)
    if arg.kind == PANCAKE_ARG_BOOL:
        return ("bool", arg.payload)
    if arg.kind == PANCAKE_ARG_BYTES:
        return ("bytes", arg.payload)
    if arg.kind == PANCAKE_ARG_VOID:
        return ("void",)
    if arg.kind == PANCAKE_ARG_REFERENCE:
        return ("reference", arg.payload)
    return ("unknown", arg.kind, arg.payload)
