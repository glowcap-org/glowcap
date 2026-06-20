"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_tcp``.

The TCP transport ships as its own à-la-carte archive (ADR-0059), symbol-disjoint
from the core ``libpancake_ocapn``: it carries the ``pancake_tcp_*`` family plus
its own thread-local last-error (``pancake_tcp_last_error`` / ``_clear``). This
module loads only that archive, reusing the shared ``Structure`` types from
:mod:`pancake._ffi_core` by layout, so importing :mod:`pancake.tcp` adds the TCP
archive on top of the core without pulling in any other transport. Nothing here
is public; :mod:`pancake.tcp` is the ergonomic surface over it.
"""

from __future__ import annotations

import ctypes

from ._ffi_core import _Frame, _Lib, _ManagedFrame, _bind, _lib_path


def _load():
    P = ctypes.c_void_p
    # The TCP transport archive carries the `pancake_tcp_*` family plus its own
    # thread-local last-error: a tcp call's diagnostic is read through
    # `pancake_tcp_last_error`, never the core family's `pancake_last_error`.
    tcp_sigs = {
        "pancake_tcp_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_tcp_clear_last_error": ([], None),
        "pancake_tcp_netlayer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_release": ([P], None),
        "pancake_tcp_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_tcp_listen": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.POINTER(P)], ctypes.c_int32,
        ),
        "pancake_tcp_listener_port": ([P, ctypes.POINTER(ctypes.c_uint16)], ctypes.c_int32),
        "pancake_tcp_accept": ([P, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_conn_read_frame": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_tcp_conn_write_frame": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_tcp_conn_release": ([P], None),
        "pancake_tcp_listener_release": ([P], None),
    }
    tcp = ctypes.CDLL(str(_lib_path("pancake_net_transport_tcp")))
    facade = _Lib(tcp)
    _bind(facade, tcp, tcp_sigs)
    return facade


# Loaded when :mod:`pancake.tcp` is imported, not when the core package is.
_tcp_lib = _load()
