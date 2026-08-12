"""Idiomatic Python API for pancake, an OCapN/CapTP Host driven by the
symbol-disjoint Host and driver archives (ADR-0112).

This is the core package: it rides ``libpancake_ocapn`` (the shared value and
locator vocabulary), ``libpancake_host`` (the byte-fed multi-session Host),
and ``libpancake_driver`` (the stepping driver that adopts that Host). It is usable on its
own for TCP. The raw ``ctypes``
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
CapTP Host those sessions share — one identity and one handoff router — read as
``server.host`` or passed to :func:`connect`.

The C ABI ships as a set of composable, symbol-disjoint archives (ADR-0059),
and this package mirrors that à la carte: the core here, plus one submodule
per transport. Each transport submodule loads only its own archive, so
importing one transport never loads another. Compose what you need:

    from pancake import connect, listen, tcp_locator
    from pancake.tcp import TcpNetlayer        # libpancake_net_transport_tcp
    from pancake.inproc import InprocNetlayer  # libpancake_net_transport_inproc
    from pancake.iroh import listen_iroh       # libpancake_net_transport_iroh

The async :func:`connect` / :func:`listen` / :class:`Session` surface here is
transport-neutral. A ``tcp``, ``keyed-tcp``, ``noise-tcp``, ``iroh``, or routed
relay connection runs on the driver archive — one stepping loop owns the
provider, pumping, and session release, parked on the asyncio reactor. A bare
relay locator with a Host rendezvous callback remains an explicit binding-level
byte seam. A plain TCP application
needs only this core. The blocking
``pancake_tcp_*`` frame shuttle
lives in :mod:`pancake.tcp`; the socket-free in-process transport in
:mod:`pancake.inproc`; the encrypted-QUIC transport in :mod:`pancake.iroh`. An
``iroh`` locator handed to :func:`connect` reaches the iroh submodule lazily,
so the core never hard-depends on the optional iroh artifact.

The implementation is split by responsibility across ``_``-private submodules
(``_errors``, ``_value``, ``_codec``, ``_context``, ``_locator``,
``_trampoline``, ``_host``, ``_action``, ``_promise``, ``_gc``, ``_dial``,
``_listen``, ``_loop``, ``_pump``, ``_session``) alongside the per-archive ``_ffi_*``
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
    VowBroken,
    abi_version,
    last_error,
)
from ._value import Forward, Keyword, Ref, Set, Symbol, Tagged
from ._constants import (
    HANDSHAKE_TIMEOUT_MS,
    HINT_DIRECT_ADDRESSES,
    TRANSPORT_INPROC,
    TRANSPORT_IROH,
    TRANSPORT_KEYED_RELAY,
    TRANSPORT_KEYED_TCP,
    TRANSPORT_NOISE_TCP,
    TRANSPORT_TCP,
    TRANSPORT_WEBRTC,
)
from ._context import Context
from ._locator import (
    Locator,
    SturdyRef,
    designator_host_port,
    encode_peer_locator,
    format_peer_uri,
    format_sturdyref,
    keyed_tcp_locator,
    noise_tcp_locator,
    parse_locator,
    parse_sturdyref,
    socket_addr_designator,
    tcp_locator,
)
from ._host import Host
from ._trace import annotate_session, enable_trace
from ._promise import RemotePromise
from ._constants import DurableProvenance
from ._session import (
    PartnerIdentity,
    SendRedeemingResult,
    Session,
)
from ._trampoline import Caretaker
from ._dial import connect
from ._listen import (
    KeyedTcpServer,
    NoiseTcpServer,
    Server,
    listen,
    listen_keyed_tcp,
    listen_noise_tcp,
)

__all__ = [
    # Version and diagnostics
    "abi_version",
    "last_error",
    "AbortDetail",
    # Exceptions
    "PancakeError",
    "VowBroken",
    "FetchFailed",
    # Argument vocabulary
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
    "SendRedeemingResult",
    "DurableProvenance",
    "PartnerIdentity",
    "RemotePromise",
    "Server",
    "KeyedTcpServer",
    "NoiseTcpServer",
    "Host",
    "Caretaker",
    "connect",
    "annotate_session",
    "enable_trace",
    "listen",
    "listen_keyed_tcp",
    "listen_noise_tcp",
    "HANDSHAKE_TIMEOUT_MS",
    # Locator grammar
    "Locator",
    "SturdyRef",
    "parse_locator",
    "parse_sturdyref",
    "format_peer_uri",
    "format_sturdyref",
    "designator_host_port",
    "socket_addr_designator",
    "tcp_locator",
    "keyed_tcp_locator",
    "noise_tcp_locator",
    "encode_peer_locator",
    # Transport symbols
    "TRANSPORT_TCP",
    "TRANSPORT_KEYED_TCP",
    "TRANSPORT_NOISE_TCP",
    "TRANSPORT_INPROC",
    "TRANSPORT_IROH",
    "TRANSPORT_KEYED_RELAY",
    "TRANSPORT_WEBRTC",
    # Locator hint keys
    "HINT_DIRECT_ADDRESSES",
]
