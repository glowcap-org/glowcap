"""The dial executor (binding spine Pass 3c): one path that turns a parsed
locator into an open, handshaken :class:`~pancake.Session`, shared by
:func:`connect` and handoff-redeem alike.

Every dial decision — the host:port grammar, the direct-addresses hint rule,
the iroh reachability posture, the scheme dispatch, and the typed errors —
is resolved once in the core by ``pancake_host_plan_dial``, which hands back a
``PancakeDialPlan``. This module holds no dial business logic: it marshals the
posture, reads the plan, and performs the one thing the core cannot — the
async byte-channel open (``asyncio.open_connection``, or the iroh companion).
Adding a transport is a core change, not an edit here. Session owns
mint/handshake (``establish_dialed_locator`` / ``establish_accepted``); this
module owns plan + channel open + the public :func:`connect` dialer.
"""

from __future__ import annotations

import asyncio
import ctypes
from typing import NamedTuple, Optional

from . import _constants as _abi
from ._errors import PancakeError, _check_host
from ._ffi_driver import _DialPlan, _host
from ._ffi_ocapn import _byte_buf
from ._host import Host
from ._locator import parse_locator

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


class _ResolvedDial(NamedTuple):
    """A resolved dial from ``pancake_host_plan_dial``: what channel to open and
    how. ``shape`` selects the live fields."""

    shape: int
    host: str
    port: int
    addresses: str
    reach_kind: int
    reach_value: int


def _plan_dial(transport_name: str, designator: str, hint: str,
               posture_policy: int, posture_value: int) -> _ResolvedDial:
    """Resolve a dial in the core — the host:port grammar, the hint rule, the
    iroh posture, and the error cases all decided by ``pancake_host_plan_dial``.
    The plan's ``host`` / ``addresses`` borrow the input buffers, so they are read
    into strings here while those buffers are alive."""
    t, d, h = transport_name.encode(), designator.encode(), hint.encode()
    tbuf, tptr = _byte_buf(t)
    dbuf, dptr = _byte_buf(d)
    hbuf, hptr = _byte_buf(h)
    plan = _DialPlan()
    _check_host(_host.pancake_host_plan_dial(
        tptr, len(t), dptr, len(d), hptr, len(h),
        posture_policy, posture_value, ctypes.byref(plan),
    ))

    def view(ptr, length):
        return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""

    return _ResolvedDial(
        shape=plan.shape,
        host=view(plan.host, plan.host_len),
        port=plan.port,
        addresses=view(plan.addresses, plan.addresses_len),
        reach_kind=plan.reach_kind,
        reach_value=plan.reach_value,
    )


class _StreamTransport:
    """How bytes move for one TCP connection over asyncio streams — the
    transport seam the byte-fed pump reads and the FLUSH drain writes. The iroh
    companion (:mod:`pancake.iroh`) supplies its own record with the same three
    verbs, so the iroh artifact stays out of this core module entirely. Framing
    is never the transport's job: the host's stream delimiter owns it. The
    write contract every transport record shares: ``write()`` moves bytes
    only — it must not call host verbs or feed a connection, because it runs
    under the connection's ``_write_lock`` and a reentrant flush would
    deadlock or interleave frames."""

    _READ_CHUNK = 65536

    def __init__(self, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter"):
        self._reader = reader
        self._writer = writer

    async def read(self) -> Optional[bytes]:
        """The next chunk of inbound bytes, or ``None`` at a clean end of
        stream."""
        chunk = await self._reader.read(self._READ_CHUNK)
        return chunk if chunk else None

    async def write(self, data: bytes) -> None:
        """Write every byte of ``data``, awaiting the stream's backpressure."""
        self._writer.write(data)
        await self._writer.drain()

    def close(self) -> None:
        self._writer.close()


async def dial_parsed_locator(
    transport_name: str,
    designator: str,
    direct_addresses_hint: str,
    host: "Optional[Host]" = None,
    *,
    reachability=None,
    redeem: bool = False,
    codec: "Optional[str]" = None,
):
    """The dial entry for ``connect`` and handoff redeem alike: no dispatch,
    no grammar, no posture — the core resolves all of that in
    ``pancake_host_plan_dial``, and this opens the channel it names."""
    # Session owns mint/handshake; import at call time so the session ↔ dial
    # module-load edge stays acyclic.
    from ._session import Session

    if redeem:
        if host is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "handoff redeem requires a shared host")
        dial_host = host
        policy, value = _abi.DIAL_POSTURE_REDEEM, 0
    else:
        dial_host = host if host is not None else Host(codec=codec or "syrup")
        if reachability is not None:
            policy, value = _abi.DIAL_POSTURE_EXPLICIT, int(reachability)
        else:
            policy, value = _abi.DIAL_POSTURE_EXPLICIT_NONE, 0
    plan = _plan_dial(transport_name, designator, direct_addresses_hint, policy, value)
    if plan.shape == _abi.DIAL_SHAPE_IROH:
        from . import iroh as _iroh
        if plan.reach_kind == _abi.DIAL_REACH_DIRECT:
            reach = _iroh.Reachability.DIRECT
        elif plan.reach_kind == _abi.DIAL_REACH_CONFIGURED:
            reach = dial_host.redeem_reachability
        else:
            reach = plan.reach_value
        return await _iroh._connect_iroh_with_host(designator, plan.addresses, reach, dial_host)
    reader, writer = await asyncio.open_connection(plan.host, plan.port)
    transport = _StreamTransport(reader, writer)
    try:
        return await Session.establish_dialed_locator(dial_host, transport_name, designator, transport)
    except BaseException:
        transport.close()
        raise


async def dial_exporter(transport_name: str, designator: str,
                        direct_addresses_hint: str, host: Host):
    """Dial an exporter a DIAL action names, keyed with ``host``'s retained
    identity, and bind the result to that same Host so the redeemed
    capability and any further handoff it triggers share one identity and
    session table. The action carries the locator's parsed pieces, so
    nothing re-parses the full give URI — tcp splits the already-parsed
    designator via the core host:port grammar.
    Binding-internal: the Host's action drain calls this to redeem a give.
    Dispatches on the transport: a ``tcp`` locator dials its host:port
    designator (already parsed out of the dial action); an
    ``iroh`` give with direct-address hints dials them with no discovery
    service (Direct), and a bare node id resolves by id under the Host's
    configured redeem posture (default Discovery; a relay-policy Host
    lowers it), so one give shape covers an offline direct dial and an
    internet dial-by-id alike."""
    return await dial_parsed_locator(
        transport_name, designator, direct_addresses_hint, host, redeem=True,
    )


async def connect(uri: str, reachability: "Optional[int]" = None,
                  host: "Optional[Host]" = None, codec: Optional[str] = None):
    """Dial a partner from its ``ocapn://`` locator, the one dialer,
    dispatching on the locator's transport: ``iroh`` dials the endpoint id with
    its ``direct-addresses`` hints, ``tcp`` dials the ``host:port`` designator.
    There is no other dial: a literal address is a ``tcp`` locator, built with
    :func:`tcp_locator`. Parse once, the core grammar picks the netlayer.

    A ``tcp`` locator needs only this core module. An ``iroh`` locator reaches
    into the companion :mod:`pancake.iroh` (the optional encrypted-QUIC
    artifact), imported lazily here so the core never hard-depends on it;
    ``reachability`` is a :class:`pancake.iroh.Reachability` (its ``int`` value
    also works) and sets the iroh dialer's posture. It is required only for an
    ``iroh`` locator; a ``tcp`` locator ignores it, so a plain TCP dial needs
    nothing but the locator. An iroh locator with no posture fails closed
    rather than guessing one.

    ``host`` shares one identity and gift registry across a server and its
    dialed sibling sessions — the gifter half of a three-party handoff (read
    it as ``server.host``). ``codec`` picks the wire grammar for a dial on a
    fresh Host; a supplied ``host`` already carries one, and a conflicting
    explicit codec is refused."""
    loc = parse_locator(uri)
    # Fail closed on options a branch cannot honor: dropping a shared Host
    # silently would dial on a different identity than `host`, so a capability
    # fetched here and re-gifted is not recognized against the shared gift
    # registry; and the codec is the Host's, so a conflict is an error at the
    # call that caused it.
    if host is not None and codec is not None and codec != host.codec:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'codec "{codec}" conflicts with the shared host\'s "{host.codec}"',
        )
    return await dial_parsed_locator(
        loc.transport, loc.designator,
        loc.hints.get(_abi.HINT_DIRECT_ADDRESSES, ""),
        host,
        reachability=reachability,
        codec=codec,
    )
