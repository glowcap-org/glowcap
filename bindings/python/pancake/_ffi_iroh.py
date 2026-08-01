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
    PANCAKE_IROH_READY_EVENT_SUBJECT_OFF,
    PANCAKE_IROH_READY_EVENT_EVENTS_OFF,
    PANCAKE_IROH_READY_EVENT_SIZE,
)
from ._lib_resolve import _lib_file, _lib_path

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``). The iroh archive keeps its
# own thread-local last-error slot: an iroh call that returns PANCAKE_ERR_IO
# records its concrete cause there, read through ``pancake_iroh_last_error``
# rather than the core ``pancake_last_error``.
from ._sigs_gen import iroh_sigs

_IROH_LIB_PATH = _lib_path("pancake_net_transport_iroh")
_IROH_LIB_FILE = _lib_file("pancake_net_transport_iroh")

class _IrohReadyEvent(ctypes.Structure):
    """One readiness record drained by ``pancake_iroh_netlayer_drain_ready``, the
    ``extern struct`` counterpart of the header's ``PancakeIrohReadyEvent``.
    ``subject`` is zero for accept, a request id for connect completion, and a
    connection handle for stream readiness."""

    _fields_ = [("subject", ctypes.c_size_t), ("events", ctypes.c_uint32)]


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
    subject_off = _IrohReadyEvent.subject.offset
    events_off = _IrohReadyEvent.events.offset
    if (
        got != PANCAKE_IROH_READY_EVENT_SIZE
        or subject_off != PANCAKE_IROH_READY_EVENT_SUBJECT_OFF
        or events_off != PANCAKE_IROH_READY_EVENT_EVENTS_OFF
    ):
        raise ImportError(
            f"pancake FFI layout drift: _IrohReadyEvent is {got} bytes "
            f"(subject@{subject_off}, events@{events_off}); expected "
            f"{PANCAKE_IROH_READY_EVENT_SIZE} bytes with "
            f"subject@{PANCAKE_IROH_READY_EVENT_SUBJECT_OFF}, "
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
    for name, (argtypes, restype) in iroh_sigs(_IrohReadyEvent, _IrohConfig).items():
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
