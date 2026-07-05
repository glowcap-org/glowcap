"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_inproc``.

The in-process transport ships as its own à-la-carte archive (ADR-0059),
symbol-disjoint from the core ``libpancake_ocapn``: it carries the
``pancake_inproc_*`` family plus its own thread-local last-error
(``pancake_inproc_last_error`` / ``_clear``). It is the socket-free sibling of
the TCP endpoints — two peers in one process wired by in-process pipes, no
kernel transport and no file descriptors — and a listener binds to an opaque
string designator rather than a ``host:port``. This module loads only that
archive, reusing the shared ``Structure`` types from :mod:`pancake._ffi_core` by
layout. Nothing here is public; :mod:`pancake.inproc` is the ergonomic surface
over it.
"""

from __future__ import annotations

import ctypes

from ._ffi_core import _Frame, _Lib, _ManagedFrame, _bind, _lib_path


def _load():
    P = ctypes.c_void_p
    inproc_sigs = {
        "pancake_inproc_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_inproc_netlayer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_inproc_netlayer_release": ([P], None),
        "pancake_inproc_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_inproc_listen": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32,
        ),
        "pancake_inproc_accept": ([P, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_inproc_conn_read_frame": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_inproc_conn_write_frame": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_inproc_conn_release": ([P], None),
        "pancake_inproc_listener_release": ([P], None),
    }
    inproc = ctypes.CDLL(str(_lib_path("pancake_net_transport_inproc")))
    facade = _Lib(inproc)
    _bind(facade, inproc, inproc_sigs)
    return facade


# Loaded when :mod:`pancake.inproc` is imported, not when the core package is.
_inproc_lib = _load()
