"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_inproc``.

The in-process transport ships as its own à-la-carte archive (ADR-0059),
symbol-disjoint from the core ``libpancake_ocapn``: it carries the
``pancake_inproc_*`` family plus its own thread-local last-error
(``pancake_inproc_last_error`` / ``_clear``). It is the socket-free sibling of
the TCP endpoints — two peers in one process wired by in-process pipes, no
kernel transport and no file descriptors — and a listener binds to an opaque
string designator rather than a ``host:port``. This module loads only that
archive, reusing the shared ``Structure`` types from :mod:`pancake._ffi_ocapn` by
layout. Nothing here is public; :mod:`pancake.inproc` is the ergonomic surface
over it.
"""

from __future__ import annotations

import ctypes

from ._ffi_ocapn import _Frame, _Lib, _ManagedFrame, _bind
from ._lib_resolve import _lib_path

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``).
from ._sigs_gen import inproc_sigs


def _load():
    inproc = ctypes.CDLL(str(_lib_path("pancake_net_transport_inproc")))
    facade = _Lib(inproc)
    _bind(facade, inproc, inproc_sigs(_Frame, _ManagedFrame))
    return facade


# Loaded when :mod:`pancake.inproc` is imported, not when the core package is.
_inproc_lib = _load()
