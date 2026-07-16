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

from ._layouts_gen import (
    PANCAKE_IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF,
    PANCAKE_IROH_CONFIG_REACHABILITY_OFF,
    PANCAKE_IROH_CONFIG_SIZE,
    PANCAKE_IROH_READY_EVENT_CONN_OFF,
    PANCAKE_IROH_READY_EVENT_EVENTS_OFF,
    PANCAKE_IROH_READY_EVENT_SIZE,
)
from ._lib_resolve import _lib_file, _lib_path

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


class _IrohConfig(ctypes.Structure):
    """One iroh endpoint's config, the ``extern struct`` counterpart of the
    header's ``PancakeIrohConfig``. ``ctypes.Structure`` zero-initializes every
    field, so filling only ``reachability`` leaves ``connect_timeout_ms`` (and
    any field a future version adds) at 0 — the header's zero-init contract."""

    _fields_ = [("reachability", ctypes.c_uint32), ("connect_timeout_ms", ctypes.c_uint64)]


def _pin_layout() -> None:
    # The layout gate at the declaration site, the same import-time pin
    # _ffi_ocapn._pin_layout runs for the shared cstructs: pinned against the
    # size and offsets `_layouts_gen` reflects off the real Zig
    # PancakeIrohReadyEvent. A plain `raise` rather than `assert`, so
    # `python -O` cannot strip it.
    got = ctypes.sizeof(_IrohReadyEvent)
    conn_off = _IrohReadyEvent.conn.offset
    events_off = _IrohReadyEvent.events.offset
    if (
        got != PANCAKE_IROH_READY_EVENT_SIZE
        or conn_off != PANCAKE_IROH_READY_EVENT_CONN_OFF
        or events_off != PANCAKE_IROH_READY_EVENT_EVENTS_OFF
    ):
        raise ImportError(
            f"pancake FFI layout drift: _IrohReadyEvent is {got} bytes "
            f"(conn@{conn_off}, events@{events_off}); expected "
            f"{PANCAKE_IROH_READY_EVENT_SIZE} bytes with "
            f"conn@{PANCAKE_IROH_READY_EVENT_CONN_OFF}, "
            f"events@{PANCAKE_IROH_READY_EVENT_EVENTS_OFF}; re-mirror the struct"
        )
    config_size = ctypes.sizeof(_IrohConfig)
    reachability_off = _IrohConfig.reachability.offset
    timeout_off = _IrohConfig.connect_timeout_ms.offset
    if (
        config_size != PANCAKE_IROH_CONFIG_SIZE
        or reachability_off != PANCAKE_IROH_CONFIG_REACHABILITY_OFF
        or timeout_off != PANCAKE_IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF
    ):
        raise ImportError(
            f"pancake FFI layout drift: _IrohConfig is {config_size} bytes "
            f"(reachability@{reachability_off}, connect_timeout_ms@{timeout_off}); "
            f"expected {PANCAKE_IROH_CONFIG_SIZE} bytes with "
            f"reachability@{PANCAKE_IROH_CONFIG_REACHABILITY_OFF}, "
            f"connect_timeout_ms@{PANCAKE_IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF}; "
            "re-mirror the struct"
        )


_pin_layout()


def _load_iroh():
    lib = ctypes.CDLL(str(_IROH_LIB_PATH))
    P = ctypes.c_void_p
    u8p = ctypes.POINTER(ctypes.c_uint8)
    size_p = ctypes.POINTER(ctypes.c_size_t)
    ev_p = ctypes.POINTER(_IrohReadyEvent)
    sigs = {
        "pancake_iroh_netlayer_new": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(_IrohConfig), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_netlayer_close": ([P], None),
        "pancake_iroh_netlayer_release": ([P], None),
        "pancake_iroh_netlayer_node_id": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        "pancake_iroh_netlayer_direct_addrs": ([P, u8p, ctypes.c_size_t, size_p], ctypes.c_int32),
        # The event-driven loop surface (ADR-0057): the netlayer's one I/O model.
        # Park on the readiness fd, drain records when it signals, and drive
        # non-blocking byte I/O, one thread serves many connections.
        "pancake_iroh_netlayer_readiness_fd": ([P], ctypes.c_int32),
        "pancake_iroh_netlayer_drain_ready": ([P, ev_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "pancake_iroh_netlayer_try_accept": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_iroh_netlayer_try_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_iroh_conn_try_read": ([P, u8p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "pancake_iroh_conn_try_write": ([P, u8p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
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
                f"iroh transport unavailable: could not load {_IROH_LIB_FILE} from "
                "PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system "
                "library path. Build it with `zig build iroh-abi` (needs cargo). " + str(exc)
            ) from exc
    return _iroh_lib_cache
