"""Internal: the raw ``ctypes`` loader for ``libglowcap_net_transport_onion``.

The onion transport ships as its own à-la-carte archive (ADR-0022),
symbol-disjoint from the core ``libglowcap_ocapn``: it carries the
``glowcap_onion_*`` family plus its own thread-local last-error
(``glowcap_onion_last_error`` / ``_clear``). It reaches a Tor daemon the
deployment already runs, over that daemon's SOCKS endpoint to dial and its
control endpoint to host. glowcap starts none. This module loads only that
archive, reusing the shared ``Structure`` types from :mod:`glowcap._ffi_ocapn` by
layout. Nothing here is public. :mod:`glowcap.onion` is the ergonomic surface
over it.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import require_archive_fingerprint
from ._constants import ONION_ARCHIVE_FINGERPRINT
from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _bind, _Frame, _Lib, _ManagedFrame
from ._lib_resolve import _lib_path
from ._pin import pin_struct

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``).
from ._sigs_gen import onion_sigs


class _OnionConfig(ctypes.Structure):
    """Mirrors ``GlowcapOnionConfig``, whose Zig declaration in
    ``src/c_abi/net_transport/onion/contract.zig`` documents every field.

    Zero-initialize and set what you use: ``ctypes`` zeroes a fresh instance, which
    is what makes a field added later read as absent rather than as stack contents.
    Every pointer is borrowed for the constructor call only, because the netlayer
    copies the text it needs.
    """

    _fields_ = [
        ("socks", ctypes.c_void_p),
        ("socks_len", ctypes.c_size_t),
        ("control_endpoint", ctypes.c_void_p),
        ("control_endpoint_len", ctypes.c_size_t),
        ("auth_kind", ctypes.c_uint32),
        ("auth_secret", ctypes.c_void_p),
        ("auth_secret_len", ctypes.c_size_t),
        ("service_key", ctypes.c_void_p),
        ("service_key_len", ctypes.c_size_t),
        ("forward", ctypes.c_void_p),
        ("forward_len", ctypes.c_size_t),
    ]


pin_struct(_OnionConfig, "GLOWCAP_ONION_CONFIG")


def _load():
    onion = ctypes.CDLL(str(_lib_path("glowcap_net_transport_onion")))
    require_archive_fingerprint(
        lambda: onion.glowcap_onion_archive_fingerprint,
        "onion",
        ONION_ARCHIVE_FINGERPRINT,
    )
    facade = _Lib(onion)
    _bind(
        facade,
        onion,
        onion_sigs(_Frame, _ManagedFrame, _OnionConfig, _TransportProvider),
    )
    return facade


# Loaded when :mod:`glowcap.onion` is imported, not when the core package is.
_onion_lib = _load()
