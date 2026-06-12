"""Idiomatic Python API for ``libpancake`` — an OCapN/CapTP peer you drive.

The raw ``ctypes`` FFI is private to this module. What you use is a :class:`Peer`
(a context manager that releases itself), native Python values as arguments
(``int``/``float``/``bool``/``bytes``/``str``/``list``, plus :class:`Symbol` and
references), and typed :class:`Event` objects out of :meth:`Peer.poll`. The
default :class:`Peer` negotiates an authenticated session; raw direct-frame
fixtures use :meth:`Peer.raw_open`.

    with Peer.raw_open() as peer:
        peer.register_import(5)
        peer.send_deliver(Far(5), [42, b"hi"], answer=9)
        peer.step()
        frame = peer.take_outbound()
"""

from __future__ import annotations

import asyncio
import ctypes
import enum
import pathlib
import secrets
import sys
from dataclasses import dataclass, field
from typing import NamedTuple, Optional, Union

try:
    from . import _pancake_constants as _abi
except ImportError:  # imported as a loose module from bindings/python
    import _pancake_constants as _abi

# The dynamic library's name is platform-specific: `.dylib` on macOS, `.dll` on
# Windows, `.so` elsewhere. `zig build` emits the right one into zig-out/lib.
_LIB_FILE = (
    "libpancake.dylib" if sys.platform == "darwin"
    else "pancake.dll" if sys.platform == "win32"
    else "libpancake.so"
)
_LIB = pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "lib" / _LIB_FILE

_OK = _abi.OK
_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED
_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE
_FRAME_SHAPE_BYTE = _abi.FRAME_SHAPE_BYTE
_EVENT_DELIVER = _abi.EVENT_DELIVER
_EVENT_RESOLVE = _abi.EVENT_RESOLVE

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

_RESOLUTION_FULFILL, _RESOLUTION_BREAK = _abi.RESOLUTION_FULFILL, _abi.RESOLUTION_BREAK
_HINTS_EMPTY_MAP, _HINTS_EMPTY_FALSE = _abi.HINTS_EMPTY_MAP, _abi.HINTS_EMPTY_FALSE


# ── Raw ctypes layer (private) ───────────────────────────────────────────────


class _Reference(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("sub_kind", ctypes.c_uint32), ("id", ctypes.c_uint64)]


class _Argument(ctypes.Structure):
    pass


_Argument._fields_ = [
    ("kind", ctypes.c_uint32),
    ("boolean", ctypes.c_uint32),
    ("integer", ctypes.c_int64),
    ("float64", ctypes.c_double),
    ("bytes", ctypes.c_void_p),
    ("bytes_len", ctypes.c_size_t),
    ("reference", _Reference),
    ("items", ctypes.POINTER(_Argument)),
    ("items_len", ctypes.c_size_t),
]


class _Frame(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_void_p), ("len", ctypes.c_size_t), ("shape", ctypes.c_uint32)]


class _ManagedFrame(ctypes.Structure):
    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
        ("shape", ctypes.c_uint32),
        ("release", ctypes.c_void_p),
        ("private_data", ctypes.c_void_p),
    ]


class _Event(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("frame", _ManagedFrame)]


# The release callback a managed frame carries: void (*)(PancakeManagedFrame*).
_ManagedFrameRelease = ctypes.CFUNCTYPE(None, ctypes.POINTER(_ManagedFrame))

# Host allocator callbacks:
#   void *(*alloc)(void *user_data, size_t size, size_t alignment);
#   void  (*free )(void *user_data, void *ptr, size_t size, size_t alignment);
_AllocFn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)
_FreeFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)


class _Allocator(ctypes.Structure):
    _fields_ = [("alloc", _AllocFn), ("free", _FreeFn), ("user_data", ctypes.c_void_p)]


class _Deliver(ctypes.Structure):
    _fields_ = [
        ("target", _Reference),
        ("args", ctypes.POINTER(_Argument)),
        ("args_len", ctypes.c_size_t),
        ("has_answer", ctypes.c_uint32),
        ("answer", ctypes.c_uint64),
        ("owner", ctypes.c_void_p),
    ]


class _Resolve(ctypes.Structure):
    _fields_ = [
        ("answer", ctypes.c_uint64),
        ("resolution_kind", ctypes.c_uint32),
        ("fulfill", _Argument),
        ("break_message", ctypes.c_void_p),
        ("break_message_len", ctypes.c_size_t),
        ("owner", ctypes.c_void_p),
    ]


class _LastAbort(ctypes.Structure):
    _fields_ = [
        ("domain", ctypes.c_uint32),
        ("has_kind", ctypes.c_uint32),
        ("kind_name", ctypes.c_void_p),
        ("kind_name_len", ctypes.c_size_t),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
        ("error_name", ctypes.c_void_p),
        ("error_name_len", ctypes.c_size_t),
    ]


def _load():
    lib = ctypes.CDLL(str(_LIB))
    P = ctypes.c_void_p
    size_p = ctypes.POINTER(ctypes.c_size_t)
    sigs = {
        "pancake_abi_version": (
            [ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)],
            None,
        ),
        "pancake_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_clear_last_error": ([], None),
        "pancake_context_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_new_with_allocator": ([ctypes.POINTER(_Allocator), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_release": ([P], None),
        "pancake_peer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_negotiated": ([ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_negotiated_in": ([P, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_raw_open": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_raw_open_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_start_session": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_peer_session_is_open": ([P], ctypes.c_int32),
        "pancake_peer_release": ([P], None),
        "pancake_peer_feed_borrowed": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_peer_feed_owned": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_peer_step": ([P], ctypes.c_int32),
        "pancake_peer_recv_stream": ([P, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "pancake_peer_take_outbound": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_managed_frame_release": ([ctypes.POINTER(_ManagedFrame)], None),
        "pancake_peer_poll_event": ([P, ctypes.POINTER(_Event)], ctypes.c_int32),
        "pancake_event_release": ([ctypes.POINTER(_Event)], None),
        "pancake_peer_last_abort": ([P, ctypes.POINTER(_LastAbort)], ctypes.c_int32),
        "pancake_peer_register_export": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_next_export": ([P, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_next_answer": ([P, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_register_import": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_peek_event": ([P], ctypes.c_int32),
        "pancake_peer_send_deliver": (
            [P, ctypes.POINTER(_Reference), ctypes.POINTER(_Argument), ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint64],
            ctypes.c_int32,
        ),
        "pancake_peer_send_resolve": (
            [P, ctypes.c_uint64, ctypes.c_uint32, ctypes.POINTER(_Argument), ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_peer_poll_event_deliver": ([P, ctypes.POINTER(_Deliver)], ctypes.c_int32),
        "pancake_peer_poll_event_resolve": ([P, ctypes.POINTER(_Resolve)], ctypes.c_int32),
        "pancake_deliver_release": ([ctypes.POINTER(_Deliver)], None),
        "pancake_resolve_release": ([ctypes.POINTER(_Resolve)], None),
        "pancake_peer_register_bootstrap_cap": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_send_bootstrap_fetch": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_codec": ([P, ctypes.POINTER(ctypes.c_uint32)], ctypes.c_int32),
        "pancake_peer_send_gc_export": ([P, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t], ctypes.c_int32),
        "pancake_peer_send_gc_answer": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_tcp_netlayer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_release": ([P], None),
        "pancake_tcp_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_tcp_listen": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.POINTER(P)], ctypes.c_int32,
        ),
        "pancake_tcp_listener_port": ([P, ctypes.POINTER(ctypes.c_uint16)], ctypes.c_int32),
        "pancake_tcp_accept": ([P, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_conn_read_frame": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_tcp_conn_write_frame": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_tcp_conn_release": ([P], None),
        "pancake_tcp_listener_release": ([P], None),
        # OCapN locator URIs — core libpancake vocabulary, so a TCP-only consumer
        # reaches them without the iroh superset. One grammar, no hand-rolled
        # percent codec. Verbs mint an opaque PancakeLocator; nouns read it.
        "pancake_uri_parse_peer": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_parse_sturdyref": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_format_peer": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_int32,
        ),
        "pancake_uri_format_sturdyref": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_int32,
        ),
        "pancake_locator_transport": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_designator": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_swissnum": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_hint": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32,
        ),
        "pancake_locator_hint_count": ([P, size_p], ctypes.c_int32),
        "pancake_locator_hint_at": (
            [P, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_locator_release": ([P], None),
    }
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


_lib = _load()


# ── iroh transport (separate libpancake_iroh artifact, loaded lazily) ───────
#
# iroh's encrypted-QUIC netlayer links the Rust sidecar, which ADR-0055 keeps out
# of libpancake so the gate stays hermetic and the core stays pure Zig. It ships
# as its own optional superset library, loaded only on first iroh use, so a
# consumer that never touches iroh never needs it built (it needs cargo:
# `zig build iroh-abi`). The frame unit is identical to TCP's, so the same pump
# drives a peer over it; only the addressing differs (an endpoint id +
# direct-address hints, no host:port).

_IROH_LIB_FILE = (
    "libpancake_iroh.dylib" if sys.platform == "darwin"
    else "pancake_iroh.dll" if sys.platform == "win32"
    else "libpancake_iroh.so"
)
_IROH_LIB = pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "lib" / _IROH_LIB_FILE


def _load_iroh():
    lib = ctypes.CDLL(str(_IROH_LIB))
    P = ctypes.c_void_p
    u8p = ctypes.POINTER(ctypes.c_uint8)
    size_p = ctypes.POINTER(ctypes.c_size_t)
    sigs = {
        "pancake_iroh_netlayer_new": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_netlayer_close": ([P], None),
        "pancake_iroh_netlayer_release": ([P], None),
        "pancake_iroh_netlayer_node_id": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        "pancake_iroh_netlayer_direct_addrs": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        "pancake_iroh_netlayer_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_iroh_netlayer_accept": ([P, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_conn_read_frame": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_iroh_conn_write_frame": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_iroh_conn_release": ([P], None),
    }
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


_iroh_lib_cache = None


def _iroh():
    """Open the iroh ABI library on first use. It is optional — absent unless
    built with cargo — so a clear error names how to produce it rather than a raw
    load failure."""
    global _iroh_lib_cache
    if _iroh_lib_cache is None:
        try:
            _iroh_lib_cache = _load_iroh()
        except OSError as exc:
            raise RuntimeError(
                f"iroh transport unavailable: could not load {_IROH_LIB_FILE} from zig-out/lib. "
                "Build it with `zig build iroh-abi` (needs cargo). " + str(exc)
            ) from exc
    return _iroh_lib_cache


def _check_iroh(code: int) -> None:
    # The iroh library carries its own thread-local last-error, so pass an
    # explicit detail rather than scraping libpancake's unrelated one.
    if code != _OK:
        raise PancakeError(code, f"iroh transport call failed (code {code})")


# ── Public value vocabulary ──────────────────────────────────────────────────


def abi_version() -> tuple[int, int, int]:
    """The linked library's ``(major, minor, patch)`` ABI version."""
    major = ctypes.c_uint32()
    minor = ctypes.c_uint32()
    patch = ctypes.c_uint32()
    _lib.pancake_abi_version(ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch))
    return (major.value, minor.value, patch.value)


def last_error() -> Optional[str]:
    """The calling thread's last error message, or ``None`` when there is none."""
    length = _lib.pancake_last_error(None, 0)
    if length == 0:
        return None
    # The C side reserves one byte for a NUL and copies at most cap-1 message
    # bytes, so allocate length + 1 to receive all `length` of them.
    buf = (ctypes.c_uint8 * (length + 1))()
    _lib.pancake_last_error(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


def clear_last_error() -> None:
    """Clear the calling thread's last error message."""
    _lib.pancake_clear_last_error()


@dataclass(frozen=True)
class AbortDetail:
    """The typed cause of a peer's most recent local dispatch failure — the
    counterpart of the C ABI's ``PancakeLastAbort``. ``domain`` names the layer
    that refused (``"codec"``, ``"session"``, or ``"foreign"``), ``kind`` the
    projected ``op:abort`` kind when one exists, ``message`` the static
    diagnostic, and ``error_name`` the originating error."""

    domain: str
    kind: Optional[str]
    message: str
    error_name: str


class PancakeError(Exception):
    """A failed C ABI call, carrying the negative ``PANCAKE_ERR_*`` code.

    When a per-thread error message is available it is captured at raise time
    (the message is thread-local and may be overwritten by a later call) and
    shown by ``str(err)``. When the failure was a refused inbound frame,
    ``abort`` carries the typed :class:`AbortDetail` naming which layer refused
    and why.
    """

    def __init__(self, code: int, message: Optional[str] = None, abort: Optional[AbortDetail] = None):
        if message:
            super().__init__(f"pancake error {code}: {message}")
        else:
            super().__init__(f"pancake error {code}")
        self.code = code
        self.message = message
        self.abort = abort


def _check(code: int) -> None:
    if code != _OK:
        # Capture the thread-local message now, before any later call clobbers it.
        raise PancakeError(code, last_error())


@dataclass(frozen=True)
class Near:
    """A local export this peer hosts."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Far:
    """A partner-hosted import this peer holds."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Promise:
    """A pipeline promise on an answer."""

    answer: int


@dataclass(frozen=True)
class Sturdy:
    pass


@dataclass(frozen=True)
class Broken:
    pass


Reference = Union[Near, Far, Promise, Sturdy, Broken]


class Symbol(str):
    """A string that marshals as an OCapN symbol rather than a string."""


class Keyword(str):
    """A string that marshals as an OCapN keyword."""


class Set(list):
    """A list that marshals as an OCapN set (elements may be unhashable)."""


@dataclass(frozen=True)
class Tagged:
    """An OCapN tagged record: a tag symbol over a value list."""

    tag: str
    value: list


# An argument is a native Python value or a wrapper:
#   int, float, bool, bytes, str, Symbol, Keyword, None (void), Reference, list,
#   Set, Tagged.
Argument = Union[int, float, bool, bytes, str, "Symbol", "Keyword", None, Reference, list, "Set", "Tagged"]


@dataclass(frozen=True)
class Fulfill:
    value: Argument


@dataclass(frozen=True)
class Break:
    message: str


Resolution = Union[Fulfill, Break]


@dataclass(frozen=True)
class Deliver:
    target: Reference
    args: list
    answer: Optional[int] = None


@dataclass(frozen=True)
class Resolve:
    answer: int
    resolution: Resolution


@dataclass(frozen=True)
class Other:
    """Any other surfaced event (abort, gc, handoff, …), with its raw frame."""

    kind: int
    frame: bytes


Event = Union[Deliver, Resolve, Other]


# ── Marshalling ──────────────────────────────────────────────────────────────


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
    if isinstance(value, bool):  # before int — bool is an int subclass
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
        a.kind = _ARG_TAGGED
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


# ── The allocation context ───────────────────────────────────────────────────


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
    def with_allocator(cls, alloc, free) -> "Context":
        """A context that routes every allocation through host callables."""
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


# ── The Peer ─────────────────────────────────────────────────────────────────


# Release callbacks handed to the library with owned frames must outlive the
# frame; the library invokes them on its own schedule. Hold them here keyed by
# id until they fire (each clears its own entry); CFUNCTYPE values are not
# hashable, so a set will not do.
_owned_frame_callbacks: dict = {}


def _version_id(version: str) -> int:
    if version == "v1.0":
        return _abi.CAPTP_VERSION_V1_0
    if version == "pre-spec":
        return _abi.CAPTP_VERSION_PRE_SPEC
    raise ValueError(f"unknown OCapN profile {version!r}")


def _codec_id(codec: str) -> int:
    if codec == "syrup":
        return _abi.CODEC_SYRUP
    if codec == "capnp":
        return _abi.CODEC_CAPNP
    raise ValueError(f"unknown OCapN codec {codec!r}")


class Peer:
    """An authenticated OCapN/CapTP peer in the negotiating state.

    Use :meth:`start_session` and drive frames until
    :meth:`session_is_open` before application traffic. Raw already-open peers
    are available only through :meth:`raw_open` for tests and low-level fixtures.
    """

    def __init__(self, version: str = "v1.0", codec: str = "syrup"):
        ptr = ctypes.c_void_p()
        if version == "v1.0" and codec == "syrup":
            _check(_lib.pancake_peer_new(ctypes.byref(ptr)))
        else:
            _check(_lib.pancake_peer_new_negotiated(_version_id(version), _codec_id(codec), ctypes.byref(ptr)))
        self._raw = ptr
        # Library-allocator peer: no backing context to keep alive.
        self._context: Optional["Context"] = None

    @classmethod
    def new_in(cls, context: "Context", version: str = "v1.0", codec: str = "syrup") -> "Peer":
        """Create a negotiating peer whose allocations route through ``context``.
        The context must outlive the peer."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        if version == "v1.0" and codec == "syrup":
            _check(_lib.pancake_peer_new_in(context._raw, ctypes.byref(ptr)))
        else:
            _check(_lib.pancake_peer_new_negotiated_in(context._raw, _version_id(version), _codec_id(codec), ctypes.byref(ptr)))
        self._raw = ptr
        # Hold a strong reference so the context cannot be GC-collected (and its
        # allocator released) before this peer — CPython does not order
        # finalizers by allocation dependency.
        self._context = context
        return self

    @classmethod
    def raw_open(cls) -> "Peer":
        """Create an already-open peer for tests and direct-frame fixtures."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_raw_open(ctypes.byref(ptr)))
        self._raw = ptr
        self._context = None
        return self

    @classmethod
    def raw_open_in(cls, context: "Context") -> "Peer":
        """Context-backed counterpart of :meth:`raw_open`."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_raw_open_in(context._raw, ctypes.byref(ptr)))
        self._raw = ptr
        # Keep the context alive at least as long as this peer (see new_in).
        self._context = context
        return self

    def __enter__(self) -> "Peer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _lib.pancake_peer_release(self._raw)
            self._raw = None

    def __del__(self):
        self.release()

    def register_export(self, export_position: int) -> None:
        _check(_lib.pancake_peer_register_export(self._raw, export_position))

    def next_export(self) -> int:
        """Allocate and register the next free export position from the
        session's one export allocator — the counter that also mints bootstrap
        and resolver exports, so a spawned position can never alias one."""
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_next_export(self._raw, ctypes.byref(out)))
        return out.value

    def register_import(self, import_position: int) -> None:
        _check(_lib.pancake_peer_register_import(self._raw, import_position))

    def next_answer(self) -> int:
        """Allocate the next outbound answer position from the session's one
        answer allocator — the counter that backs every outbound question, so a
        privately-counted answer can never alias a live one."""
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_next_answer(self._raw, ctypes.byref(out)))
        return out.value

    def start_session(
        self,
        seed: bytes,
        *,
        transport: str = "tcp",
        designator: str,
        hints_empty_false: bool = True,
    ) -> None:
        """Sign and queue ``op:start-session`` from this negotiating peer. The
        handshake speaks the profile the peer was constructed with
        (``Peer("pre-spec")`` for upstream OCapN). The 32-byte ``seed`` is the
        session key (the library refuses any other length);
        ``transport``/``designator`` form the locator the partner verifies, so
        they must be what it expects — for a Goblins partner, ``"tcp"`` with
        ``hints_empty_false`` true (Goblins emits the empty hints as the
        boolean ``#f``). Flush it, then pump until :meth:`session_is_open`."""
        if len(seed) != 32:
            raise ValueError("a session seed must be 32 bytes")
        transport_b = transport.encode()
        designator_b = designator.encode()
        _check(_lib.pancake_peer_start_session(
            self._raw,
            transport_b, len(transport_b),
            designator_b, len(designator_b),
            _HINTS_EMPTY_FALSE if hints_empty_false else _HINTS_EMPTY_MAP,
            seed, len(seed),
        ))

    def session_is_open(self) -> bool:
        """Whether the authenticated handshake has completed and the session is open for
        traffic. Pump the connection and poll this before sending application
        messages."""
        rc = _lib.pancake_peer_session_is_open(self._raw)
        if rc < 0:
            raise PancakeError(rc)
        return rc == 1

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of this peer's most recent local dispatch failure,
        or ``None`` when no failure has been recorded. The per-call
        :class:`PancakeError` code names the failure family; this names the
        member. Errors raised by :meth:`feed`, :meth:`feed_owned`, and
        :meth:`recv_stream` carry it already as ``err.abort``."""
        info = _LastAbort()
        rc = _lib.pancake_peer_last_abort(self._raw, ctypes.byref(info))
        if rc == _WOULD_BLOCK:
            return None
        _check(rc)

        def text(ptr, length) -> str:
            return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""

        domain = {
            _abi.ABORT_DOMAIN_CODEC: "codec",
            _abi.ABORT_DOMAIN_SESSION: "session",
            _abi.ABORT_DOMAIN_FOREIGN: "foreign",
        }.get(info.domain, str(info.domain))
        return AbortDetail(
            domain=domain,
            kind=text(info.kind_name, info.kind_name_len) if info.has_kind else None,
            message=text(info.message, info.message_len),
            error_name=text(info.error_name, info.error_name_len),
        )

    def _dispatch_error(self, code: int) -> PancakeError:
        """A :class:`PancakeError` for a refused frame, carrying the typed abort
        cause. Captures the thread-local message first, before any later call
        clobbers it."""
        message = last_error()
        try:
            abort = self.last_abort()
        except PancakeError:
            abort = None
        return PancakeError(code, message, abort=abort)

    def feed(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        rc = _lib.pancake_peer_feed_borrowed(self._raw, ctypes.byref(f))
        if rc != _OK:
            raise self._dispatch_error(rc)

    def feed_owned(self, frame: bytes) -> None:
        """Transfer owned frame bytes into the inbound queue for the next
        :meth:`step` — the library owns the copy until it calls our release.

        A Python buffer owning a copy of ``frame`` is handed to the library
        with a release callback. On success the library owns it and calls the
        callback when done; on failure we reclaim it ourselves.
        """
        n = len(frame)
        buf = (ctypes.c_uint8 * n).from_buffer_copy(frame) if n else (ctypes.c_uint8 * 0)()

        # The owning buffer must outlive the descriptor: park it on the callback
        # closure so it lives exactly as long as the release callback does.
        state = {"buf": buf}

        def _release(_frame_ptr):
            # Drop the owning buffer and stop holding the callback alive.
            state.pop("buf", None)
            _owned_frame_callbacks.pop(id(release_cb), None)

        release_cb = _ManagedFrameRelease(_release)
        _owned_frame_callbacks[id(release_cb)] = release_cb

        managed = _ManagedFrame(
            ctypes.cast(buf, ctypes.c_void_p),
            n,
            _FRAME_SHAPE_BYTE,
            ctypes.cast(release_cb, ctypes.c_void_p),
            None,
        )
        rc = _lib.pancake_peer_feed_owned(self._raw, ctypes.byref(managed))
        if rc != _OK:
            # The descriptor was not adopted; reclaim the bytes ourselves and
            # drop the callback. Capture the message before it is clobbered.
            err = self._dispatch_error(rc)
            state.pop("buf", None)
            _owned_frame_callbacks.pop(id(release_cb), None)
            raise err

    def step(self) -> None:
        _check(_lib.pancake_peer_step(self._raw))

    def recv_stream(self, data: "Union[bytes, bytearray]") -> Optional[int]:
        """Frame and dispatch one whole frame out of a streamed read buffer.

        Returns the number of bytes consumed when a whole frame was framed and
        dispatched, ``None`` when ``data`` holds only a partial frame (read more
        and retry with the larger buffer), and raises :class:`PancakeError` on a
        fatal framing or dispatch error (malformed, frame too large, …).
        """
        n = len(data)
        # Copy into a C array (from_buffer_copy accepts a bytes or bytearray).
        # A borrowed `from_buffer` view is deliberately avoided: it would keep a
        # buffer export alive that blocks the caller's `del inbox[:consumed]`
        # resize (BufferError). Accepting the bytearray directly already removes
        # the redundant `bytes(inbox)` wrapper copy the drain loop used to make.
        buf = (ctypes.c_uint8 * n).from_buffer_copy(data) if n else (ctypes.c_uint8 * 0)()
        ptr = ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8))
        consumed = ctypes.c_size_t(0)
        rc = _lib.pancake_peer_recv_stream(self._raw, ptr, n, ctypes.byref(consumed))
        if rc == _OK:
            return consumed.value
        if rc == _WOULD_BLOCK:
            return None
        # The error carries the thread-local message and the typed abort cause.
        raise self._dispatch_error(rc)

    def register_bootstrap_cap(self, swissnum: bytes) -> int:
        buf = ctypes.create_string_buffer(swissnum, len(swissnum))
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_register_bootstrap_cap(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(swissnum), ctypes.byref(out)))
        return out.value

    def send_bootstrap_fetch(self, name: bytes) -> int:
        """Queue the canonical bootstrap ``fetch`` for the capability published
        behind ``name``, returning the answer position the partner's resolution
        arrives on (as a :class:`Resolve` event). Registers the bootstrap
        import and allocates the answer from the session's own counters."""
        buf = ctypes.create_string_buffer(name, len(name))
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_send_bootstrap_fetch(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(name), ctypes.byref(out)))
        return out.value

    def codec(self) -> int:
        """The codec the session speaks (a ``CODEC_*`` value), so an opaque
        :class:`Other` frame drained after a typed-poll refusal can be
        interpreted."""
        out = ctypes.c_uint32()
        _check(_lib.pancake_peer_codec(self._raw, ctypes.byref(out)))
        return out.value

    def send_gc_export(self, positions: list, deltas: list) -> None:
        """Queue an ``op:gc-export`` releasing wire-delta counts on imports
        this peer holds: ``positions[i]`` is released by ``deltas[i]``. The
        lists are parallel and must be non-empty and the same length."""
        if len(positions) != len(deltas):
            raise ValueError("positions and deltas must be the same length")
        n = len(positions)
        pos_arr = (ctypes.c_uint64 * n)(*positions)
        delta_arr = (ctypes.c_uint64 * n)(*deltas)
        _check(_lib.pancake_peer_send_gc_export(self._raw, pos_arr, delta_arr, n))

    def send_gc_answer(self, answer: int) -> None:
        """Queue an ``op:gc-answer`` releasing an answer this peer no longer
        needs."""
        _check(_lib.pancake_peer_send_gc_answer(self._raw, answer))

    def send_deliver(self, target: Reference, args: list, answer: Optional[int] = None) -> None:
        t = _ref_to_c(target)
        keepalive: list = []
        arr_ptr, arr_len = _args_to_c(list(args), keepalive)
        _check(
            _lib.pancake_peer_send_deliver(
                self._raw, ctypes.byref(t), arr_ptr, arr_len, 1 if answer is not None else 0, answer or 0
            )
        )

    def send_resolve(self, answer: int, resolution: Resolution) -> None:
        if isinstance(resolution, Fulfill):
            keepalive: list = []
            value = _arg_to_c(resolution.value, keepalive)
            _check(
                _lib.pancake_peer_send_resolve(
                    self._raw, answer, _RESOLUTION_FULFILL, ctypes.byref(value), None, 0
                )
            )
        else:
            msg = resolution.message.encode()
            buf = ctypes.create_string_buffer(msg, len(msg))
            _check(
                _lib.pancake_peer_send_resolve(
                    self._raw, answer, _RESOLUTION_BREAK, None, ctypes.cast(buf, ctypes.c_void_p), len(msg)
                )
            )

    def take_outbound(self) -> Optional[bytes]:
        frame = _ManagedFrame()
        rc = _lib.pancake_peer_take_outbound(self._raw, ctypes.byref(frame))
        if rc == _WOULD_BLOCK:
            return None
        # Any other non-OK code (e.g. an OOM after the frame was dequeued and
        # then freed) is a real failure: surface it instead of silently dropping
        # an outbound frame and ending the drain as if the queue were empty.
        if rc != _OK:
            raise PancakeError(rc, last_error())
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def poll(self) -> Optional[Event]:
        kind = _lib.pancake_peer_peek_event(self._raw)
        if kind == _EVENT_DELIVER:
            return self._poll_deliver()
        if kind == _EVENT_RESOLVE:
            return self._poll_resolve()
        if kind == _WOULD_BLOCK:
            return None
        # A negative code is a peek failure (e.g. a released peer), not an event
        # kind; fail closed rather than fabricating an Other with kind == -1.
        if kind < 0:
            raise PancakeError(kind, last_error())
        return self._poll_other()

    def _poll_deliver(self) -> Event:
        d = _Deliver()
        rc = _lib.pancake_peer_poll_event_deliver(self._raw, ctypes.byref(d))
        if rc == _ERR_UNSUPPORTED_VALUE:
            # The typed projection cannot carry this deliver (e.g. a handoff
            # argument). The event stays queued, so drain it as an opaque
            # Other — raising here would peek the same event forever.
            return self._poll_other()
        _check(rc)
        try:
            return Deliver(
                target=_ref_from_c(d.target),
                args=[_arg_from_c(d.args[i]) for i in range(d.args_len)],
                answer=d.answer if d.has_answer else None,
            )
        finally:
            # Always free the C-owned arena, even if marshalling raises on a
            # hostile payload — otherwise every bad frame leaks it.
            _lib.pancake_deliver_release(ctypes.byref(d))

    def _poll_resolve(self) -> Event:
        r = _Resolve()
        rc = _lib.pancake_peer_poll_event_resolve(self._raw, ctypes.byref(r))
        if rc == _ERR_UNSUPPORTED_VALUE:
            # Same leave-queued contract as _poll_deliver: drain the refused
            # resolve as an opaque Other so the loop survives.
            return self._poll_other()
        _check(rc)
        try:
            if r.resolution_kind == _RESOLUTION_FULFILL:
                resolution: Resolution = Fulfill(_arg_from_c(r.fulfill))
            else:
                msg = ctypes.string_at(r.break_message, r.break_message_len).decode(errors="replace") if r.break_message else ""
                resolution = Break(msg)
            return Resolve(answer=r.answer, resolution=resolution)
        finally:
            _lib.pancake_resolve_release(ctypes.byref(r))

    def _poll_other(self) -> Other:
        e = _Event()
        _check(_lib.pancake_peer_poll_event(self._raw, ctypes.byref(e)))
        frame = ctypes.string_at(e.frame.bytes, e.frame.len) if e.frame.bytes else b""
        kind = e.kind
        _lib.pancake_event_release(ctypes.byref(e))
        return Other(kind=kind, frame=frame)


# ── Actors ───────────────────────────────────────────────────────────────────
#
# This is pancake's Goblins-shaped actor model in Python. It is where the actor
# layer meets the OCapN peer. It mirrors the Zig ``actors.vat`` and the Racket
# binding's actor section in idiomatic Python: callables for behaviors, exceptions
# for broken resolutions, and dataclasses for the unified reference and promise.
#
# An actor is a callable ``behavior(verb, args) -> value``. It returns a reply
# value, or raises to break the resolution. A :class:`Ref` names an object the
# vat can eventual-send to, wherever it lives: a local actor in this vat, or a
# far object the bound peer holds as an import. :meth:`Vat.call` is the
# synchronous near-call and is local-only; :meth:`Vat.send` is the
# location-transparent eventual-send and routes by where the ref lives.


@dataclass(frozen=True)
class Ref:
    """A reference the vat can eventual-send to, wherever the object lives.

    A *local* ref names an actor in this vat; :meth:`Vat.call` and
    :meth:`Vat.send` run its turns here. A *far* ref wraps a :class:`Far`
    import the bound peer holds; :meth:`Vat.send` routes to it as an
    ``op:deliver`` and :meth:`Vat.call` (near) is illegal.
    """

    local_id: Optional[int] = None
    far: Optional[Far] = None
    # The wire reference this marshals to when handed to a partner as a capability
    # argument. A locally-spawned actor carries a `Near` (our export); set by the
    # :class:`Connection` layer. The vat itself never reads this.
    near: Optional[Near] = None

    @classmethod
    def local(cls, actor_id: int) -> "Ref":
        """A reference to a local actor by its vat id."""
        return cls(local_id=actor_id)

    @classmethod
    def to(cls, far: Far) -> "Ref":
        """A reference to a partner-hosted object the peer holds as an import."""
        return cls(far=far)

    @property
    def is_local(self) -> bool:
        return self.local_id is not None

    def _wire(self) -> Reference:
        """The wire reference to marshal this capability to in a `send` argument:
        a local actor's `Near` export, else the `Far` import it names."""
        if self.near is not None:
            return self.near
        if self.far is not None:
            return self.far
        raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this ref has no wire reference to marshal")


class VowBroken(Exception):
    """Raised when an awaited vow settles broken; the message is the break reason."""


class FetchFailed(Exception):
    """Raised when a ``fetch`` settles, but not with a capability.

    This is the application-level outcome — the partner answered, and the
    answer was not a reference — distinct from a marshalling failure or a
    broken promise. ``name`` is the swiss-number the fetch asked for."""

    def __init__(self, name: str):
        super().__init__(f'fetch("{name}") did not resolve to a capability')
        self.name = name


@dataclass(frozen=True)
class Vow:
    """A handle to the eventual result of a :meth:`Vat.send`.

    A vow is awaitable: ``value = await vat.send(ref, verb, args)`` resolves with
    the value, or raises :class:`VowBroken` on a break. You can also observe it
    with :meth:`Vat.on` for the callback style. A *local* vow settles during
    :meth:`Vat.drive`; a *far* vow settles when :meth:`Vat.serve` dispatches the
    matching inbound resolve, so something must be driving the vat (e.g. an
    ``async for event in conn`` loop) for the await to complete.
    """

    local_id: Optional[int] = None
    answer: Optional[int] = None
    # The vat that issued this vow, so `await` can register for its settlement.
    # Excluded from equality/repr — two vows are the same by position, not vat.
    vat: Optional["Vat"] = field(default=None, compare=False, repr=False)

    @property
    def is_local(self) -> bool:
        return self.local_id is not None

    def __await__(self):
        future = asyncio.get_running_loop().create_future()

        def fulfilled(value: object) -> None:
            if not future.done():
                future.set_result(value)

        def broken(message: str) -> None:
            if not future.done():
                future.set_exception(VowBroken(message))

        assert self.vat is not None, "an awaitable vow must come from Vat.send"
        self.vat.on(self, on_fulfilled=fulfilled, on_broken=broken)
        return future.__await__()


@dataclass
class _Listener:
    """A one-shot promise listener: at most one of ``on_fulfilled`` /
    ``on_broken`` fires when the vow settles."""

    on_fulfilled: Optional[object] = None
    on_broken: Optional[object] = None


class Vat:
    """A turn loop over a heap of actors, local and remote alike.

    A vat owns local actors (callables ``behavior(verb, args) -> value``), a
    queue of pending local eventual-sends, listeners for local and far vows, and
    an export map when it is bound to a peer. That export map lets inbound
    deliveries run published actors. You drive the vat; it owns no I/O and no
    scheduler thread.

    A pure-local vat (``Vat()``) sends and drives over local actors only. A vat
    bound to a peer (``Vat(peer)``) also routes far sends out as ``op:deliver``
    and serves inbound peer events through :meth:`serve`.
    """

    def __init__(self, peer: Optional[Peer] = None):
        self._peer = peer
        self._actors: dict = {}
        self._exports: dict = {}  # export id -> local actor id
        self._listeners: dict = {}  # local vow id -> _Listener
        self._far_listeners: dict = {}  # far answer -> _Listener
        self._queue: list = []  # pending local sends: (actor_id, verb, args, vow_id)
        self._next_actor = 1
        self._next_vow = 1

    @property
    def peer(self) -> Optional[Peer]:
        """The bound peer — to feed/step/take_outbound around :meth:`serve`."""
        return self._peer

    def spawn(self, behavior) -> Ref:
        """Spawn a local actor with ``behavior``, returning a local :class:`Ref`."""
        actor_id = self._next_actor
        self._next_actor += 1
        self._actors[actor_id] = behavior
        return Ref.local(actor_id)

    def call(self, ref: Ref, verb: str, args: Optional[list] = None):
        """The synchronous near-call (``$``): run ``ref``'s handler now and
        return its value. Legal only for a *local* ref — a far ref raises, since
        only :meth:`send` reaches one. Raises if no such actor exists, or
        propagates whatever the behavior itself raises."""
        if not ref.is_local:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot near-call a far ref; use send")
        behavior = self._actors.get(ref.local_id)
        if behavior is None:
            raise KeyError(f"no such actor: {ref.local_id}")
        return behavior(verb, list(args or []))

    def send(self, ref: Ref, verb: str, args: Optional[list] = None) -> Vow:
        """The eventual send (``<-``): location-transparent. A local target
        queues a turn for :meth:`drive` and returns a local :class:`Vow`. A far
        target sends an ``op:deliver`` over the bound peer — a leading
        :class:`Symbol` carries the verb, matching Goblins's
        ``($ obj 'method …)`` — and returns a far vow carrying the answer."""
        rest = list(args or [])
        if ref.is_local:
            vow_id = self._next_vow
            self._next_vow += 1
            self._queue.append((ref.local_id, verb, rest, vow_id))
            return Vow(local_id=vow_id, vat=self)
        if self._peer is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this vat has no peer; far sends need Vat(peer)")
        answer = self._peer.next_answer()
        payload = [Symbol(verb), *rest] if verb else rest
        self._peer.send_deliver(ref.far, payload, answer=answer)
        return Vow(answer=answer, vat=self)

    def on(self, vow: Vow, on_fulfilled=None, on_broken=None) -> None:
        """Register a one-shot listener for ``vow``. A local vow fires during
        :meth:`drive`; a far vow fires when :meth:`serve` dispatches the
        partner's resolution. ``on_fulfilled(value)`` runs on a fulfill,
        ``on_broken(message)`` on a break."""
        listener = _Listener(on_fulfilled, on_broken)
        if vow.is_local:
            self._listeners[vow.local_id] = listener
        else:
            self._far_listeners[vow.answer] = listener

    def break_far_vows(self, message: str) -> None:
        """Break every outstanding far vow with ``message``, firing each
        listener's ``on_broken``. A far vow settles only when the partner's
        resolution arrives over the wire, so once the connection is gone those
        replies can never come. The connection driver calls this on disconnect,
        so an awaiting :meth:`send` raises :class:`VowBroken` instead of hanging
        forever. Local vows are untouched: they settle synchronously in
        :meth:`drive` and never wait on the wire."""
        # Snapshot then clear before firing: a listener may register another far
        # vow, and mutating the dict mid-iteration would lose it.
        pending = list(self._far_listeners.values())
        self._far_listeners.clear()
        for listener in pending:
            if listener.on_broken is not None:
                listener.on_broken(message)

    def drive(self) -> None:
        """Run queued local eventual-sends to quiescence, settling each vow with
        the handler's value (a break carrying the message on a raised exception)
        and firing its listener. Turns queued by a turn run in the same drive
        (FIFO)."""
        index = 0
        while index < len(self._queue):
            actor_id, verb, args, vow_id = self._queue[index]
            index += 1
            try:
                resolution: Resolution = Fulfill(self.call(Ref.local(actor_id), verb, args))
            except Exception as error:  # noqa: BLE001 — a raise breaks the resolution
                resolution = Break(str(error))
            self._settle_local(vow_id, resolution)
        self._queue.clear()

    def publish(self, export_position: int, behavior) -> Ref:
        """Spawn ``behavior`` and publish it at ``export_position`` so a partner's
        deliveries to that export run the actor (dispatched by :meth:`serve`).
        Requires a bound peer. Returns the new local :class:`Ref`."""
        if self._peer is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this vat has no peer; publish needs Vat(peer)")
        ref = self.spawn(behavior)
        self._peer.register_export(export_position)
        self._exports[export_position] = ref.local_id
        return ref

    def serve(self, event: Event) -> bool:
        """Dispatch one inbound peer event. A deliver to a published export runs
        its actor (a leading :class:`Symbol` is the verb) and resolves the
        answer with the reply (a break if the actor raised). A resolve for a
        pending far vow fires its listener. Returns whether the event belonged
        to this vat — ``False`` means the caller handles it."""
        if isinstance(event, Deliver):
            return self._serve_deliver(event)
        if isinstance(event, Resolve):
            return self._serve_resolve(event)
        return False

    def _serve_deliver(self, event: Deliver) -> bool:
        if not isinstance(event.target, Near):
            return False
        actor_id = self._exports.get(event.target.id)
        if actor_id is None:
            return False

        # A leading symbol is the method verb; the rest are its arguments.
        args = event.args
        if args and isinstance(args[0], Symbol):
            verb, rest = str(args[0]), args[1:]
        else:
            verb, rest = "", args

        try:
            resolution: Resolution = Fulfill(self.call(Ref.local(actor_id), verb, rest))
        except Exception as error:  # noqa: BLE001 — broken resolution carries the message
            resolution = Break(str(error))
        if event.answer is not None and self._peer is not None:
            self._peer.send_resolve(event.answer, resolution)
        return True

    def _serve_resolve(self, event: Resolve) -> bool:
        listener = self._far_listeners.pop(event.answer, None)
        if listener is None:
            return False
        self._fire(listener, event.resolution)
        return True

    def _settle_local(self, vow_id: int, resolution: Resolution) -> None:
        listener = self._listeners.pop(vow_id, None)
        if listener is not None:
            self._fire(listener, resolution)

    @staticmethod
    def _fire(listener: _Listener, resolution: Resolution) -> None:
        if isinstance(resolution, Fulfill):
            if listener.on_fulfilled is not None:
                listener.on_fulfilled(resolution.value)
        else:
            if listener.on_broken is not None:
                listener.on_broken(resolution.message)


# ── Async driver ──────────────────────────────────────────────────────────────


class _KeyedLocator(NamedTuple):
    """The locator a keyed ``op:start-session`` signs for a transport: the
    transport name, its designator, and whether empty hints encode as ``#f``."""

    transport: str
    designator: str
    hints_empty_false: bool = True


class _FramePump:
    """How one transport moves a frame — a complete, codec-self-delimited CapTP
    message, the same unit :meth:`Peer.take_outbound` yields and
    :meth:`Peer.feed`/:meth:`Peer.recv_stream` consume. A transport differs only
    in how it moves that unit, never in the pump that drives the peer over it, so
    :class:`AsyncConnection` holds a pump and is otherwise transport-blind."""

    def locator(self) -> _KeyedLocator:
        raise NotImplementedError

    def dispatch_buffered(self, peer: Peer) -> bool:
        """Frame and dispatch one already-buffered inbound frame without
        blocking; ``True`` when one was dispatched (the caller loops). A
        one-frame-per-receive transport buffers nothing and returns ``False``."""
        raise NotImplementedError

    async def receive(self, peer: Peer) -> bool:
        """Block for more inbound and dispatch it; ``False`` on a clean EOF."""
        raise NotImplementedError

    async def write_frame(self, frame: bytes) -> None:
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError


class _TcpPump(_FramePump):
    """The TCP pump: an asyncio stream pair plus the inbound byte buffer the peer
    frames. The keyed locator signs the socket's own ``host:port``, a true ``tcp``
    locator a Goblins partner accepts."""

    _READ_CHUNK = 65536

    def __init__(self, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter"):
        self._reader = reader
        self._writer = writer
        self._inbox = bytearray()

    def locator(self) -> _KeyedLocator:
        host, port, *_ = self._writer.get_extra_info("sockname")
        return _KeyedLocator("tcp", f"{host}:{port}")

    def dispatch_buffered(self, peer: Peer) -> bool:
        if not self._inbox:
            return False
        consumed = peer.recv_stream(self._inbox)
        if consumed is None:
            return False
        del self._inbox[:consumed]
        return True

    async def receive(self, peer: Peer) -> bool:
        chunk = await self._reader.read(self._READ_CHUNK)
        if chunk == b"":
            return False  # clean EOF
        self._inbox.extend(chunk)
        return True

    async def write_frame(self, frame: bytes) -> None:
        self._writer.write(frame)
        await self._writer.drain()

    async def close(self) -> None:
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (OSError, asyncio.CancelledError):
            pass


class _IrohPump(_FramePump):
    """The iroh pump: an :class:`IrohConn` that delivers and accepts whole frames
    through the sidecar FFI. Its calls block the calling thread (the sidecar runs
    its own runtime), so each rides :func:`asyncio.to_thread` to keep the event
    loop free. The keyed locator signs the ``iroh`` transport with the local
    endpoint id as designator (empty for a dialer, matching the Zig driver). When
    the pump minted its own dialing netlayer it owns that netlayer's lifetime
    too."""

    def __init__(self, conn: IrohConn, designator: str, owned_netlayer: "Optional[IrohNetlayer]" = None):
        self._conn = conn
        self._designator = designator
        self._owned_netlayer = owned_netlayer

    def locator(self) -> _KeyedLocator:
        return _KeyedLocator("iroh", self._designator)

    def dispatch_buffered(self, peer: Peer) -> bool:
        # Each receive reads exactly one whole frame; nothing is buffered ahead.
        return False

    async def receive(self, peer: Peer) -> bool:
        frame = await asyncio.to_thread(self._conn.read_frame)
        if frame is None:
            return False  # clean EOF
        peer.feed(frame)
        return True

    async def write_frame(self, frame: bytes) -> None:
        await asyncio.to_thread(self._conn.write_frame, frame)

    async def close(self) -> None:
        self._conn.release()
        if self._owned_netlayer is not None:
            self._owned_netlayer.release()


class AsyncConnection:
    """An OCapN/CapTP peer driven asynchronously over a transport pump.

    The sync :class:`Peer` is sans-io — it never blocks and never owns a socket.
    This owns one peer and one :class:`_FramePump` and *drives* the peer over it:
    source whole frames (or raw bytes the peer frames), let the peer dispatch
    them, write the peer's outbound frames back, and surface events. The pump is
    the only thing that differs between transports (TCP today, iroh through the
    sidecar); the drive loop is identical.

    The peer is a single-owner state machine: one ``AsyncConnection`` owns one
    peer and must be driven from a single task. Use as an ``async with`` context
    manager, or call :meth:`aclose`. This is the pump layer :class:`Connection`
    builds on; an application usually holds a :class:`Connection`.
    """

    def __init__(self, peer: Peer, pump: _FramePump):
        self._peer = peer
        self._pump = pump
        self._vat: Optional[Vat] = None

    @classmethod
    async def connect(cls, host: str, port: int) -> "AsyncConnection":
        """Connect to ``host:port`` and complete the keyed OCapN handshake."""
        reader, writer = await asyncio.open_connection(host, port)
        ac = cls(Peer(), _TcpPump(reader, writer))
        await _open_keyed_session(ac)
        return ac

    @classmethod
    def from_stream(cls, peer: Peer, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter") -> "AsyncConnection":
        """Wrap an already-connected stream pair and a peer you have configured
        (registered exports/imports, bootstrap caps, …)."""
        return cls(peer, _TcpPump(reader, writer))

    @classmethod
    def from_pump(cls, peer: Peer, pump: _FramePump) -> "AsyncConnection":
        """Wrap a peer and an already-built frame pump — the transport-neutral
        constructor the iroh path uses."""
        return cls(peer, pump)

    @property
    def locator(self) -> _KeyedLocator:
        """The locator this connection's transport signs in its start-session."""
        return self._pump.locator()

    @property
    def peer(self) -> Peer:
        """The owned peer — e.g. to register exports/imports before driving."""
        return self._peer

    def vat(self) -> "Vat":
        """A :class:`Vat` bound to this connection's peer, created once and
        cached. This is how you drive actors over the wire: ``publish`` an actor
        to host it, ``send`` to a far :class:`Ref` to call a remote object, and
        hand each event from :meth:`next_event` to :meth:`Vat.serve`. The vat
        enqueues on the peer; :meth:`next_event` and :meth:`flush` move bytes."""
        if self._vat is None:
            self._vat = Vat(self._peer)
        return self._vat

    async def flush(self) -> None:
        """Flush whatever is already queued on the peer's outbound to the wire.

        A :meth:`Vat.send` only enqueues; the bytes leave when something pumps
        the peer. :meth:`next_event` pumps at the top of its loop, so a reply
        queued while serving an event leaves on the next turn. But work another
        task queues onto this peer — a server pushing a broadcast to a subscriber
        whose own task is parked reading — would sit unsent until that task woke.
        Call :meth:`flush` right after such a cross-task send to put the bytes on
        the wire now."""
        await self._pump_outbound()

    async def send_deliver(self, target: Reference, args: list, answer: Optional[int] = None) -> None:
        """Queue a call to ``target`` and flush it to the wire. ``answer``
        requests a reply."""
        self._peer.send_deliver(target, args, answer)
        await self._pump_outbound()

    async def send_resolve(self, answer: int, resolution: Resolution) -> None:
        """Queue a reply settling ``answer`` and flush it to the wire."""
        self._peer.send_resolve(answer, resolution)
        await self._pump_outbound()

    def __aiter__(self):
        """The connection as a native event stream: ``async for event in conn:``.
        Yields each event the peer surfaces and ends on a clean disconnect, so the
        idiomatic receive loop is just an ``async for``. (Same as looping on
        :meth:`next_event` until it returns ``None``.)"""
        return self._events()

    async def _events(self):
        event = await self.next_event()
        while event is not None:
            yield event
            event = await self.next_event()

    async def next_event(self) -> Optional[Event]:
        """Await the next application event, driving the transport as needed.
        Returns ``None`` on a clean end of stream."""
        while True:
            # A surfaced event takes priority.
            event = self._peer.poll()
            if event is not None:
                return event
            # Flush anything the last dispatch queued (replies, aborts).
            await self._pump_outbound()
            # Dispatch every whole frame already buffered; each may surface an
            # event or queue outbound, so loop back to re-check.
            consumed_any = False
            while self._pump.dispatch_buffered(self._peer):
                consumed_any = True
            if consumed_any:
                continue
            # Need more from the wire.
            if not await self._pump.receive(self._peer):
                return None  # clean EOF

    async def _drive_until_session_open(self) -> None:
        """Pump handshake frames without consuming application events."""
        while not self._peer.session_is_open():
            await self._pump_outbound()
            dispatched = False
            while self._pump.dispatch_buffered(self._peer):
                dispatched = True
                if self._peer.session_is_open():
                    return
            if dispatched:
                continue
            if not await self._pump.receive(self._peer):
                raise PancakeError(_ERR_CLOSED, "connection closed during the OCapN handshake")

    async def _pump_outbound(self) -> None:
        """Encode pending outbound work and write every queued frame, then flush."""
        self._peer.step()
        while (frame := self._peer.take_outbound()) is not None:
            await self._pump.write_frame(frame)

    async def aclose(self) -> None:
        """Close the transport and release the owned peer."""
        await self._pump.close()
        self._peer.release()

    async def __aenter__(self) -> "AsyncConnection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()


def _host_buf(host: str):
    data = host.encode()
    buf = ctypes.create_string_buffer(data, len(data))
    return buf, len(data)


class Endpoint:
    """A blocking TCP endpoint: the ``pancake_tcp_*`` frame shuttle,
    one layer below :class:`Connection`. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "Endpoint":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _lib.pancake_tcp_conn_release(self._raw)
            self._raw = None

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises PancakeError(ERR_CLOSED) on clean EOF."""
        frame = _ManagedFrame()
        _check(_lib.pancake_tcp_conn_read_frame(self._raw, ctypes.byref(frame)))
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check(_lib.pancake_tcp_conn_write_frame(self._raw, ctypes.byref(f)))


class Listener:
    """A bound TCP listener. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "Listener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _lib.pancake_tcp_listener_release(self._raw)
            self._raw = None

    def port(self) -> int:
        out = ctypes.c_uint16()
        _check(_lib.pancake_tcp_listener_port(self._raw, ctypes.byref(out)))
        return out.value

    def accept(self, codec: str = "syrup", max_frame_bytes: int = 4096) -> Endpoint:
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_accept(self._raw, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return Endpoint(out)


class Netlayer:
    """Owns the blocking-TCP I/O backend; outlives the endpoints made from it."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_netlayer_new(ctypes.byref(out)))
        self._raw = out
        self._context: Optional["Context"] = None

    @classmethod
    def new_in(cls, context: "Context") -> "Netlayer":
        """Create a netlayer whose backend and per-connection buffers allocate
        through ``context``. The context must outlive the netlayer."""
        self = cls.__new__(cls)
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_netlayer_new_in(context._raw, ctypes.byref(out)))
        self._raw = out
        # Keep the context alive at least as long as this netlayer (see Peer.new_in).
        self._context = context
        return self

    def __enter__(self) -> "Netlayer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _lib.pancake_tcp_netlayer_release(self._raw)
            self._raw = None

    def listen(self, host: str, port: int = 0) -> Listener:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_listen(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, ctypes.byref(out)))
        return Listener(out)

    def connect(self, host: str, port: int, codec: str = "syrup", max_frame_bytes: int = 4096) -> Endpoint:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_connect(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return Endpoint(out)


class Reachability(enum.IntEnum):
    """An iroh endpoint's addressing posture — how it dials partners and how it
    is dialed. Every iroh constructor requires it explicitly; there is **no
    default**, because the right posture is a deployment decision (relay-less vs
    relayed, discovery vs none) and a hidden one would silently route — or refuse
    to route — a partner's traffic.

    ``DIRECT`` (0)
        Dial by endpoint id plus direct-address hints; relay-less, no discovery.
        A URI must carry ``direct-addresses``. This is the rooms demo's posture.
    ``DISCOVERY`` (1)
        Use the n0 relays and DNS discovery, so a partner is dialable by
        endpoint id alone.
    ``DISCOVERY_NO_RELAY`` (2)
        Use DNS discovery, but no relays.
    ``LOCAL_DISCOVERY`` (3)
        Use an in-process address book — for tests and same-process peers.
    """

    DIRECT = 0
    DISCOVERY = 1
    DISCOVERY_NO_RELAY = 2
    LOCAL_DISCOVERY = 3


class IrohConn:
    """One iroh QUIC connection carrying one OCapN session, framed on the
    netlayer's codec — the iroh sibling of :class:`Endpoint`. Its calls block the
    calling thread (the sidecar runs its own runtime), so the async iroh transport
    drives them through :func:`asyncio.to_thread`."""

    def __init__(self, raw):
        self._raw = raw

    def read_frame(self) -> "Optional[bytes]":
        """Block for one whole frame; ``None`` on a clean end of stream."""
        frame = _ManagedFrame()
        rc = _iroh().pancake_iroh_conn_read_frame(self._raw, ctypes.byref(frame))
        if rc == _ERR_CLOSED:
            return None
        _check_iroh(rc)
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check_iroh(_iroh().pancake_iroh_conn_write_frame(self._raw, ctypes.byref(f)))

    def release(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_conn_release(self._raw)
            self._raw = None


class IrohNetlayer:
    """A bound iroh QUIC endpoint plus the sidecar runtime driving it — the iroh
    sibling of :class:`Netlayer`, and its own listener (there is no host:port, so
    :meth:`accept` lives here). Release every :class:`IrohConn` it mints before
    releasing it.

    ``reachability`` (a :class:`Reachability`) is required — it sets the
    endpoint's addressing posture and has no default."""

    def __init__(self, reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None):
        if secret_seed is not None and len(secret_seed) != 32:
            raise ValueError("an iroh secret seed must be 32 bytes")
        seed = secret_seed or b""
        buf = ctypes.create_string_buffer(seed, len(seed)) if seed else None
        out = ctypes.c_void_p()
        _check_iroh(_iroh().pancake_iroh_netlayer_new(
            ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None, len(seed),
            int(reachability), ctypes.byref(out),
        ))
        self._raw = out

    def node_id(self) -> str:
        """This endpoint's id — its Ed25519 public key as lowercase hex, the
        dialable designator a keyed locator signs."""
        cap = 64
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_node_id(self._raw, out, cap, ctypes.byref(n)))
        return bytes(out[: n.value]).decode()

    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct socket addresses — the dialing
        hint a partner needs because the sidecar binds relay-less."""
        cap = 1024
        out = (ctypes.c_uint8 * cap)()
        n = ctypes.c_size_t()
        _check_iroh(_iroh().pancake_iroh_netlayer_direct_addrs(self._raw, out, cap, ctypes.byref(n)))
        return bytes(out[: n.value]).decode()

    def connect(self, node_id: str, addr_hints: str, codec: str = "syrup", max_frame_bytes: int = 4096) -> IrohConn:
        """Dial a partner by endpoint id (``addr_hints`` its comma-separated
        direct-address list) and complete a framed connection."""
        id_b = node_id.encode()
        hints_b = addr_hints.encode()
        id_buf = ctypes.create_string_buffer(id_b, len(id_b))
        hints_buf = ctypes.create_string_buffer(hints_b, len(hints_b))
        out = ctypes.c_void_p()
        _check_iroh(_iroh().pancake_iroh_netlayer_connect(
            self._raw,
            ctypes.cast(id_buf, ctypes.c_void_p), len(id_b),
            ctypes.cast(hints_buf, ctypes.c_void_p), len(hints_b),
            _codec_id(codec), max_frame_bytes, ctypes.byref(out),
        ))
        return IrohConn(out)

    def close(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_netlayer_close(self._raw)

    def release(self) -> None:
        if self._raw:
            _iroh().pancake_iroh_netlayer_release(self._raw)
            self._raw = None


# ── Connection: the application surface ──────────────────────────────────────
#
# This is what an application holds. It composes a peer, a vat, and the asyncio
# I/O driver into one object, so a consumer never stitches those three together
# by hand. The verbs — ``connect``/``listen``, ``fetch``/``publish``, ``spawn``,
# ``send``, ``serve``, ``close`` — are the whole common surface. The raw
# :class:`Peer`, :class:`Vat`, and :class:`AsyncConnection` remain for power
# users (reach ``conn.peer``), but no application needs them.

def _is_wire_reference(value: object) -> bool:
    return isinstance(value, (Near, Far, Promise, Sturdy, Broken))


async def _open_keyed_session(ac: "AsyncConnection") -> None:
    """Complete the keyed ``op:start-session`` handshake over a negotiating peer:
    sign the transport's locator with a per-connection random session key, flush
    it, and pump until the partner's start-session opens the session. Entropy is
    generated here, at the I/O boundary, never in the sans-io core. The locator
    comes from the transport pump — the socket's real local address for ``tcp``
    (a true locator a Goblins partner accepts), the local endpoint id for
    ``iroh`` — so the signed locator always matches what the partner expects."""
    loc = ac.locator
    ac.peer.start_session(
        secrets.token_bytes(32),
        transport=loc.transport,
        designator=loc.designator,
        hints_empty_false=loc.hints_empty_false,
    )
    await ac.flush()
    await ac._drive_until_session_open()


class Connection:
    """A live connection to one OCapN partner — the one object an app holds.

        conn = await connect("127.0.0.1", 9099)
        conn.serve()
        board = await conn.fetch("board")
        inbox = conn.spawn(lambda verb, args: None)
        await conn.send(board, "watch", [inbox])
    """

    def __init__(self, ac: AsyncConnection):
        self._ac = ac
        self._vat = ac.vat()
        self._serve_task: Optional[asyncio.Task] = None
        self._closing = False

    @classmethod
    async def connect(cls, host: str, port: int) -> "Connection":
        """Dial ``host:port``, complete the keyed OCapN handshake, and return a
        ready connection. The session is open before this resolves, so a
        ``fetch``/``send`` rides an established session — the same handshake a
        real Goblins peer requires."""
        reader, writer = await asyncio.open_connection(host, port)
        ac = AsyncConnection.from_stream(Peer(), reader, writer)
        await _open_keyed_session(ac)
        return cls(ac)

    @classmethod
    async def _accept(cls, reader, writer) -> "Connection":
        """Wrap an accepted stream and complete the keyed handshake from the
        responder side. Resolves once the session is open."""
        ac = AsyncConnection.from_stream(Peer(), reader, writer)
        await _open_keyed_session(ac)
        return cls(ac)

    @classmethod
    async def connect_iroh(cls, node_id: str, direct_addresses: str, reachability: "Union[int, Reachability]") -> "Connection":
        """Dial an iroh partner by endpoint id and direct-address hints, complete
        the keyed OCapN handshake over the encrypted-QUIC transport, and return a
        ready connection — the iroh sibling of :meth:`connect`. The local
        endpoint is ephemeral (a fresh key) and released with the connection.
        ``reachability`` (a :class:`Reachability`) sets the ephemeral dialer's
        posture and is required — there is no default. Needs the iroh ABI library
        (``zig build iroh-abi``)."""
        netlayer = IrohNetlayer(reachability)
        try:
            conn = await asyncio.to_thread(netlayer.connect, node_id, direct_addresses)
        except BaseException:
            netlayer.release()
            raise
        # A dialer signs an empty designator (its identity is the session key),
        # matching the Zig driver; the pump owns the ephemeral netlayer's lifetime.
        ac = AsyncConnection.from_pump(Peer(), _IrohPump(conn, "", netlayer))
        await _open_keyed_session(ac)
        return cls(ac)

    @classmethod
    async def _accept_iroh(cls, conn: IrohConn, local_node_id: str) -> "Connection":
        """Complete the responder handshake over an accepted iroh connection,
        signing the server's endpoint id as the locator designator (used by
        :class:`IrohServer`). The accepted connection's netlayer belongs to the
        server, not this connection."""
        ac = AsyncConnection.from_pump(Peer(), _IrohPump(conn, local_node_id))
        await _open_keyed_session(ac)
        return cls(ac)

    @property
    def peer(self) -> Peer:
        """The underlying sans-io peer — the escape hatch for handoff, pipelining,
        and session control. Applications do not need it."""
        return self._ac.peer

    def spawn(self, behavior) -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback. The
        position comes from the session's one export allocator, so it can never
        alias a bootstrap or resolver export."""
        position = self._ac.peer.next_export()
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def publish(self, name: str, behavior) -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        position = self._ac.peer.register_bootstrap_cap(name.encode())
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def _settle(self, vow) -> "asyncio.Future":
        """Register a listener on ``vow`` now and return a future it settles. The
        listener must be registered before any pump (``drive``/``flush``): a local
        ``drive`` fires synchronously, and a far reply can land on the serve loop
        the instant ``flush`` yields — either would settle before a later ``await``
        could subscribe."""
        future = asyncio.get_running_loop().create_future()

        def fulfilled(value: object) -> None:
            if not future.done():
                future.set_result(value)

        def broken(message: str) -> None:
            if not future.done():
                future.set_exception(VowBroken(message))

        self._vat.on(vow, on_fulfilled=fulfilled, on_broken=broken)
        return future

    async def fetch(self, name: str) -> Ref:
        """Fetch a partner's published capability by ``name``. Starts the inbound
        loop itself, so a ``fetch`` straight after ``connect`` works without a
        separate :meth:`serve` call (which stays the way to keep serving).
        Raises :class:`VowBroken` when the partner breaks the fetch, and
        :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        self.serve()  # idempotent; the resolution arrives on the inbound loop
        # The canonical fetch lives in the library: one call registers the
        # bootstrap import, allocates the answer, and queues the deliver.
        answer = self._ac.peer.send_bootstrap_fetch(name.encode())
        future = self._settle(Vow(answer=answer, vat=self._vat))
        await self._ac.flush()
        result = await future
        if not _is_wire_reference(result):
            raise FetchFailed(name)
        return Ref(far=result) if isinstance(result, Far) else Ref(near=result)

    async def send(self, target: Ref, verb: str, args: Optional[list] = None):
        """Call ``verb(args)`` on the capability ``target`` and await the reply.
        Flushes immediately. ``args`` may contain :class:`Ref`s. Raises
        :class:`VowBroken` if the partner breaks the call."""
        wire_args = [self._lower(a) for a in (args or [])]
        if target.local_id is None:
            self.serve()  # far reply arrives on the inbound loop
        vow = self._vat.send(target, verb, wire_args)
        future = self._settle(vow)
        if target.local_id is not None:
            self._vat.drive()
        else:
            await self._ac.flush()
        return self._lift(await future)

    async def tell(self, target: Ref, verb: str, args: Optional[list] = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        wire_args = [self._lower(a) for a in (args or [])]
        if target.local_id is not None:
            self._vat.send(target, verb, wire_args)
            self._vat.drive()
            return
        payload = [Symbol(verb), *wire_args] if verb else wire_args
        self._ac.peer.send_deliver(target._wire(), payload, answer=None)
        await self._ac.flush()

    def serve(self) -> "asyncio.Task":
        """Run the inbound event loop as a background task: dispatch each arriving
        call to its actor and settle the promises of awaiting ``send``s. The task
        completes when the connection closes; started once."""
        if self._serve_task is None:
            self._serve_task = asyncio.create_task(self._serve_loop())
        return self._serve_task

    async def _serve_loop(self) -> None:
        # Either a clean disconnect or a transport fault ends the loop; the wire
        # is gone in both cases, so break any ``send`` still awaiting a reply
        # rather than leaving its future pending forever.
        try:
            async for event in self._ac:
                self._vat.serve(event)
        except (asyncio.CancelledError, OSError):
            if not self._closing:
                raise
        finally:
            self._vat.break_far_vows("connection closed")

    async def close(self) -> None:
        """Close the connection; a running :meth:`serve` completes cleanly."""
        self._closing = True
        await self._ac.aclose()
        if self._serve_task is not None:
            try:
                await self._serve_task
            except (asyncio.CancelledError, OSError):
                pass

    async def __aenter__(self) -> "Connection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    def _wrap(self, behavior):
        def wrapped(verb: str, raw_args: list):
            result = behavior(verb, [self._lift(a) for a in raw_args])
            return None if result is None else self._lower(result)
        return wrapped

    @staticmethod
    def _lower(value):
        if isinstance(value, Ref):
            return value._wire()
        if isinstance(value, Set):  # before list — Set subclasses list
            return Set(Connection._lower(v) for v in value)
        if isinstance(value, Tagged):
            return Tagged(value.tag, [Connection._lower(v) for v in value.value])
        if isinstance(value, list):
            return [Connection._lower(v) for v in value]
        return value

    @staticmethod
    def _lift(value):
        if isinstance(value, Far):
            return Ref(far=value)
        if isinstance(value, Near):
            return Ref(near=value)
        if isinstance(value, Set):  # before list — Set subclasses list
            return Set(Connection._lift(v) for v in value)
        if isinstance(value, Tagged):
            return Tagged(value.tag, [Connection._lift(v) for v in value.value])
        if isinstance(value, list):
            return [Connection._lift(v) for v in value]
        return value


async def connect(host: str, port: int) -> Connection:
    """Dial ``host:port`` and return a ready connection — the module-level
    shorthand for :meth:`Connection.connect`."""
    return await Connection.connect(host, port)


class Server:
    """A listening server — one object an app holds, mirroring the Deno/Rust/Racket
    servers. Async-iterable (``async for conn in server``), and ``.port`` surfaces
    the bound port so binding an ephemeral port (``port=0``) and telling a partner
    where to connect works the same as the other bindings."""

    def __init__(self, server: asyncio.AbstractServer, queue: "asyncio.Queue"):
        self._server = server
        self._queue = queue

    @property
    def port(self) -> int:
        """The kernel-chosen bound port (read it back after binding ``port=0``)."""
        return self._server.sockets[0].getsockname()[1]

    def close(self) -> None:
        self._server.close()

    def __aiter__(self) -> "Server":
        return self

    async def __anext__(self) -> "Connection":
        reader, writer = await self._queue.get()
        return await Connection._accept(reader, writer)


async def listen(host: str, port: int = 0) -> Server:
    """Bind a listening :class:`Server`. ``async for conn in await listen(host, 0)``
    accepts each partner; ``server.port`` reads the bound ephemeral port. Each
    yielded :class:`Connection` is one accepted partner — publish capabilities on
    it and call :meth:`Connection.serve`."""
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), host, port,
    )
    return Server(server, queue)


# ── OCapN locator URIs ───────────────────────────────────────────────────────
#
# The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
# vocabulary, defined once in libpancake's `pancake_uri_*` / `pancake_locator_*`
# surface, so no binding hand-rolls a percent codec. `parse_locator` copies every
# borrowed view into Python strings before releasing the handle; `format_peer_uri`
# renders through the same grammar.


class Locator(NamedTuple):
    """A parsed OCapN locator: the fields a ``pancake_uri_parse_*`` yields.
    ``swissnum`` is empty for a peer URI, the swiss bytes for a sturdyref."""

    transport: str
    designator: str
    swissnum: str
    hints: "dict[str, str]"


def _read_view(ptr: ctypes.c_void_p, length: ctypes.c_size_t) -> str:
    # Decode a borrowed (pointer, length) view a locator accessor filled. A zero
    # length (or NULL pointer) is the empty string.
    n = length.value
    if n == 0 or not ptr.value:
        return ""
    return ctypes.string_at(ptr.value, n).decode("utf-8")


def parse_locator(uri: str, *, sturdyref: bool = False) -> Locator:
    """Parse an ``ocapn://`` URI into its structured locator fields through the
    core grammar. ``sturdyref`` selects the ``/s/<swiss>`` form; the default reads
    a peer URI. Raises :class:`PancakeError` for a malformed URI."""
    raw = uri.encode("utf-8")
    out = ctypes.c_void_p()
    parse = _lib.pancake_uri_parse_sturdyref if sturdyref else _lib.pancake_uri_parse_peer
    _check(parse(raw, len(raw), ctypes.byref(out)))
    try:
        def field(accessor) -> str:
            p = ctypes.c_void_p()
            n = ctypes.c_size_t()
            _check(accessor(out, ctypes.byref(p), ctypes.byref(n)))
            return _read_view(p, n)

        count = ctypes.c_size_t()
        _check(_lib.pancake_locator_hint_count(out, ctypes.byref(count)))
        hints: "dict[str, str]" = {}
        for i in range(count.value):
            kp = ctypes.c_void_p()
            kn = ctypes.c_size_t()
            vp = ctypes.c_void_p()
            vn = ctypes.c_size_t()
            _check(_lib.pancake_locator_hint_at(out, i, ctypes.byref(kp), ctypes.byref(kn), ctypes.byref(vp), ctypes.byref(vn)))
            hints[_read_view(kp, kn)] = _read_view(vp, vn)
        return Locator(
            field(_lib.pancake_locator_transport),
            field(_lib.pancake_locator_designator),
            field(_lib.pancake_locator_swissnum),
            hints,
        )
    finally:
        _lib.pancake_locator_release(out)


def format_peer_uri(transport: str, designator: str, hints: "Optional[dict[str, str]]" = None) -> str:
    """Format a peer locator as an ``ocapn://<designator>.<transport>[?hints]``
    URI through the core grammar."""
    items = list((hints or {}).items())
    t = transport.encode("utf-8")
    d = designator.encode("utf-8")
    keys = [k.encode("utf-8") for k, _ in items]
    vals = [v.encode("utf-8") for _, v in items]
    n = len(items)
    if n:
        key_arr = (ctypes.c_char_p * n)(*keys)
        val_arr = (ctypes.c_char_p * n)(*vals)
        key_lens = (ctypes.c_size_t * n)(*[len(k) for k in keys])
        val_lens = (ctypes.c_size_t * n)(*[len(v) for v in vals])
        key_ptr = ctypes.cast(key_arr, ctypes.c_void_p)
        val_ptr = ctypes.cast(val_arr, ctypes.c_void_p)
        key_len_ptr = ctypes.cast(key_lens, ctypes.c_void_p)
        val_len_ptr = ctypes.cast(val_lens, ctypes.c_void_p)
    else:
        key_ptr = val_ptr = key_len_ptr = val_len_ptr = None

    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t()
        rc = _lib.pancake_uri_format_peer(
            t, len(t), d, len(d),
            key_ptr, key_len_ptr, val_ptr, val_len_ptr, n,
            buf, cap, ctypes.byref(out_len),
        )
        need = out_len.value
        if rc == _OK:
            return buf.raw[:need].decode("utf-8")
        if rc == _ERR_INVALID_ARGUMENT and need > cap:
            cap = need
            continue
        _check(rc)


class IrohServer:
    """A listening iroh endpoint — the iroh sibling of :class:`Server`.
    Async-iterable (``async for conn in server``) for an accepted
    :class:`Connection` per partner; read :attr:`uri` for the dialable address
    (endpoint id + direct-address hints) to hand a client. ``reachability`` (a
    :class:`Reachability`) is required and sets the endpoint's addressing
    posture — there is no default. Needs the iroh ABI library
    (``zig build iroh-abi``)."""

    def __init__(self, reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None):
        self._netlayer = IrohNetlayer(reachability, secret_seed)
        self._node_id = self._netlayer.node_id()
        self._closed = False

    @property
    def node_id(self) -> str:
        """This endpoint's id — the keyed locator designator and the URI host."""
        return self._node_id

    @property
    def direct_addresses(self) -> str:
        """This endpoint's comma-separated direct-address hints."""
        return self._netlayer.direct_addresses()

    @property
    def uri(self) -> str:
        """The ``ocapn://<nodeid>.iroh?direct-addresses=…`` URI a partner dials."""
        hints = {"direct-addresses": self.direct_addresses} if self.direct_addresses else None
        return format_peer_uri("iroh", self._node_id, hints)

    def __aiter__(self) -> "IrohServer":
        return self

    async def __anext__(self) -> "Connection":
        while True:
            if self._closed:
                raise StopAsyncIteration
            out = ctypes.c_void_p()
            rc = await asyncio.to_thread(
                _iroh().pancake_iroh_netlayer_accept,
                self._netlayer._raw, _codec_id("syrup"), 4096, ctypes.byref(out),
            )
            if rc == _ERR_CLOSED or self._closed:
                raise StopAsyncIteration
            _check_iroh(rc)
            conn = IrohConn(out)
            # A handshake failure belongs to that one connection, never the
            # server — release it and keep accepting.
            try:
                return await Connection._accept_iroh(conn, self._node_id)
            except Exception:
                conn.release()
                continue

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._netlayer.close()
        self._netlayer.release()


def listen_iroh(reachability: "Union[int, Reachability]", secret_seed: "Optional[bytes]" = None) -> IrohServer:
    """Bind an iroh endpoint and return an :class:`IrohServer` you iterate for
    each accepted :class:`Connection`. ``reachability`` (a :class:`Reachability`)
    is required and sets the endpoint's addressing posture — there is no default.
    ``secret_seed`` is a 32-byte Ed25519 secret for a stable endpoint id, or
    ``None`` for a fresh random one. Needs the iroh ABI library
    (``zig build iroh-abi``)."""
    return IrohServer(reachability, secret_seed)


async def connect_iroh(node_id: str, direct_addresses: str, reachability: "Union[int, Reachability]") -> Connection:
    """Dial an iroh partner by endpoint id and direct-address hints — the
    module-level shorthand for :meth:`Connection.connect_iroh`. ``reachability``
    (a :class:`Reachability`) is required and has no default."""
    return await Connection.connect_iroh(node_id, direct_addresses, reachability)


async def connect_uri(uri: str, reachability: "Union[int, Reachability]") -> Connection:
    """Dial a partner from its published ``ocapn://`` URI, dispatching on the
    locator's transport: ``iroh`` dials the endpoint id with its
    ``direct-addresses`` hints, ``tcp`` dials the ``host:port`` designator. The
    transport-agnostic entry point — parse once, the core grammar picks the
    netlayer. ``reachability`` (a :class:`Reachability`) is required and sets the
    iroh dialer's posture — there is no default; the ``tcp`` path ignores it."""
    loc = parse_locator(uri)
    if loc.transport == "iroh":
        return await Connection.connect_iroh(loc.designator, loc.hints.get("direct-addresses", ""), reachability)
    if loc.transport == "tcp":
        host, sep, port = loc.designator.rpartition(":")
        if not sep:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"tcp locator designator is not host:port: {loc.designator}")
        return await Connection.connect(host, int(port))
    raise PancakeError(_ERR_INVALID_ARGUMENT, f'connect_uri: unsupported transport "{loc.transport}"')


async def connect_iroh_uri(uri: str, reachability: "Union[int, Reachability]") -> Connection:
    """Dial an iroh partner from its published ``ocapn://<nodeid>.iroh?…`` URI —
    a thin wrapper over the transport-dispatching :func:`connect_uri`.
    ``reachability`` (a :class:`Reachability`) is required and has no default."""
    return await connect_uri(uri, reachability)
