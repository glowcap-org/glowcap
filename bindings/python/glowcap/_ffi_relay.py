"""Internal ctypes loader for ``libglowcap_net_transport_relay``.

The relay archive owns one provider runtime for both keyed-relay and
noise-relay. The generic driver consumes its provider package; this module
does not expose or recreate multiplexed execution.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import require_archive_fingerprint
from ._constants import RELAY_ARCHIVE_FINGERPRINT
from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _Lib, _bind
from ._lib_resolve import _lib_path
from ._pin import pin_struct
from ._sigs_gen import relay_sigs


class _RelayConfig(ctypes.Structure):
    """Mirrors ``GlowcapRelayConfig``; construction borrows every buffer."""

    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("relay_url", ctypes.c_void_p),
        ("relay_url_len", ctypes.c_size_t),
        ("register_url", ctypes.c_void_p),
        ("register_url_len", ctypes.c_size_t),
        ("trust", ctypes.c_uint32),
        ("trust_pem", ctypes.c_void_p),
        ("trust_pem_len", ctypes.c_size_t),
    ]


class _RelayTrustSummary(ctypes.Structure):
    _fields_ = [
        ("loaded", ctypes.c_size_t),
        ("skipped_by_engine", ctypes.c_size_t),
        ("first_skipped_engine_code", ctypes.c_int32),
    ]


pin_struct(_RelayConfig, "GLOWCAP_RELAY_CONFIG")
pin_struct(_RelayTrustSummary, "GLOWCAP_RELAY_TRUST_SUMMARY")


def _load():
    lib = ctypes.CDLL(str(_lib_path("glowcap_net_transport_relay")))
    require_archive_fingerprint(
        lambda: lib.glowcap_relay_archive_fingerprint,
        "relay",
        RELAY_ARCHIVE_FINGERPRINT,
    )
    facade = _Lib(lib)
    _bind(
        facade,
        lib,
        relay_sigs(_RelayConfig, _RelayTrustSummary, _TransportProvider),
    )
    return facade


_relay_lib = _load()
