"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_webrtc``.

The WebRTC companion library (``libpancake_net_transport_webrtc``, ADR-0089) is
optional -- built only with cargo (``zig build webrtc-abi``) -- so it loads
lazily on first ``_webrtc()`` use and names how to produce it when absent rather
than failing at import. It carries the ``pancake_webrtc_*`` family plus its own
thread-local last-error (``pancake_webrtc_last_error``), symbol-disjoint from the
core. The endpoint config and readiness record are pinned to generated ABI
layouts; peers remain opaque handles. Nothing here is public; a higher-level surface would sit over it, the
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
from ._pin import pin_struct
from ._ffi_driver import _TransportProvider

_WEBRTC_LIB_PATH = _lib_path("pancake_net_transport_webrtc")
_WEBRTC_LIB_FILE = _lib_file("pancake_net_transport_webrtc")


class _WebrtcReadyEvent(ctypes.Structure):
    """One stable peer-id readiness record from the WebRTC endpoint."""

    _fields_ = [("subject", ctypes.c_size_t), ("events", ctypes.c_uint32)]


pin_struct(_WebrtcReadyEvent, "PANCAKE_WEBRTC_READY_EVENT")


class _WebrtcConfig(ctypes.Structure):
    """One WebRTC endpoint's configuration; see the header's
    ``PancakeWebrtcConfig`` for what each setting means. Zero-initialized by
    ``ctypes.Structure``, and an unset field takes the transport's default."""

    _fields_ = [
        ("ice_servers", ctypes.POINTER(ctypes.c_uint8)),
        ("ice_servers_len", ctypes.c_size_t),
        ("include_loopback_candidates", ctypes.c_uint32),
        ("worker_threads", ctypes.c_uint32),
    ]


pin_struct(_WebrtcConfig, "PANCAKE_WEBRTC_CONFIG")


def _load_webrtc():
    lib = ctypes.CDLL(str(_WEBRTC_LIB_PATH))
    for name, (argtypes, restype) in webrtc_sigs(
        _WebrtcReadyEvent, _WebrtcConfig, _TransportProvider
    ).items():
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
