"""Internal ctypes loader for ``libglowcap_net_transport_relay``.

The relay archive owns one provider runtime for both keyed-relay and
noise-relay. The generic driver consumes its provider package. This module
does not expose or recreate multiplexed execution.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import load_archive
from ._constants import RELAY_ARCHIVE_FINGERPRINT
from ._ffi_driver import _TransportProvider
from ._pin import pin_struct
from ._sigs_gen import relay_sigs


class _RelayConfig(ctypes.Structure):
    """Mirrors ``GlowcapRelayConfig``. Construction borrows every buffer."""

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
        ("relay_alias_url", ctypes.c_void_p),
        ("relay_alias_url_len", ctypes.c_size_t),
    ]


pin_struct(_RelayConfig, "GLOWCAP_RELAY_CONFIG")


_relay_lib = load_archive(
    "glowcap_net_transport_relay",
    lambda lib: lib.glowcap_relay_archive_fingerprint,
    RELAY_ARCHIVE_FINGERPRINT,
    relay_sigs(_RelayConfig, _TransportProvider),
)
