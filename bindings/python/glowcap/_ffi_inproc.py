"""Internal: the raw ``ctypes`` loader for ``libglowcap_net_transport_inproc``.

The in-process transport ships as its own à-la-carte archive (ADR-0022),
symbol-disjoint from the core ``libglowcap_ocapn``: it carries the
``glowcap_inproc_*`` family plus its own thread-local last-error
(``glowcap_inproc_last_error`` / ``_clear``). It is the socket-free sibling of
the TCP connections, two peers in one process wired by in-process pipes, with no
kernel transport. The listener wake descriptor carries no application bytes,
and a listener binds to an opaque
string designator rather than a ``host:port``. This module loads only that
archive, reusing the shared ``Structure`` types from :mod:`glowcap._ffi_ocapn` by
layout. Nothing here is public. :mod:`glowcap.inproc` is the ergonomic surface
over it.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import require_archive_fingerprint
from ._constants import INPROC_ARCHIVE_FINGERPRINT
from ._ffi_ocapn import _Frame, _Lib, _ManagedFrame, _bind
from ._lib_resolve import _lib_path

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``).
from ._sigs_gen import inproc_sigs


def _load():
    inproc = ctypes.CDLL(str(_lib_path("glowcap_net_transport_inproc")))
    require_archive_fingerprint(
        lambda: inproc.glowcap_inproc_archive_fingerprint,
        "inproc",
        INPROC_ARCHIVE_FINGERPRINT,
    )
    facade = _Lib(inproc)
    _bind(facade, inproc, inproc_sigs(_Frame, _ManagedFrame))
    return facade


# Loaded when :mod:`glowcap.inproc` is imported, not when the core package is.
_inproc_lib = _load()
