"""Idiomatic Python API for pancake, an OCapN/CapTP Host you drive over the
byte-fed host archive (``libpancake_driver``, ADR-0072).

This is the core package: it rides ``libpancake_ocapn`` (the shared value and
locator vocabulary) plus its companion ``libpancake_driver`` (the byte-fed
multi-session CapTP host), and is usable on its own for TCP. The raw ``ctypes``
FFI lives in the internal ``_ffi_*`` modules; this package is the public
surface over it. What you hold is a :class:`Session`: dial with
:func:`connect`, accept with :func:`listen`, and speak native Python values —
``int``/``float``/``bool``/``bytes``/``str``/``list``, plus :class:`Symbol`,
:class:`Keyword`, :class:`Set`, :class:`Tagged`, and the capability
:class:`Ref`:

    session = await connect(tcp_locator("127.0.0.1", 9099))
    session.serve()
    greeter = await session.fetch("greeter")
    reply = await session.send(greeter, "greet", ["world"])

The host owns routing, three-party redemption, and gift origination; the
binding moves bytes and honors the host's action queue. A :class:`Host` is the
CapTP Host those sessions share — one identity, one gift registry — read as
``server.host`` or passed to :func:`connect`.

The C ABI ships as a set of composable, symbol-disjoint archives (ADR-0059),
and this package mirrors that à la carte: the core here, plus one submodule
per transport. Each transport submodule loads only its own archive, so
importing one transport never loads another. Compose what you need:

    from pancake import connect, listen, tcp_locator
    from pancake.tcp import TcpNetlayer        # libpancake_net_transport_tcp
    from pancake.inproc import InprocNetlayer  # libpancake_net_transport_inproc
    from pancake.iroh import listen_iroh       # libpancake_net_transport_iroh

The async :func:`connect` / :func:`listen` / :class:`Session` surface here
is transport-neutral and pure-asyncio over a TCP socket, so a plain TCP
application needs only this core. The blocking ``pancake_tcp_*`` frame shuttle
lives in :mod:`pancake.tcp`; the socket-free in-process transport in
:mod:`pancake.inproc`; the encrypted-QUIC transport in :mod:`pancake.iroh`. An
``iroh`` locator handed to :func:`connect` reaches the iroh submodule lazily,
so the core never hard-depends on the optional iroh artifact.

The implementation is split by responsibility across ``_``-private submodules
(``_errors``, ``_value``, ``_codec``, ``_context``, ``_locator``,
``_trampoline``, ``_host``, ``_action``, ``_promise``, ``_gc``, ``_dial``,
``_listen``, ``_pump``, ``_session``) alongside the per-archive ``_ffi_*``
loaders; this module is the barrel that re-exports the public surface. Import
every name from :mod:`pancake` — the submodule layout is internal.
"""

from __future__ import annotations

# Re-export the public surface from the per-responsibility submodules, in
# dependency order (errors and values first, then the Host and the application
# surface). A consumer imports every name from :mod:`pancake`.
from ._errors import (
    AbortDetail,
    FetchFailed,
    PancakeError,
    PancakeException,
    VowBroken,
    abi_version,
    last_error,
)
from ._value import (
    Broken,
    Far,
    Forward,
    Keyword,
    Near,
    Promise,
    Ref,
    Set,
    Sturdy,
    Symbol,
    Tagged,
)
from ._constants import TRANSPORT_IROH, TRANSPORT_KEYED_TCP, TRANSPORT_TCP
from ._context import Context
from ._locator import (
    Locator,
    designator_host_port,
    encode_peer_locator,
    format_peer_uri,
    keyed_tcp_locator,
    parse_locator,
    socket_addr_designator,
    tcp_locator,
)
from ._host import Host
from ._promise import RemotePromise
from ._session import (
    Session,
)
from ._trampoline import Caretaker
from ._dial import connect
from ._listen import (
    KeyedTcpServer,
    Server,
    listen,
    listen_keyed_tcp,
)

__all__ = [
    # Version and diagnostics
    "abi_version",
    "last_error",
    "AbortDetail",
    # Exceptions
    "PancakeException",
    "PancakeError",
    "VowBroken",
    "FetchFailed",
    # Value vocabulary
    "Near",
    "Promise",
    "Sturdy",
    "Broken",
    "Far",
    "Ref",
    "Symbol",
    "Keyword",
    "Set",
    "Tagged",
    "Forward",
    # Allocation scope
    "Context",
    # Application surface
    "Session",
    "RemotePromise",
    "Server",
    "KeyedTcpServer",
    "Host",
    "Caretaker",
    "connect",
    "listen",
    "listen_keyed_tcp",
    # Locator grammar
    "Locator",
    "parse_locator",
    "format_peer_uri",
    "designator_host_port",
    "socket_addr_designator",
    "tcp_locator",
    "keyed_tcp_locator",
    "encode_peer_locator",
    # Transport symbols
    "TRANSPORT_TCP",
    "TRANSPORT_KEYED_TCP",
    "TRANSPORT_IROH",
]
