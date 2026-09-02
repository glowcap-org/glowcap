"""Internal: the raw ``ctypes`` loader for ``libglowcap_net_transport_iroh``.

The iroh companion library (``libglowcap_net_transport_iroh``, ADR-0055) is
optional — built only with cargo (``zig build iroh-abi``) — so it loads lazily on
first ``_iroh()`` use and names how to produce it when absent rather than failing
at import. It carries the ``glowcap_iroh_*`` family plus its own thread-local
last-error (``glowcap_iroh_last_error``), symbol-disjoint from the
core. Nothing here is public; :mod:`glowcap.iroh` is the ergonomic surface over
it. The read/write calls move frames through the shared ctypes ``Structure``
types from :mod:`glowcap._ffi_ocapn`.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import require_archive_fingerprint
from ._constants import IROH_ARCHIVE_FINGERPRINT
from ._ffi_driver import _TransportProvider
from ._pin import pin_struct
from ._lib_resolve import _lib_file, _lib_path

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``). The iroh archive keeps its
# own thread-local last-error slot: an iroh call that returns GLOWCAP_ERR_IO
# records its concrete cause there, read through ``glowcap_iroh_last_error``
# rather than the core ``glowcap_last_error``.
from ._sigs_gen import iroh_sigs

_IROH_LIB_PATH = _lib_path("glowcap_net_transport_iroh")
_IROH_LIB_FILE = _lib_file("glowcap_net_transport_iroh")


class _IrohReadyEvent(ctypes.Structure):
    """One readiness record drained by ``glowcap_iroh_netlayer_drain_ready``, the
    ``extern struct`` counterpart of the header's ``GlowcapIrohReadyEvent``.
    ``subject`` is zero for accept, a request id for connect completion, and a
    connection handle for stream readiness."""

    _fields_ = [("subject", ctypes.c_size_t), ("events", ctypes.c_uint32)]


class _IrohConfig(ctypes.Structure):
    """One iroh endpoint's config, the ``extern struct`` counterpart of the
    header's ``GlowcapIrohConfig``. ``ctypes.Structure`` zero-initializes every
    field, so filling only ``reachability`` leaves ``connect_timeout_ms`` (and
    any field a future version adds) at 0 — the header's zero-init contract."""

    _fields_ = [
        ("reachability", ctypes.c_uint32),
        ("connect_timeout_ms", ctypes.c_uint64),
        ("idle_timeout_ms", ctypes.c_uint64),
        ("worker_threads", ctypes.c_uint32),
    ]


# The layout gate at the declaration site, the same import-time pin every
# other _ffi_* module runs for its own mirrors.
pin_struct(_IrohReadyEvent, "GLOWCAP_IROH_READY_EVENT")
pin_struct(_IrohConfig, "GLOWCAP_IROH_CONFIG")


def _load_iroh():
    lib = ctypes.CDLL(str(_IROH_LIB_PATH))
    require_archive_fingerprint(
        lambda: lib.glowcap_iroh_archive_fingerprint,
        "iroh",
        IROH_ARCHIVE_FINGERPRINT,
    )
    for name, (argtypes, restype) in iroh_sigs(
        _IrohReadyEvent, _IrohConfig, _TransportProvider
    ).items():
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
                "GLOWCAP_LIB_DIR, the abi-versioned cache, zig-out/lib, or the system "
                "library path. Build it with `zig build iroh-abi` (needs cargo). "
                + str(exc)
            ) from exc
    return _iroh_lib_cache
