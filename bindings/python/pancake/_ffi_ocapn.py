"""Internal: the raw ``ctypes`` mirror of ``libpancake_ocapn``, the core
archive.

Nothing here is public. The ergonomic surface in :mod:`pancake` reaches the
symbols through ``_lib`` and the ctypes ``Structure`` types this module
defines; a consumer never imports this module. Keeping the ctypes layer in one
internal module per archive is what lets the public package read as just the
connection/value API it offers.

This module loads exactly one archive, ``libpancake_ocapn`` (ADR-0059): the
shared ``pancake_*`` vocabulary — context, the locator grammar, the ABI
version, ``pancake_last_error``, and the managed-frame release. The driver and
transport archives are symbol-disjoint companions, each loaded by its own
internal module (:mod:`pancake._ffi_driver`, :mod:`pancake._ffi_tcp`,
:mod:`pancake._ffi_inproc`, :mod:`pancake._ffi_iroh`). They reuse the
``Structure`` types defined here by *layout* — the same way the C headers
share ``pancake_ocapn.h`` — so importing one transport never loads another.
"""

from __future__ import annotations

import ctypes

# Archive path resolution (configure → abi-versioned cache → zig-out → find)
# lives in ``_lib_resolve`` so every ``_ffi_*`` loader shares one cascade.
from ._lib_resolve import _lib_path

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


# Host allocator callbacks:
#   void *(*alloc)(void *user_data, size_t size, size_t alignment);
#   void  (*free )(void *user_data, void *ptr, size_t size, size_t alignment);
_AllocFn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)
_FreeFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)


class _Allocator(ctypes.Structure):
    _fields_ = [("alloc", _AllocFn), ("free", _FreeFn), ("user_data", ctypes.c_void_p)]


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


def _pin_layout() -> None:
    # The layout gate for the shared cstructs this module declares, at the
    # declaration site (the driver mirror pins its own _HostAction the same
    # way): each mirror is pinned at import time against the LP64 sizes the C
    # headers document, hand-copied here — so the gate catches a mirror that
    # drifts from its documented layout (a mis-swept field, a wrong ctype),
    # not a C-side change that updates neither; the dogfoods defend that
    # behaviorally. A plain `raise` rather than `assert`, so `python -O`
    # cannot strip the gate.
    expected_sizes = (
        (_Reference, 16),
        (_Argument, 72),
        (_Frame, 24),
        (_ManagedFrame, 40),
        (_Allocator, 24),
        (_LastAbort, 56),
    )
    for struct, want in expected_sizes:
        got = ctypes.sizeof(struct)
        if got != want:
            raise ImportError(
                f"pancake FFI layout drift: sizeof({struct.__name__}) == {got}, "
                f"the C headers say {want}; re-mirror the struct"
            )


_pin_layout()


class _Lib:
    """A bound handle to one archive: the package reads ``_lib.pancake_*``
    without holding a raw ``CDLL``. Keeps the loaded ``CDLL`` alive so it is
    never collected while a bound function is still callable."""

    def __init__(self, *handles):
        self._handles = handles


def _bind(facade, lib, sigs):
    """Attach each signature in ``sigs`` to ``facade`` as a bound ctypes
    function read off ``lib``. Shared by every archive's loader."""
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
        setattr(facade, name, fn)


def _read_last_error(fn) -> str | None:
    """Read an archive's thread-local last-error slot into a string, or ``None``
    when empty. ``fn`` is the archive's two-pass C reader ``(buffer, cap) ->
    length``: probe the length with a NULL buffer, then copy into a right-sized
    buffer. Every archive family — core, the driver, the transports — reads its
    own slot through this, so the two-pass discipline lives in one place."""
    length = fn(None, 0)
    if length == 0:
        return None
    # The C side reserves one byte for a NUL and copies at most cap-1 message
    # bytes, so allocate length + 1 to receive all `length` of them.
    buf = (ctypes.c_uint8 * (length + 1))()
    fn(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


def _str_buf(text: str):
    """Encode ``text`` to UTF-8 in a fresh ctypes buffer, returning ``(buf,
    length)``. The buffer is the caller's to keep alive across the synchronous C
    call that borrows it."""
    data = text.encode()
    return ctypes.create_string_buffer(data, len(data)), len(data)


def _byte_buf(data: bytes):
    """A kept-alive ctypes buffer over ``data`` plus its non-null pointer —
    non-null even for empty bytes (a methodless positional send's zero-length
    verb), which the C side would otherwise refuse as a NULL pointer. Returns
    ``(buf, ptr)``; the caller keeps ``buf`` alive across the synchronous C
    call that borrows it. The one borrowed-bytes helper every module shares;
    do not hand-roll ``create_string_buffer`` for a borrowed input."""
    buf = ctypes.create_string_buffer(data if data else b"\0", len(data) or 1)
    return buf, ctypes.cast(buf, ctypes.c_void_p)


def _load():
    P = ctypes.c_void_p
    size_p = ctypes.POINTER(ctypes.c_size_t)
    ocapn_sigs = {
        "pancake_abi_version": (
            [ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)],
            None,
        ),
        "pancake_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_context_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_new_with_allocator": ([ctypes.POINTER(_Allocator), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_release": ([P], None),
        "pancake_managed_frame_release": ([ctypes.POINTER(_ManagedFrame)], None),
        "pancake_encode_peer_locator": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_peer_locator_bytes_release": ([ctypes.c_void_p, ctypes.c_size_t], None),
        # OCapN locator URIs — core libpancake_ocapn vocabulary, so a TCP-only consumer
        # reaches them without the iroh companion library. One grammar, no hand-rolled
        # percent codec. Verbs mint an opaque PancakeLocator; nouns read it.
        "pancake_uri_parse_peer": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_parse_sturdyref": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_format_peer": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_int32,
        ),
        "pancake_locator_transport": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_designator": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_host_port": (
            [P, ctypes.POINTER(ctypes.c_void_p), size_p, ctypes.POINTER(ctypes.c_uint16)], ctypes.c_int32,
        ),
        "pancake_designator_host_port": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p, ctypes.POINTER(ctypes.c_uint16)],
            ctypes.c_int32,
        ),
        "pancake_locator_swissnum": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_hint_count": ([P, size_p], ctypes.c_int32),
        "pancake_locator_hint_at": (
            [P, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_locator_release": ([P], None),
    }
    ocapn = ctypes.CDLL(str(_lib_path("pancake_ocapn")))
    facade = _Lib(ocapn)
    _bind(facade, ocapn, ocapn_sigs)
    return facade


_lib = _load()
