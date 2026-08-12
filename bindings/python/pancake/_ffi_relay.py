"""Internal ctypes loader for ``libpancake_net_transport_relay``.

The relay archive owns one provider runtime for both keyed-relay and
noise-relay. The generic driver consumes its provider package; this module
does not expose or recreate multiplexed execution.
"""

from __future__ import annotations

import ctypes

from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _Lib, _bind
from ._lib_resolve import _lib_path
from ._sigs_gen import relay_sigs


class _RelayConfig(ctypes.Structure):
    """Mirrors ``PancakeRelayConfig``; construction borrows both buffers."""

    _fields_ = [
        ("relay_url", ctypes.c_void_p),
        ("relay_url_len", ctypes.c_size_t),
        ("register_url", ctypes.c_void_p),
        ("register_url_len", ctypes.c_size_t),
    ]


def _load():
    lib = ctypes.CDLL(str(_lib_path("pancake_net_transport_relay")))
    facade = _Lib(lib)
    _bind(facade, lib, relay_sigs(_RelayConfig, _TransportProvider))
    return facade


_relay_lib = _load()
