"""Internal: the raw ``ctypes`` mirror of ``libglowcap_ocapn``, the core
archive.

Nothing here is public. The ergonomic surface in :mod:`glowcap` reaches the
symbols through ``_lib`` and the ctypes ``Structure`` types this module
defines. A consumer never imports this module. Keeping the ctypes layer in one
internal module per archive is what lets the public package read as just the
connection/value API it offers.

This module loads one archive, ``libglowcap_ocapn``: the shared
``glowcap_*`` vocabulary: context, the locator grammar, the ABI version,
``glowcap_last_error``, and the managed-frame release. The host, driver, and
transport archives are loaded by their own internal modules
(:mod:`glowcap._ffi_host`, :mod:`glowcap._ffi_tcp`, :mod:`glowcap._ffi_inproc`,
:mod:`glowcap._ffi_iroh`). They reuse the ``Structure`` types defined here by
*layout*, the same way the C headers share ``glowcap_ocapn.h``.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import load_archive
from ._constants_gen import FRAME_SHAPE_BYTE, OCAPN_ARCHIVE_FINGERPRINT

# Archive path resolution (configure → abi-versioned cache → zig-out → find)
# lives in ``_lib_resolve`` so every ``_ffi_*`` loader shares one cascade.
# The layout gate for the hand-mirrored ctypes.Structure types below, held
# against sizes and offsets reflected off the real Zig C ABI types
# (``zig build gen-binding-ffi-layouts``).
from ._pin import pin_struct

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``); this module hands it the
# ``Structure`` types it declares below.
from ._sigs_gen import ocapn_sigs

# ── Raw ctypes layer (private) ───────────────────────────────────────────────


class _BreakCause(ctypes.Structure):
    _fields_ = [("origin", ctypes.c_uint32), ("reason", ctypes.c_uint32), ("context", ctypes.c_uint32)]


class _Reference(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint64)]


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
        ("private_words", ctypes.c_size_t * 8),
    ]


class _LocatorHintView(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_void_p),
        ("name_len", ctypes.c_size_t),
        ("kind", ctypes.c_uint32),
        ("bytes", ctypes.c_void_p),
        ("bytes_len", ctypes.c_size_t),
        ("boolean_value", ctypes.c_uint8),
        ("integer_value", ctypes.c_int64),
    ]


class _LocatorView(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("transport", ctypes.c_void_p),
        ("transport_len", ctypes.c_size_t),
        ("designator", ctypes.c_void_p),
        ("designator_len", ctypes.c_size_t),
        ("hints", ctypes.POINTER(_LocatorHintView)),
        ("hint_count", ctypes.c_size_t),
        ("hint_wire_form", ctypes.c_uint32),
    ]


# Host allocator callbacks:
#   void *(*alloc)(void *user_data, size_t size, size_t alignment);
#   void  (*free )(void *user_data, void *ptr, size_t size, size_t alignment);
_AllocFn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)
_FreeFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)


class _Allocator(ctypes.Structure):
    _fields_ = [("alloc", _AllocFn), ("free", _FreeFn), ("user_data", ctypes.c_void_p)]


class _FailureReport(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("layer", ctypes.c_uint32),
        ("scope_kind", ctypes.c_uint32),
        ("scope_id", ctypes.c_uint64),
        ("operation_id", ctypes.c_uint64),
        ("primary_result", ctypes.c_int32),
        ("secondary_result", ctypes.c_int32),
        ("secondary_count", ctypes.c_uint32),
        ("operation", ctypes.c_void_p),
        ("operation_len", ctypes.c_size_t),
        ("primary_name", ctypes.c_void_p),
        ("primary_name_len", ctypes.c_size_t),
        ("primary_message", ctypes.c_void_p),
        ("primary_message_len", ctypes.c_size_t),
        ("secondary_name", ctypes.c_void_p),
        ("secondary_name_len", ctypes.c_size_t),
        ("secondary_message", ctypes.c_void_p),
        ("secondary_message_len", ctypes.c_size_t),
    ]


class _FailureEvent(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("sequence", ctypes.c_uint64),
        ("dropped_before", ctypes.c_uint64),
        ("layer", ctypes.c_uint32),
        ("scope_kind", ctypes.c_uint32),
        ("scope_id", ctypes.c_uint64),
        ("operation_id", ctypes.c_uint64),
        ("primary_result", ctypes.c_int32),
        ("secondary_result", ctypes.c_int32),
        ("secondary_count", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("operation", ctypes.c_void_p),
        ("operation_len", ctypes.c_size_t),
        ("primary_name", ctypes.c_void_p),
        ("primary_name_len", ctypes.c_size_t),
        ("primary_message", ctypes.c_void_p),
        ("primary_message_len", ctypes.c_size_t),
        ("secondary_name", ctypes.c_void_p),
        ("secondary_name_len", ctypes.c_size_t),
        ("secondary_message", ctypes.c_void_p),
        ("secondary_message_len", ctypes.c_size_t),
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
        ("abort_delivery_error_name", ctypes.c_void_p),
        ("abort_delivery_error_name_len", ctypes.c_size_t),
        ("secondary_error_name", ctypes.c_void_p),
        ("secondary_error_name_len", ctypes.c_size_t),
        ("secondary_error_count", ctypes.c_uint32),
    ]


# The layout gate for the shared mirrors this module declares, at the
# declaration site (every other _ffi_* module pins its own the same way).
pin_struct(_BreakCause, "GLOWCAP_BREAK_CAUSE")
pin_struct(_Reference, "GLOWCAP_REFERENCE")
pin_struct(_Argument, "GLOWCAP_ARGUMENT")
pin_struct(_Frame, "GLOWCAP_FRAME")
pin_struct(_ManagedFrame, "GLOWCAP_MANAGED_FRAME")
pin_struct(_LocatorHintView, "GLOWCAP_LOCATOR_HINT_VIEW")
pin_struct(_LocatorView, "GLOWCAP_LOCATOR_VIEW")
pin_struct(_Allocator, "GLOWCAP_ALLOCATOR")
pin_struct(_FailureReport, "GLOWCAP_FAILURE_REPORT")
pin_struct(_FailureEvent, "GLOWCAP_FAILURE_EVENT")
pin_struct(_LastAbort, "GLOWCAP_LAST_ABORT")


def _read_last_error(fn) -> str | None:
    """Read an archive's thread-local last-error slot into a string, or ``None``
    when empty. ``fn`` is the archive's two-pass C reader ``(buffer, cap) ->
    length``: probe the length with a NULL buffer, then copy into a right-sized
    buffer. Every archive family, core, the driver, the transports, reads its
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
    """Encode ``text`` to UTF-8, returning ``(owner, length)``. The owner keeps
    the bytes live across the synchronous C call that borrows it."""
    data = text.encode()
    owner, _ptr = _borrowed_byte_ptr(data)
    return owner, len(data)


def _byte_buf(data: bytes):
    """Borrow ``data`` as a non-null pointer for one synchronous C call."""
    return _borrowed_byte_ptr(data)


def _borrowed_byte_ptr(data: bytes) -> tuple[ctypes.c_char_p, ctypes.c_void_p]:
    owner = ctypes.c_char_p(data)
    return owner, ctypes.cast(owner, ctypes.c_void_p)


def _borrowed_byte_frame(data: bytes) -> tuple[_Frame, ctypes.c_char_p]:
    """Borrow a byte-shaped frame for one synchronous C call."""
    owner, ptr = _borrowed_byte_ptr(data)
    return _Frame(ptr, len(data), FRAME_SHAPE_BYTE), owner


_lib = load_archive(
    "glowcap_ocapn",
    lambda lib: lib.glowcap_ocapn_archive_fingerprint,
    OCAPN_ARCHIVE_FINGERPRINT,
    ocapn_sigs(_Allocator, _ManagedFrame, _LocatorHintView, _LocatorView, _FailureReport, _FailureEvent),
)


def _copy_managed_frame(frame: _ManagedFrame) -> bytes:
    """Copy one C-owned managed frame and release it on every Python outcome."""
    try:
        return ctypes.string_at(frame.bytes, frame.len) if frame.bytes else b""
    finally:
        _lib.glowcap_managed_frame_release(ctypes.byref(frame))
