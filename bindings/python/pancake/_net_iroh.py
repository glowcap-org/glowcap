"""ctypes bindings for ``libpancake_ffi_net_iroh`` — QUIC-over-iroh.

Mirrors ``crates/ffi/pancake-ffi-net-iroh/include/pancake_net_iroh.h``. The
endpoint is constructed standalone (UDP auto-bound; no host:port), addressed
by a base32 ``EndpointId``, and dialed by ``EndpointId`` plus an optional
direct ``host:port`` hint (loopback without discovery). ``read_frame`` hands
back a self-describing ``PancakeManagedFrame`` released via the shared
``pancake_managed_frame_release`` (abi seam); failures read from its own
last-error slot.
"""

from __future__ import annotations

import ctypes
from ctypes import POINTER, c_char_p, c_int32, c_size_t, c_uint8, c_uint64, c_void_p

from . import _abi

_P = c_void_p

# 64 base32 chars + NUL fits in 65.
IROH_ID_CAP = 65


class NetIrohLib:
    def __init__(self, lib: ctypes.CDLL):
        self.lib = lib
        self.last_error, self.clear_last_error = _abi.bind_last_error(lib)
        self._bind()

    def _bind(self) -> None:
        lib = self.lib

        def fn(name, argtypes, restype):
            f = getattr(lib, name)
            f.argtypes = argtypes
            f.restype = restype
            setattr(self, name, f)

        # Shared abi-seam release for managed read frames.
        fn("pancake_managed_frame_release", [POINTER(_abi.PancakeManagedFrame)], None)

        fn("pancake_endpoint_iroh_new", [], _P)
        fn("pancake_endpoint_iroh_endpoint_id", [_P, c_char_p, c_size_t], c_int32)
        fn("pancake_endpoint_iroh_bound_addr", [_P, c_char_p, c_size_t], c_int32)
        fn("pancake_endpoint_iroh_connect", [_P, c_char_p, c_char_p], _P)
        fn("pancake_endpoint_iroh_listen", [_P], _P)
        fn("pancake_endpoint_iroh_accept_timed", [_P, c_uint64, POINTER(_P)], c_int32)
        fn("pancake_endpoint_iroh_set_read_timeout_ms", [_P, c_uint64], c_int32)
        fn(
            "pancake_endpoint_iroh_read_frame",
            [_P, POINTER(_abi.PancakeManagedFrame)],
            c_int32,
        )
        fn("pancake_endpoint_iroh_write_frame", [_P, POINTER(c_uint8), c_size_t], c_int32)
        fn("pancake_endpoint_iroh_conn_close", [_P], None)
        fn("pancake_endpoint_iroh_listener_close", [_P], None)
        fn("pancake_endpoint_iroh_close", [_P], None)


def load() -> NetIrohLib:
    return NetIrohLib(_abi.load_library(_abi.ENV_NET_IROH, "pancake-ffi-net-iroh"))
