"""The dial executor (binding spine Pass 3c): one path that turns a parsed
locator into an open, handshaken :class:`~pancake.Session`, shared by
:func:`connect` and handoff-redeem alike.

Every dial decision — the host:port grammar, the direct-addresses hint rule,
the peer-id reachability posture, the scheme dispatch, and the typed errors —
is resolved once in the core by ``pancake_host_plan_dial``, which hands back a
``PancakeDialPlan``. This module holds no dial business logic: it marshals the
posture, reads the plan into a language sum, and performs the one thing the
core cannot — the async byte-channel open (``asyncio.open_connection``, or the
iroh companion). Adding a transport is a core change, not an edit here.
Session owns mint/handshake (``establish_dialed_locator`` /
``establish_accepted``); this module owns plan + channel open + the public
:func:`connect` dialer.
"""

from __future__ import annotations

import asyncio
import ctypes
from dataclasses import dataclass
from typing import Optional, Union

from . import _constants as _abi
from ._errors import PancakeError, _check_host
from ._ffi_host import _DialPlan, _PendingDial, _host
from ._ffi_ocapn import _byte_buf
from ._host import Host
from ._locator import parse_locator

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


@dataclass(frozen=True, slots=True)
class _HostPortDial:
    host: str
    port: int
    tag: str = "host_port"


@dataclass(frozen=True, slots=True)
class _PeerIdDial:
    addresses: str
    reach_kind: int
    reach_value: int
    tag: str = "peer_id"


@dataclass(frozen=True, slots=True)
class _RendezvousDial:
    tag: str = "rendezvous"


_ResolvedDial = Union[_HostPortDial, _PeerIdDial, _RendezvousDial]


def _decode_plan_view(sources, ptr, length: int) -> str:
    """Decode a plan view that aliases one of the ctypes input buffers (one OS
    connect decode). A non-alias view is a core contract break. ``sources`` is
    ``(buf, base_ptr, raw_len)`` where ``raw_len`` is the logical UTF-8 length
    passed to the core."""
    if not ptr or not length:
        return ""
    vp = ctypes.cast(ptr, ctypes.c_void_p).value
    if vp is None:
        return ""
    for buf, base_ptr, raw_len in sources:
        base = base_ptr.value
        if base is None or raw_len == 0:
            continue
        if base <= vp and vp + length <= base + raw_len:
            off = vp - base
            return bytes(memoryview(buf)[off:off + length]).decode("utf-8", errors="replace")
    raise PancakeError(_ERR_INVALID_ARGUMENT, "dial plan view does not alias input buffers")


def _plan_dial(transport_name: str, designator: str, hint: str,
               posture_policy: int, posture_value: int) -> _ResolvedDial:
    """Resolve a dial in the core — the host:port grammar, the hint rule, the
    peer-id posture, and the error cases all decided by ``pancake_host_plan_dial``.
    Plan views alias the input UTF-8 buffers; decode those subslices only."""
    t, d, h = transport_name.encode(), designator.encode(), hint.encode()
    tbuf, tptr = _byte_buf(t)
    dbuf, dptr = _byte_buf(d)
    hbuf, hptr = _byte_buf(h)
    plan = _DialPlan()
    _check_host(_host.pancake_host_plan_dial(
        tptr, len(t), dptr, len(d), hptr, len(h),
        posture_policy, posture_value, ctypes.byref(plan),
    ))
    # Keep the ctypes buffers alive across the view decode (plan pointers alias them).
    _ = (tbuf, dbuf, hbuf)
    sources = ((dbuf, dptr, len(d)), (hbuf, hptr, len(h)))
    if plan.shape == _abi.DIAL_SHAPE_PEER_ID:
        return _PeerIdDial(
            addresses=_decode_plan_view(sources, plan.addresses, plan.addresses_len),
            reach_kind=plan.reach_kind,
            reach_value=plan.reach_value,
        )
    if plan.shape == _abi.DIAL_SHAPE_HOST_PORT:
        return _HostPortDial(
            host=_decode_plan_view(sources, plan.host, plan.host_len),
            port=plan.port,
        )
    if plan.shape == _abi.DIAL_SHAPE_SIGNALING:
        raise PancakeError(_ERR_INVALID_ARGUMENT,
            "webrtc signaling dial shape requires a signaling-aware adapter; a bare locator cannot open it")
    if plan.shape == _abi.DIAL_SHAPE_RENDEZVOUS:
        return _RendezvousDial()
    raise PancakeError(_ERR_INVALID_ARGUMENT, f"unknown dial shape {plan.shape}")


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
    handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS,
):
    """The dial entry for ``connect`` and handoff redeem alike: no dispatch,
    no grammar, no posture — the core resolves all of that in
    ``pancake_host_plan_dial``, and this opens the channel it names. Every dial
    through here bounds its handshake, so a peer that accepts the connection and
    then never finishes the OCapN handshake fails the dial rather than parking
    the caller."""
    # Session owns mint/handshake; import at call time so the session ↔ dial
    # module-load edge stays acyclic.
    from ._session import Session

    if redeem:
        if host is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, "handoff redeem requires a shared host")
        dial_host = host
        owns_host = False
        policy, value = _abi.DIAL_POSTURE_REDEEM, 0
    else:
        dial_host = host if host is not None else Host(codec=codec or "syrup")
        owns_host = host is None
        if reachability is not None:
            policy, value = _abi.DIAL_POSTURE_EXPLICIT, int(reachability)
        else:
            policy, value = _abi.DIAL_POSTURE_EXPLICIT_NONE, 0
    plan = _plan_dial(transport_name, designator, direct_addresses_hint, policy, value)
    if isinstance(plan, _PeerIdDial):
        from . import iroh as _iroh
        reach: _iroh.Reachability
        if plan.reach_kind == _abi.DIAL_REACH_DIRECT:
            reach = _iroh.Reachability.DIRECT
        elif plan.reach_kind == _abi.DIAL_REACH_CONFIGURED:
            reach = _iroh.Reachability(dial_host.redeem_reachability)
        else:
            # The plan carried the posture as its raw wire integer; converting
            # rather than assigning refuses a value outside the enum here, where
            # the locator that produced it is still in hand.
            reach = _iroh.Reachability(plan.reach_value)
        iroh_session = await _iroh._connect_iroh_with_host(
            designator, plan.addresses, reach, dial_host, handshake_timeout_ms,
        )
        iroh_session.owns_host = owns_host
        return iroh_session
    if isinstance(plan, _RendezvousDial):
        # A `keyed-relay` peer holds an inbound socket at a relay under its key
        # designator; the byte path is the relay's rendezvous bridge, and the
        # relay mapping is this host's deployment configuration, exactly like
        # the redeem reachability posture beside it (ADR-0088).
        rendezvous_url = dial_host.rendezvous_url
        if rendezvous_url is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT,
                "keyed-relay dial: no rendezvous relay configured; set Host.rendezvous_url first")
        from ._ws import connect_websocket
        ws_transport = await connect_websocket(rendezvous_url(designator))
        try:
            session = await Session.establish_dialed_locator(
                dial_host, transport_name, designator, ws_transport, handshake_timeout_ms,
            )
            session.owns_host = owns_host
            return session
        except BaseException:
            ws_transport.close()
            raise
    reader, writer = await asyncio.open_connection(plan.host, plan.port)
    transport = _StreamTransport(reader, writer)
    try:
        session = await Session.establish_dialed_locator(
            dial_host, transport_name, designator, transport, handshake_timeout_ms,
        )
        session.owns_host = owns_host
        return session
    except BaseException:
        transport.close()
        raise


async def dial_exporter(transport_name: str, designator: str,
                        direct_addresses_hint: str, host: Host,
                        handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS):
    """Dial an exporter a DIAL action names, keyed with ``host``'s retained
    identity, and bind the result to that same Host so the redeemed
    capability and any further handoff it triggers share one identity and
    session table. Binding-internal: the Host's action drain calls this to
    redeem a give. An exporter that never finishes the handshake breaks the
    redeem on ``handshake_timeout_ms`` rather than stalling the drain."""
    return await dial_parsed_locator(
        transport_name, designator, direct_addresses_hint, host, redeem=True,
        handshake_timeout_ms=handshake_timeout_ms,
    )


async def run_dial_ticket(host: Host, ticket: int) -> None:
    """Ticket-only DIAL arm: borrow parsed parts (no URI re-parse), dial, report."""
    from ._ffi_ocapn import _byte_buf

    try:
        view = _PendingDial()
        _check_host(_host.pancake_host_pending_dial(host.raw, ticket, ctypes.byref(view)))

        def _view_str(ptr: int | None, length: int) -> str:
            if not ptr or not length:
                return ""
            return bytes(ctypes.string_at(ptr, length)).decode("utf-8", errors="replace")

        transport = _view_str(view.transport, view.transport_len)
        designator = _view_str(view.designator, view.designator_len)
        hint = _view_str(view.hint, view.hint_len)
        session = await dial_exporter(transport, designator, hint, host)
        session.serve()
        _check_host(_host.pancake_host_dialed(host.raw, ticket, session.raw))
    except Exception as error:  # noqa: BLE001 — a failed dial breaks the redeems
        reason = (str(error) or type(error).__name__).encode()
        _buf, ptr = _byte_buf(reason)
        _check_host(_host.pancake_host_dial_failed(host.raw, ticket, ptr, len(reason)))


async def connect(uri: str, reachability: "Optional[int]" = None,
                  host: "Optional[Host]" = None, codec: Optional[str] = None,
                  *, handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS):
    """Dial a partner from its ``ocapn://`` locator: parse once, call
    ``pancake_host_plan_dial``, and open the byte channel the plan names.
    There is no other dial: a literal address is a ``tcp`` locator, built with
    :func:`tcp_locator`. The core owns transport dispatch and grammar.

    A ``tcp`` locator needs only this core module. An ``iroh`` locator reaches
    into the companion :mod:`pancake.iroh` (the optional encrypted-QUIC
    artifact), imported lazily here so the core never hard-depends on it;
    ``reachability`` is a :class:`pancake.iroh.Reachability` (its ``int`` value
    also works) and sets the iroh dialer's posture. It is required only for an
    ``iroh`` locator; a ``tcp`` locator ignores it, so a plain TCP dial needs
    nothing but the locator. An iroh locator with no posture fails closed
    rather than guessing one.

    ``host`` shares one identity and live-session directory across a server and its
    dialed sibling sessions — the gifter half of a three-party handoff (read
    it as ``server.host``). ``codec`` picks the wire grammar for a dial on a
    fresh Host; a supplied ``host`` already carries one, and a conflicting
    explicit codec is refused.

    ``handshake_timeout_ms`` bounds the OCapN handshake once the byte channel
    is open, at :data:`HANDSHAKE_TIMEOUT_MS` by default. A peer that accepts
    the connection and then says nothing raises :class:`PancakeError` with
    ``ERR_TIMEOUT`` instead of parking the caller; pass ``None`` or ``0`` to
    wait without a bound. It does not cover opening the channel itself: a TCP
    connect is the OS's timeout, and an iroh dial-by-id keeps its own discovery
    retry budget (ADR-0082) before the handshake starts."""
    loc = parse_locator(uri)
    # Fail closed on options a branch cannot honor: dropping a shared Host
    # silently would dial on a different identity and outside the live-session
    # directory that a later handoff uses to find this dial's session-owned
    # gift table; and the codec is the Host's, so a conflict is an error at the
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
        handshake_timeout_ms=handshake_timeout_ms,
    )
