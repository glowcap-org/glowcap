"""Internal: the raw ``ctypes`` loader for ``libpancake_net_transport_tcp``.

The TCP transport ships as its own à-la-carte archive (ADR-0059), symbol-disjoint
from the core ``libpancake_ocapn``: it carries the ``pancake_tcp_*`` family plus
its own thread-local last-error (``pancake_tcp_last_error`` / ``_clear``). This
module loads only that archive, reusing the shared ``Structure`` types from
:mod:`pancake._ffi_ocapn` by layout, so importing :mod:`pancake.tcp` adds the TCP
archive on top of the core without pulling in any other transport. Nothing here
is public; :mod:`pancake.tcp` is the ergonomic surface over it.
"""

from __future__ import annotations

import ctypes

from ._archive_contract import require_archive_fingerprint
from ._constants import TCP_ARCHIVE_FINGERPRINT
from ._ffi_driver import _TransportProvider
from ._ffi_ocapn import _Frame, _Lib, _ManagedFrame, _bind
from ._lib_resolve import _lib_path
from ._pin import pin_struct

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``). The TCP archive carries
# its own thread-local last-error: a tcp call's diagnostic is read through
# ``pancake_tcp_last_error``, never the core family's ``pancake_last_error``.
from ._sigs_gen import tcp_sigs


class _TcpStreamOptions(ctypes.Structure):
    _fields_ = [
        ("keepalive_idle_sec", ctypes.c_uint32),
        ("keepalive_interval_sec", ctypes.c_uint32),
        ("keepalive_count", ctypes.c_uint32),
    ]


class _TcpConfig(ctypes.Structure):
    _fields_ = [("stream", _TcpStreamOptions)]


pin_struct(_TcpStreamOptions, "PANCAKE_TCP_STREAM_OPTIONS")
pin_struct(_TcpConfig, "PANCAKE_TCP_CONFIG")


def _load():
    tcp = ctypes.CDLL(str(_lib_path("pancake_net_transport_tcp")))
    require_archive_fingerprint(tcp, "tcp", TCP_ARCHIVE_FINGERPRINT)
    facade = _Lib(tcp)
    _bind(
        facade,
        tcp,
        tcp_sigs(
            _Frame,
            _ManagedFrame,
            _TcpConfig,
            _TcpStreamOptions,
            _TransportProvider,
        ),
    )
    return facade


# Loaded when :mod:`pancake.tcp` is imported, not when the core package is.
_tcp_lib = _load()
