"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_iroh``.

The iroh companion library (``libpancake_net_transport_iroh``, ADR-0055) is
optional — built only with cargo (``zig build iroh-abi``) — so it loads lazily on
first ``_iroh()`` use and names how to produce it when absent rather than failing
at import. It carries the ``pancake_iroh_*`` family plus its own thread-local
last-error (``pancake_iroh_last_error``), symbol-disjoint from the
core. Nothing here is public; :mod:`pancake.iroh` is the ergonomic surface over
it. The read/write calls move frames through the shared ctypes ``Structure``
types from :mod:`pancake._ffi_ocapn`.
"""

from __future__ import annotations

import ctypes

from ._ffi_ocapn import _lib_file, _lib_path

_IROH_LIB_PATH = _lib_path("pancake_net_transport_iroh")
_IROH_LIB_FILE = _lib_file("pancake_net_transport_iroh")

# Readiness event bits (the header's PANCAKE_IROH_EV_*), carried by a
# `drain_ready` record. A record may carry several at once.
_IROH_EV_READABLE = 1
_IROH_EV_WRITABLE = 2
_IROH_EV_CLOSED = 4
_IROH_EV_ACCEPT = 8


class _IrohReadyEvent(ctypes.Structure):
    """One readiness record drained by ``pancake_iroh_netlayer_drain_ready``, the
    ``extern struct`` counterpart of the header's ``PancakeIrohReadyEvent``.
    ``conn`` is the ready connection's handle (``None`` for an accept record,
    claimed with ``try_accept``) and ``events`` the ``_IROH_EV_*`` bitset."""

    _fields_ = [("conn", ctypes.c_void_p), ("events", ctypes.c_uint32)]


def _pin_layout() -> None:
    # The layout gate at the declaration site, the same import-time pin
    # _ffi_ocapn._pin_layout runs for the shared cstructs: the header's
    # PancakeIrohReadyEvent is {PancakeIrohConn *conn; uint32_t events;} — 16
    # bytes on LP64, conn at offset 0, events at 8 (4 bytes of tail padding).
    # A plain `raise` rather than `assert`, so `python -O` cannot strip it.
    got = ctypes.sizeof(_IrohReadyEvent)
    conn_off = _IrohReadyEvent.conn.offset
    events_off = _IrohReadyEvent.events.offset
    if got != 16 or conn_off != 0 or events_off != 8:
        raise ImportError(
            f"pancake FFI layout drift: _IrohReadyEvent is {got} bytes "
            f"(conn@{conn_off}, events@{events_off}); the C header says 16 "
            "bytes with conn@0, events@8; re-mirror the struct"
        )


_pin_layout()


def _load_iroh():
    lib = ctypes.CDLL(str(_IROH_LIB_PATH))
    P = ctypes.c_void_p
    u8p = ctypes.POINTER(ctypes.c_uint8)
    size_p = ctypes.POINTER(ctypes.c_size_t)
    ev_p = ctypes.POINTER(_IrohReadyEvent)
    sigs = {
        "pancake_iroh_netlayer_new": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_netlayer_close": ([P], None),
        "pancake_iroh_netlayer_release": ([P], None),
        "pancake_iroh_netlayer_node_id": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        "pancake_iroh_netlayer_direct_addrs": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        # The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
        # Park on the readiness fd, drain records when it signals, and drive
        # non-blocking byte I/O, one thread serves many connections.
        "pancake_iroh_netlayer_readiness_fd": ([P], ctypes.c_int32),
        "pancake_iroh_netlayer_drain_ready": ([P, ev_p, ctypes.c_size_t], ctypes.c_ssize_t),
        "pancake_iroh_netlayer_try_accept": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_netlayer_try_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_iroh_conn_try_read": ([P, u8p, ctypes.c_size_t], ctypes.c_ssize_t),
        "pancake_iroh_conn_try_write": ([P, u8p, ctypes.c_size_t], ctypes.c_ssize_t),
        "pancake_iroh_conn_release": ([P], None),
        # The iroh archive's own thread-local last-error slot: an iroh call that
        # returns PANCAKE_ERR_IO records its concrete cause here, read through
        # `pancake_iroh_last_error` rather than the core `pancake_last_error`.
        "pancake_iroh_last_error": ([u8p, ctypes.c_size_t], ctypes.c_size_t),
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
