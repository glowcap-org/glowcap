"""Internal: the raw ``ctypes`` loader for ``libglowcap_net_transport_inproc``.

This module loads only that archive. It carries the ``glowcap_inproc_*``
family plus its own thread-local last-error
(``glowcap_inproc_last_error`` / ``_clear``). The transport is the socket-free
sibling of the TCP connections, two peers in one process wired by in-process
pipes, with no kernel transport. The listener wake descriptor carries no
application bytes, and a listener binds to an opaque string designator rather
than a ``host:port``. It reuses the shared ``Structure`` types from
:mod:`glowcap._ffi_ocapn` by layout. Nothing here is public.
:mod:`glowcap.inproc` is the ergonomic surface over it.
"""

from __future__ import annotations

from ._archive_contract import load_archive
from ._constants import INPROC_ARCHIVE_FINGERPRINT
from ._ffi_ocapn import _Frame, _ManagedFrame

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``).
from ._sigs_gen import inproc_sigs

# Loaded when :mod:`glowcap.inproc` is imported, not when the core package is.
_inproc_lib = load_archive(
    "glowcap_net_transport_inproc",
    lambda lib: lib.glowcap_inproc_archive_fingerprint,
    INPROC_ARCHIVE_FINGERPRINT,
    inproc_sigs(_Frame, _ManagedFrame),
)
