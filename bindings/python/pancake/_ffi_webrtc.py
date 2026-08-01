"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_webrtc``.

The WebRTC companion library (``libpancake_net_transport_webrtc``, ADR-0089) is
optional -- built only with cargo (``zig build webrtc-abi``) -- so it loads
lazily on first ``_webrtc()`` use and names how to produce it when absent rather
than failing at import. It carries the ``pancake_webrtc_*`` family plus its own
thread-local last-error (``pancake_webrtc_last_error``), symbol-disjoint from the
core. It declares no structs (a peer is an opaque handle), so there is no layout
to pin. Nothing here is public; a higher-level surface would sit over it, the
same way :mod:`pancake.iroh` sits over :mod:`pancake._ffi_iroh`.
"""

from __future__ import annotations

import ctypes

from ._lib_resolve import _lib_file, _lib_path

# The signature table is generated from the archive's annotated symbol inventory
# (``zig build gen-binding-python-ffi``). The webrtc archive keeps its own
# thread-local last-error slot: a webrtc call that returns PANCAKE_ERR_IO records
# its concrete cause there, read through ``pancake_webrtc_last_error`` rather
# than the core ``pancake_last_error``.
from ._sigs_gen import webrtc_sigs
from ._layouts_gen import (
    PANCAKE_WEBRTC_READY_EVENT_EVENTS_OFF,
    PANCAKE_WEBRTC_READY_EVENT_SIZE,
    PANCAKE_WEBRTC_READY_EVENT_SUBJECT_OFF,
)

_WEBRTC_LIB_PATH = _lib_path("pancake_net_transport_webrtc")
_WEBRTC_LIB_FILE = _lib_file("pancake_net_transport_webrtc")


class _WebrtcReadyEvent(ctypes.Structure):
    """One stable peer-id readiness record from the WebRTC endpoint."""

    _fields_ = [("subject", ctypes.c_size_t), ("events", ctypes.c_uint32)]


def _pin_layout() -> None:
    got = ctypes.sizeof(_WebrtcReadyEvent)
    subject_off = _WebrtcReadyEvent.subject.offset
    events_off = _WebrtcReadyEvent.events.offset
    if (
        got != PANCAKE_WEBRTC_READY_EVENT_SIZE
        or subject_off != PANCAKE_WEBRTC_READY_EVENT_SUBJECT_OFF
        or events_off != PANCAKE_WEBRTC_READY_EVENT_EVENTS_OFF
    ):
        raise ImportError(
            "pancake FFI layout drift: _WebrtcReadyEvent "
            f"is {got} bytes (subject@{subject_off}, events@{events_off})"
        )


_pin_layout()


def _load_webrtc():
    lib = ctypes.CDLL(str(_WEBRTC_LIB_PATH))
    for name, (argtypes, restype) in webrtc_sigs(_WebrtcReadyEvent).items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


_webrtc_lib_cache = None


def _webrtc():
    """Open the webrtc ABI library on first use. It is optional -- absent unless
    built with cargo -- so a clear error names how to produce it rather than a
    raw load failure."""
    global _webrtc_lib_cache
    if _webrtc_lib_cache is None:
        try:
            _webrtc_lib_cache = _load_webrtc()
        except OSError as exc:
            raise RuntimeError(
                f"webrtc transport unavailable: could not load {_WEBRTC_LIB_FILE} from "
                "PANCAKE_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system "
                "library path. Build it with `zig build webrtc-abi` (needs cargo). " + str(exc)
            ) from exc
    return _webrtc_lib_cache
