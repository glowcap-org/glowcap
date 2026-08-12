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

import ctypes
from dataclasses import dataclass
from typing import Optional, Union

from . import _constants as _abi
from ._errors import PancakeError, _check_host
from ._ffi_host import _DialPlan, _host
from ._ffi_ocapn import _byte_buf, _LocatorHintView, _LocatorView
from ._host import Host
from ._locator import Locator, _OwnedLocator, parse_locator

_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


@dataclass(frozen=True, slots=True)
class _HostPortDial:
    transport: str
    host: str
    port: int
    tag: str = "host_port"


@dataclass(frozen=True, slots=True)
class _PeerIdDial:
    transport: str
    addresses: str
    reach_kind: int
    reach_value: int
    tag: str = "peer_id"


@dataclass(frozen=True, slots=True)
class _RendezvousDial:
    transport: str
    tag: str = "rendezvous"


@dataclass(frozen=True, slots=True)
class _SignalingDial:
    transport: str
    tag: str = "signaling"


_ResolvedDial = Union[_HostPortDial, _PeerIdDial, _RendezvousDial, _SignalingDial]


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
            return bytes(memoryview(buf)[off : off + length]).decode(
                "utf-8", errors="replace"
            )
    raise PancakeError(
        _ERR_INVALID_ARGUMENT, "dial plan view does not alias input buffers"
    )


def _plan_dial(
    transport_name: str,
    designator: str,
    hint: str,
    posture_policy: int,
    posture_value: int,
) -> _ResolvedDial:
    """Resolve a dial in the core — the host:port grammar, the hint rule, the
    peer-id posture, and the error cases all decided by ``pancake_host_plan_dial``.
    Plan views alias the input UTF-8 buffers; decode those subslices only."""
    t, d, h = transport_name.encode(), designator.encode(), hint.encode()
    tbuf, tptr = _byte_buf(t)
    dbuf, dptr = _byte_buf(d)
    hbuf, hptr = _byte_buf(h)
    plan = _DialPlan()
    _check_host(
        _host.pancake_host_plan_dial(
            tptr,
            len(t),
            dptr,
            len(d),
            hptr,
            len(h),
            posture_policy,
            posture_value,
            ctypes.byref(plan),
        )
    )
    # Keep the ctypes buffers alive across the view decode (plan pointers alias them).
    _ = (tbuf, dbuf, hbuf)
    sources = ((dbuf, dptr, len(d)), (hbuf, hptr, len(h)))
    if plan.shape == _abi.DIAL_SHAPE_PEER_ID:
        return _PeerIdDial(
            transport=transport_name,
            addresses=_decode_plan_view(sources, plan.addresses, plan.addresses_len),
            reach_kind=plan.reach_kind,
            reach_value=plan.reach_value,
        )
    if plan.shape == _abi.DIAL_SHAPE_HOST_PORT:
        return _HostPortDial(
            transport=transport_name,
            host=_decode_plan_view(sources, plan.host, plan.host_len),
            port=plan.port,
        )
    if plan.shape == _abi.DIAL_SHAPE_SIGNALING:
        return _SignalingDial(transport_name)
    if plan.shape == _abi.DIAL_SHAPE_RENDEZVOUS:
        return _RendezvousDial(transport_name)
    raise PancakeError(_ERR_INVALID_ARGUMENT, f"unknown dial shape {plan.shape}")


async def dial_parsed_locator(
    locator: Locator,
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
    the caller.

    Native TCP, iroh, and routed relay plans run through the generic driver. A
    supplied byte-fed Host is transferred transactionally before that driver
    is started, preserving the caller's Host object and authority. A bare relay
    locator can still use the Host's explicit WebSocket rendezvous fallback."""
    # Session owns mint/handshake; import at call time so the session ↔ dial
    # module-load edge stays acyclic.
    from ._session import Session

    transport_name = locator.transport
    designator = locator.designator
    direct_addresses_hint = _direct_addresses_hint(locator)
    if redeem and host is None:
        raise PancakeError(
            _ERR_INVALID_ARGUMENT, "handoff redeem requires a shared host"
        )
    dial_host = host
    owns_host = False
    policy, value = (
        (_abi.DIAL_POSTURE_REDEEM, 0)
        if redeem
        else (
            (_abi.DIAL_POSTURE_EXPLICIT, int(reachability))
            if reachability is not None
            else (_abi.DIAL_POSTURE_EXPLICIT_NONE, 0)
        )
    )
    succeeded = False
    loop = None
    try:
        plan = _plan_dial(
            transport_name, designator, direct_addresses_hint, policy, value
        )
        from .relay import _route_from_locator

        relay_route = _route_from_locator(locator)
        if isinstance(plan, (_HostPortDial, _PeerIdDial)) or (
            isinstance(plan, _RendezvousDial) and relay_route is not None
        ):
            if not handshake_timeout_ms or handshake_timeout_ms <= 0:
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "native driver providers require a positive handshake timeout",
                )
            from ._loop import DriverLoop, dial_shared_loop

            if host is not None and getattr(host, "_loop_mode", False):
                loop = host._driver_loop
            elif host is not None:
                loop = DriverLoop.take_host(host)
            else:
                loop = DriverLoop.open(
                    codec=codec if codec is not None else "syrup",
                    handshake_ms=handshake_timeout_ms,
                )
            await loop.start()
            await prepare_native_provider(loop, plan, locator)
            session = await dial_shared_loop(loop, locator)
            session.owns_host = host is None
            succeeded = True
            return session
        if isinstance(plan, _RendezvousDial):
            # A `keyed-relay` peer holds an inbound socket at a relay under its key
            # designator; the byte path is the relay's rendezvous bridge, and the
            # relay mapping is this host's deployment configuration, exactly like
            # the redeem reachability posture beside it (ADR-0088).
            dial_host = dial_host or Host(codec=codec if codec is not None else "syrup")
            owns_host = host is None
            from .relay import _dial_url, _route_from_locator

            relay_route = _route_from_locator(locator)
            rendezvous_url = dial_host.rendezvous_url
            if relay_route is None and rendezvous_url is None:
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "relay dial: locator has no rendezvous-relay hint and the Host has no rendezvous mapping",
                )
            from ._ws import connect_websocket

            url = (
                _dial_url(relay_route, designator)
                if relay_route is not None
                else rendezvous_url(designator)
            )
            ws_transport = await connect_websocket(url)
            try:
                session = await Session.establish_dialed_locator(
                    dial_host,
                    transport_name,
                    designator,
                    ws_transport,
                    handshake_timeout_ms,
                )
                session.owns_host = owns_host
                succeeded = True
                return session
            except BaseException:
                ws_transport.close()
                raise
        if isinstance(plan, _SignalingDial):
            dial_host = dial_host or Host(codec=codec if codec is not None else "syrup")
            owns_host = host is None
            signaling = getattr(dial_host, "signaling", None)
            if signaling is None:
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "signaling dial requires an explicit Host.signaling byte-channel integration",
                )
            channel = await signaling.open(designator)
            try:
                session = await Session.establish_dialed_locator(
                    dial_host,
                    transport_name,
                    designator,
                    channel,
                    handshake_timeout_ms,
                )
                session.owns_host = owns_host
                succeeded = True
                return session
            except BaseException:
                channel.close()
                raise
        raise PancakeError(
            _ERR_INVALID_ARGUMENT, "native dial plan was not a driver provider"
        )
    finally:
        if (
            loop is not None
            and not succeeded
            and (host is None or not getattr(host, "_loop_mode", False))
        ):
            loop.close()
        elif owns_host and not succeeded:
            dial_host.release()


async def prepare_native_provider(loop, plan, locator: Locator) -> None:
    """Compose the provider package selected by the binding product edge."""
    if isinstance(plan, _HostPortDial):
        from .tcp import install_provider

        install_provider(loop)
        return
    if isinstance(plan, _PeerIdDial):
        from . import iroh

        await iroh.adopt_loop_provider(
            loop,
            iroh.IrohConfig(iroh.reachability_for_plan(plan)),
            seed=loop.wrapper_host().seed,
        )
        return
    if isinstance(plan, _RendezvousDial):
        from .relay import _route_from_locator, install_provider

        route = _route_from_locator(locator)
        if route is None:
            raise PancakeError(
                _ERR_INVALID_ARGUMENT,
                "native relay provider requires a rendezvous-relay locator hint",
            )
        install_provider(loop, route)
        return


def _direct_addresses_hint(locator: Locator) -> str:
    value = locator.hints.get(_abi.HINT_DIRECT_ADDRESSES, "")
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return ""


async def dial_exporter(
    locator: Locator,
    host: Host,
    handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS,
):
    """Dial an exporter a DIAL action names, keyed with ``host``'s retained
    identity, and bind the result to that same Host so the redeemed
    capability and any further handoff it triggers share one identity and
    session table. Binding-internal: the Host's action drain calls this to
    redeem a give. An exporter that never finishes the handshake breaks the
    redeem on ``handshake_timeout_ms`` rather than stalling the drain."""
    return await dial_parsed_locator(
        locator,
        host,
        redeem=True,
        handshake_timeout_ms=handshake_timeout_ms,
    )


async def run_dial_ticket(host: Host, ticket: int) -> None:
    """Ticket-only DIAL arm: clone the complete locator, dial, and report."""
    from ._ffi_ocapn import _byte_buf

    session = None
    try:
        if host.released:
            return
        capacity = 8
        while True:
            hints = (_LocatorHintView * capacity)()
            view = _LocatorView()
            count = ctypes.c_size_t()
            rc = _host.pancake_host_pending_dial(
                host.raw,
                ticket,
                hints,
                capacity,
                ctypes.byref(view),
                ctypes.byref(count),
            )
            if rc != _abi.ERR_BUFFER_TOO_SMALL:
                _check_host(rc)
                break
            capacity = count.value
        with _OwnedLocator.clone_view(ctypes.byref(view)) as owned:
            locator = owned.value()
        session = await dial_exporter(locator, host)
        if host.released:
            session.close_transport()
            return
        _check_host(_host.pancake_host_dialed(host.raw, ticket, session.raw))
        session.serve()
        session = None  # the Host registry now owns terminal teardown
    except BaseException as error:  # cancellation must settle a popped action
        if session is not None:
            session.close_transport()
        if host.released:
            return
        reason = (str(error) or type(error).__name__).encode()
        _buf, ptr = _byte_buf(reason)
        _check_host(_host.pancake_host_dial_failed(host.raw, ticket, ptr, len(reason)))
        if not isinstance(error, Exception):
            raise


async def connect(
    uri: str,
    reachability: "Optional[int]" = None,
    host: "Optional[Host]" = None,
    codec: Optional[str] = None,
    *,
    handshake_timeout_ms: "Optional[int]" = _abi.HANDSHAKE_TIMEOUT_MS,
):
    """Dial a partner from its ``ocapn://`` locator: parse once, call
    ``pancake_host_plan_dial``, and open the channel the plan names.
    There is no other dial: a literal address is a ``tcp`` locator, built with
    :func:`tcp_locator`. The core owns transport dispatch and grammar.

    A ``tcp``, ``keyed-tcp``, ``noise-tcp``, ``iroh``, or routed relay dial runs on the driver archive (ADR-0112):
    the session rides one stepping native loop that owns the socket, the
    pumping, and — for a session opened with no shared ``host`` — the whole
    stack, so closing the session closes it all. A bare relay locator can use a
    deliberately explicit Host WebSocket fallback.

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
    ``ERR_TIMEOUT`` instead of parking the caller. Native provider dials reject
    ``None`` or ``0`` because the driver requires a positive budget; only the
    explicit bare-locator relay fallback is byte-fed. A dial
    sharing a loop-backed server's Host is bounded by that loop's budget
    rather than this argument. The bound does not cover opening the channel
    itself: a TCP connect is the OS's timeout, and an iroh dial-by-id keeps
    its own discovery retry budget (ADR-0082) before the handshake starts."""
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
        loc,
        host,
        reachability=reachability,
        codec=codec,
        handshake_timeout_ms=handshake_timeout_ms,
    )
