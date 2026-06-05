"""ctypes bindings for ``libpancake_ffi_net_tcp`` — cleartext + TLS TCP.

Mirrors ``crates/ffi/pancake-ffi-net-tcp/include/pancake_net_tcp.h``. A thin
sync shell over the ``pancake-net-tcp`` core (``std::net`` + Syrup framing).
Two parallel surfaces — cleartext (``tcp_*``) and rustls (``tcp_tls_*``) —
share the lib's own per-library last-error slot; ``read_frame`` hands back a
self-describing ``PancakeManagedFrame`` released via the shared
``pancake_managed_frame_release`` (abi seam).
"""

from __future__ import annotations

import ctypes
from ctypes import POINTER, c_char_p, c_int32, c_size_t, c_uint8, c_uint64, c_void_p

from . import _abi

_P = c_void_p


class NetTcpLib:
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

        # Cleartext TCP.
        fn("pancake_endpoint_tcp_connect", [c_char_p], _P)
        fn("pancake_endpoint_tcp_listen", [c_char_p, c_char_p, c_size_t], _P)
        fn("pancake_endpoint_tcp_accept_timed", [_P, c_uint64, POINTER(_P)], c_int32)
        fn("pancake_endpoint_tcp_set_read_timeout_ms", [_P, c_uint64], c_int32)
        fn(
            "pancake_endpoint_tcp_read_frame",
            [_P, POINTER(_abi.PancakeManagedFrame)],
            c_int32,
        )
        fn("pancake_endpoint_tcp_write_frame", [_P, POINTER(c_uint8), c_size_t], c_int32)
        fn("pancake_endpoint_tcp_conn_close", [_P], None)
        fn("pancake_endpoint_tcp_listener_close", [_P], None)

        # TLS over the same TCP core.
        fn("pancake_endpoint_tcp_tls_connect", [c_char_p], _P)
        fn("pancake_endpoint_tcp_tls_listen", [c_char_p, c_char_p, c_size_t], _P)
        fn("pancake_endpoint_tcp_tls_accept_timed", [_P, c_uint64, POINTER(_P)], c_int32)
        fn("pancake_endpoint_tcp_tls_set_read_timeout_ms", [_P, c_uint64], c_int32)
        fn(
            "pancake_endpoint_tcp_tls_read_frame",
            [_P, POINTER(_abi.PancakeManagedFrame)],
            c_int32,
        )
        fn("pancake_endpoint_tcp_tls_write_frame", [_P, POINTER(c_uint8), c_size_t], c_int32)
        fn("pancake_endpoint_tcp_tls_conn_close", [_P], None)
        fn("pancake_endpoint_tcp_tls_listener_close", [_P], None)


def load() -> NetTcpLib:
    return NetTcpLib(_abi.load_library(_abi.ENV_NET_TCP, "pancake-ffi-net-tcp"))
