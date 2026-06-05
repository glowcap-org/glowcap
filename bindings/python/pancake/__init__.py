"""pancake-python — Python ``ctypes`` bindings for the libpancake cdylib family.

pancake is a codec-neutral CapTP runtime for OCapN, exposed as a C-ABI cdylib
family. This package binds all three cdylibs (protocol core, TCP/TLS netlayer,
iroh netlayer) and layers a Pythonic API on top:

* :class:`Runtime` — loads ``libpancake_ffi_runtime``; factory for peers,
  keypairs, OCapN-URI parsing, syrup frame-probe, cross-peer coordination.
* :class:`Peer` / :class:`KeyPair` — per-peer lifecycle, step / queues, typed
  send / receive.
* :class:`TcpNetlayer` / :class:`IrohNetlayer` — endpoint dialing / listening.
* :class:`Bridge` + :func:`run_until` — the single-thread poll pump.
* :mod:`pancake.values` — typed CapTP value builders + projections.

Set ``PANCAKE_LIB``, ``PANCAKE_NET_TCP_LIB``, ``PANCAKE_NET_IROH_LIB`` to the
absolute ``target/release/lib*.so`` paths before importing the lib-loading
classes.
"""

from __future__ import annotations

from . import constants  # noqa: F401
from .constants import *  # noqa: F401,F403
from .host import (  # noqa: F401
    KeyPair,
    OcapnUri,
    PancakeError,
    Peer,
    Runtime,
    SturdyrefDedup,
)
from .netlayer import (  # noqa: F401
    CLOSED,
    MALFORMED,
    WOULD_BLOCK,
    Connection,
    EndpointError,
    IrohEndpoint,
    IrohNetlayer,
    Listener,
    TcpNetlayer,
    TransportOps,
)
from .pump import Bridge, both_open, run_until  # noqa: F401
from .values import (  # noqa: F401
    Argument,
    Reference,
    Resolution,
    arg_bool,
    arg_bytes,
    arg_integer,
    arg_list,
    arg_reference,
    arg_string,
    arg_symbol,
    arg_void,
    ref_far,
    ref_near,
    ref_sturdy,
    res_break,
    res_fulfill,
    to_native,
)

__version__ = "0.1.0"
