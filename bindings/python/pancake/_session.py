"""Internal: the application surface over the byte-fed host
(``libpancake_driver``, ADR-0072).

This is what an application holds: :class:`Session` and its verbs
(``fetch``/``send``/``tell``/``spawn``/``publish``/``enliven``/``serve``/
``close``), plus mint/handshake (``establish_*``). The dial executor
(plan + channel open + :func:`connect`) lives in :mod:`pancake._dial`;
Server/:func:`listen` live in :mod:`pancake._listen`. The
:class:`RemotePromise` handle, far-send mint, and fetch/enliven wait live
in :mod:`pancake._promise`. Spawn/publish hosting, local send/tell, near/far
dispatch, and ADR-0064 proxy factories live in :mod:`pancake._trampoline`. The
byte-fed embedder pump — read raw bytes off the transport, hand them to the
core's stream delimiter ``pancake_host_session_feed_bytes``, drain the host's
action queue, write what ``take_outbound`` drains — lives in
:mod:`pancake._pump`; :class:`Session` methods wrap it. The host owns
everything else: routing, redemption, gift origination, far vows.
:class:`Host` and :class:`Session` are one mutually-recursive layer; the
Host half lives in :mod:`pancake._host`. Import from the :mod:`pancake`
package.
"""

from __future__ import annotations

import asyncio
from typing import Optional

import ctypes

from . import _constants as _abi
from . import _pump
from ._errors import (
    AbortDetail,
    PancakeError,
    PancakeException,
    _check_host,
)
from ._ffi_driver import _AcceptPlan, _host
from ._ffi_ocapn import _byte_buf
from ._host import Host
from ._locator import parse_locator
from ._promise import RemotePromise, _fetch_like
from ._gc import ConnGc, bind_session
from ._trampoline import (
    Caretaker,
    _attenuate_proxy,
    _caretaker_proxy,
    _dispatch_send,
    _dispatch_tell,
    _inside_turn,
    _spawn_hosted,
    _publish_hosted,
    _unregister_behavior,
)
from ._value import Behavior, Ref

_ERR_CLOSED = _abi.ERR_CLOSED


class Session:
    """A live CapTP session with one OCapN partner, the one object an app holds,
    over one byte-fed ``PancakeHostSession`` the shared :class:`Host` minted.

        session = await connect(tcp_locator("127.0.0.1", 9099))
        session.serve()
        board = await session.fetch("board")
        inbox = session.spawn(lambda verb, args: None)
        await session.send(board, "watch", [inbox])
    """

    def __init__(self, ptr: ctypes.c_void_p, host: Host, transport):
        self._ptr = ptr
        self._key = ptr.value or 0
        self._host = host
        self._transport = transport
        self._serve_task: Optional[asyncio.Task] = None
        # Set the moment teardown begins (an application close, or the
        # transport reporting EOF), so the FAIL completions the break queues
        # classify as the typed ERR_CLOSED instead of partner breaks.
        self._closing = False
        self._released = False
        # Serializes transport writes: `flush_outbound` runs from the action
        # drain, the feed-failure choreography, and teardown, and each frame
        # must land whole and in submission order.
        self._write_lock = asyncio.Lock()
        # Export position -> trampoline ctx id for the objects this session
        # hosts, so a `Forward` whose target this side hosts composes in
        # process (and a send to a self-spawned Ref runs in process).
        self._hosted: "dict[int, int]" = {}
        # True for an exporter connection the Host's action drain dialed to
        # redeem a handoff, so `close()` can sweep it.
        self.host_dialed = False
        # Distributed GC (ADR-0063), opt-in and off by default — see `_gc`.
        self._gc = ConnGc()
        try:
            self._loop: "Optional[asyncio.AbstractEventLoop]" = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None
        bind_session(self._gc, self)
        # Join the Host's registry so a FLUSH action can find the transport and
        # a dialed exporter stays reachable for teardown.
        host.register_session(self._key, self)

    # ── Construction: establish, dial, accept ──────────────────────────────────

    @classmethod
    def _open_dialed_locator(
        cls, host: Host, transport_name: str, designator: str, transport,
    ) -> "Session":
        # Mint the dialing half from already-parsed locator pieces without
        # driving the handshake — the signed op:start-session is encoded (its
        # FLUSH queued) but nothing has moved. A DIAL action's binding half
        # borrows the pending URI before calling here.
        t = transport_name.encode()
        d = designator.encode()
        tbuf, tptr = _byte_buf(t)
        dbuf, dptr = _byte_buf(d)
        out = ctypes.c_void_p()
        _check_host(_host.pancake_host_session_open_dialed_locator(
            host.raw, tptr, len(t), dptr, len(d), ctypes.byref(out),
        ))
        return cls(out, host, transport)

    @classmethod
    async def establish_dialed_locator(
        cls, host: Host, transport_name: str, designator: str, transport,
    ) -> "Session":
        """Mint the dialing half from already-parsed locator pieces. A DIAL
        action's binding half borrows the pending URI first. Binding-internal."""
        return await cls._open_dialed_locator(
            host, transport_name, designator, transport,
        )._establish()

    @classmethod
    async def establish_accepted(
        cls,
        host: Host,
        transport_name: str,
        server_designator: str,
        transport,
        accepted_local_addr: str = "",
    ) -> "Session":
        """Mint the accepting half over a connection the caller's own listener
        produced. ``server_designator`` is the listener's signing designator
        (key for keyed-tcp/iroh; unused for tcp); ``accepted_local_addr`` is
        what accept reported. Signing designator/hint come from
        ``pancake_host_plan_accept`` (ADR-0078). Binding-internal."""
        t = transport_name.encode()
        server = server_designator.encode()
        local = accepted_local_addr.encode()
        tbuf, tptr = _byte_buf(t)
        sbuf, sptr = _byte_buf(server)
        lbuf, lptr = _byte_buf(local)
        plan = _AcceptPlan()
        _check_host(_host.pancake_host_plan_accept(
            tptr, len(t), sptr, len(server), lptr, len(local), ctypes.byref(plan),
        ))
        # Plan views borrow the caller buffers (or the static unreachable
        # placeholder); keep tbuf/sbuf/lbuf alive and pass those pointers
        # through — no second materialize (ADR-0078 / Rust establish_accepted).
        out = ctypes.c_void_p()
        _check_host(_host.pancake_host_session_open_accepted(
            host.raw, tptr, len(t),
            plan.designator, plan.designator_len,
            plan.direct_addresses_hint, plan.direct_addresses_hint_len,
            ctypes.byref(out),
        ))
        return await cls(out, host, transport)._establish()

    async def _establish(self) -> "Session":
        # Drive the freshly opened connection's keyed handshake to an open
        # session, abandoning the connection on any failure (release +
        # transport close) so a rude partner costs one accept, never the
        # listener. The read/feed loop lives in ``_pump._run_handshake``.
        try:
            await _pump._run_handshake(self)
            return self
        except BaseException:
            self.close_transport()
            raise

    # ── State: the consumer reads only `host`; the rest is a binding-internal
    # seam ──────────────────────────────────────────────────────────────────────
    # The underscore fields (`_ptr`, `_transport`, `_write_lock`,
    # `_hosted`, `_gc`, `_closing`, `_released`) are the private backing store.
    # The non-underscore accessors below are the binding-internal seam the pump,
    # trampoline, and GC reach through: a named tier between the public verbs and
    # the raw storage, so an owning module names the seam rather than reaching a
    # private field, and a consumer holding a Session still sees only the verbs
    # and `host`.

    @property
    def raw(self) -> ctypes.c_void_p:
        """The raw PancakeHostSession handle. Binding-internal seam: the Host's
        DIAL arm reports it through ``pancake_host_dialed``."""
        return self._ptr

    @property
    def host(self) -> Host:
        """The session's shared Host, its retained identity and gift
        registry, shared by every session of one Host so the gifter half of
        a handoff can reach a sibling session's keys. An application
        reads it to publish host-giftables (:meth:`Host.publish_giftable`),
        share one identity across dials, or set the redeem posture."""
        return self._host

    @property
    def released(self) -> bool:
        """Whether the host conn handle has been released. Binding-internal seam."""
        return self._released

    @property
    def closing_flag(self) -> bool:
        """The Session ``_closing`` flag alone (not ``released``). Binding-internal
        seam for the pump."""
        return self._closing

    @closing_flag.setter
    def closing_flag(self, value: bool) -> None:
        self._closing = value

    @property
    def is_closing(self) -> bool:
        """Whether teardown has begun: the ``_closing`` flag alone or a
        completed release. The Host's FAIL arm classifies a closing
        connection's breaks as the typed ERR_CLOSED. Binding-internal seam."""
        return self._closing or self._released

    @property
    def session_open(self) -> bool:
        """Whether the keyed handshake has completed and the session is open.
        Binding-internal seam for the pump."""
        return not self._released and _host.pancake_host_session_session_open(self._ptr) == 1

    @property
    def write_lock(self) -> asyncio.Lock:
        """Serializes transport writes. Binding-internal seam for the pump."""
        return self._write_lock

    @property
    def transport(self):
        """Byte-channel transport. Binding-internal seam for the pump."""
        return self._transport

    @property
    def gc(self):
        """Per-session GC state. Binding-internal seam for promise fetch track."""
        return self._gc

    @property
    def hosted(self) -> "dict[int, int]":
        """Export position → trampoline ctx. Binding-internal seam for trampoline."""
        return self._hosted

    def schedule_on_loop(self, run) -> None:
        """Hop ``run`` onto this session's event loop (finalizer → drain).
        Binding-internal seam for GcHandle."""
        loop = self._loop
        if loop is None:
            return
        try:
            loop.call_soon_threadsafe(run)
        except RuntimeError:
            pass  # the loop is closed; teardown reclaims the partner's export

    def guard_open(self) -> None:
        """Raise ERR_CLOSED when the connection is released. Binding-internal
        seam."""
        if self._released:
            raise PancakeError(_ERR_CLOSED, "connection closed")

    # ── The pump ────────────────────────────────────────────────────────────────

    def serve(self) -> "asyncio.Task":
        """Run the inbound loop as a background task: read raw bytes, hand them
        to the core's stream delimiter (behaviors run and vow completions queue
        inside the feed), and drain the action queue. The task completes when
        the CapTP session closes cleanly; started once."""
        if self._serve_task is None:
            self._serve_task = asyncio.get_running_loop().create_task(
                _pump._serve_loop(self),
            )
        return self._serve_task

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of this CapTP session's most recent local dispatch
        failure, or ``None`` when none has been recorded. The flat per-feed
        error code names the failure family; this names the member. Errors
        raised by a refused feed carry it already as ``err.abort``."""
        return _pump.last_abort(self)

    async def flush_outbound(self) -> None:
        """Drain every encoded outbound frame on this CapTP session and write it
        to the transport — how a FLUSH action lands. Writes are serialized, so
        frames stay whole and in submission order. Binding-internal."""
        await _pump.flush_outbound(self)

    # ── Teardown ────────────────────────────────────────────────────────────────

    async def close(self) -> None:
        """Close the session and every exporter connection its Host dialed
        for handoffs. A running :meth:`serve` completes cleanly; pending vows
        settle with the typed ERR_CLOSED."""
        self._closing = True
        self._host.close_exporters()
        self.close_transport()
        task = self._serve_task
        if task is not None and task is not asyncio.current_task():
            try:
                await task
            except (asyncio.CancelledError, OSError, PancakeException):
                pass

    def close_transport(self) -> None:
        """Close just this session, without touching the Host's other
        sessions: stop the transport first, then retire the Host's entry and
        free the host handle (its still-parked far vows break inside the
        release, classified as closure), so no foreign call touches a freed
        session. Called from inside a behavior callback — where the C tier
        refuses the release — it parks the release on the Host; the enclosing
        feed's unwind runs it, so a mid-turn close never leaks the handle.
        Binding-internal."""
        self._closing = True
        try:
            self._transport.close()
        except Exception:
            pass  # already closed
        if self._released:
            return
        self._released = True
        self._host.unregister_session(self._key)
        # The host can never deliver to this session's hosted objects again;
        # drop their trampoline entries so the registry does not pin dead
        # behaviors. Host-wide giftables live on the host, untouched here.
        for ctx in self._hosted.values():
            _unregister_behavior(ctx)
        self._hosted.clear()
        ptr = self._ptr
        self._ptr = None
        if _inside_turn():
            self._host.park_release(lambda: _host.pancake_host_session_release(ptr))
        else:
            _host.pancake_host_session_release(ptr)
        # The release queued FAIL completions (and sibling withdraws may have
        # failed closed): route them now.
        self._host.schedule_kick()

    async def __aenter__(self) -> "Session":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    # ── Hosting: spawn, publish, and the proxy verbs ───────────────────────────

    def spawn(self, behavior: Behavior) -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback. The
        position comes from the session's one export allocator, so it can never
        alias a bootstrap or resolver export. Callable from inside a served
        turn (a factory's ``create`` minting the task it replies with)."""
        return _spawn_hosted(self, behavior)

    def publish(self, name: str, behavior: Behavior) -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        return _publish_hosted(self, name, behavior)

    def caretaker(self, target: Ref) -> Caretaker:
        """Wrap ``target`` (local or far) in a revocable caretaker (ADR-0064).
        Returns a :class:`Caretaker` whose ``proxy`` is an ordinary capability
        to hand a partner; every call through it forwards to ``target`` until
        :meth:`Caretaker.revoke`, after which each breaks with ``Revoked``.
        ``target`` may be a capability imported over the wire — the proxy
        forwards transparently — so this hands out a revocable view of
        authority you do not own locally. The proxy is a plain spawned actor,
        so it answers a local call exactly as a partner's does."""
        return _caretaker_proxy(self.spawn, target)

    def attenuate(self, target: Ref, verbs: "list[str]") -> Ref:
        """Wrap ``target`` (local or far) in an attenuator (ADR-0064): a proxy
        that forwards only the calls whose verb is in ``verbs`` and breaks
        every other with ``Attenuated``. Returns the proxy capability to hand a
        partner. The proxy is a plain spawned actor."""
        return _attenuate_proxy(self.spawn, target, verbs)

    # ── The application verbs ───────────────────────────────────────────────────

    async def fetch(self, name: str) -> Ref:
        """Fetch a partner's published capability by ``name``. Returns a
        :class:`Ref` you can ``send`` to. The canonical fetch lives in the
        library: one call registers the bootstrap import, allocates the answer,
        and queues the deliver; the host enrolls the fulfilled capability under
        a node-unique token (ADR-0069) before the completion is queued, so a
        return re-gifts the right home. Starts the inbound loop itself, so a
        ``fetch`` straight after ``connect`` works without a separate
        :meth:`serve` call. Raises :class:`VowBroken` when the partner breaks
        the fetch, and :class:`FetchFailed` when it fulfills with something
        that is not a live capability."""
        return await _fetch_like(
            self, name.encode(), name, _host.pancake_host_session_fetch, track=True,
        )

    async def enliven(self, sturdyref: str) -> Ref:
        """Enliven a sturdyref against this session (ADR-0012): bring the
        durable ``(peer, swissnum)`` to life as a live :class:`Ref`. Parses
        ``sturdyref`` for its swissnum, then fetches it through the host's
        dedup cache -- a repeat enliven of the same swissnum on this session
        short-circuits with no wire traffic (its completion is queued before
        the minting call returns). The session must already be open to the
        sturdyref's peer; the sans-io core tracks no remote locator and never
        dials. Raises :class:`VowBroken` when the partner breaks the enliven,
        and :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        swiss = parse_locator(sturdyref, sturdyref=True).swissnum.encode()
        return await _fetch_like(
            self, swiss, sturdyref, _host.pancake_host_session_enliven, track=False,
        )

    def send(self, target: "Ref | RemotePromise", verb: str, args: "Optional[list]" = None) -> RemotePromise:
        """Eventual-send ``verb(args)`` to ``target`` and return a
        :class:`RemotePromise` for the reply. ``await`` it for the value (a
        :class:`Ref` if the partner returned a capability; raises
        :class:`VowBroken` on a partner break).

        ``target`` is a capability :class:`Ref` *or* a :class:`RemotePromise`
        from an earlier send: passing the latter pipelines (ADR-0007) -- the
        call is addressed at the answer that send will resolve, so a dependent
        chain costs one round trip instead of one per link. ``args`` may
        contain :class:`Ref`\\ s. A :class:`Ref` this session spawned runs
        in process; a partner's rides the wire, and a redeemed or fetched token
        routes to the exporter connection that hosts it, transparently.

        The deliver is queued now; its bytes leave the wire when the returned
        handle -- or any send pipelined behind it -- is first observed (awaited
        or gathered), so a pipelined batch travels together."""
        self.guard_open()
        self._gc.drain_gc()
        args = list(args or [])
        return _dispatch_send(self, target, verb, args)

    async def tell(self, target: Ref, verb: str, args: "Optional[list]" = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        self.guard_open()
        self._gc.drain_gc()
        args = list(args or [])
        await _dispatch_tell(self, target, verb, args)

    def set_exporter_locator(self, raw_locator: bytes) -> None:
        """Record the verbatim exporter-location bytes (from
        :func:`encode_peer_locator`) the gifter embeds when *this* connection
        is the exporter side of a handoff this host originates (ADR-0009).
        Needed when the partner's signed location is not dialable on its own —
        an iroh partner signs only its node id, so a gifter that learned the
        exporter's ``direct-addresses`` out of band sets the full locator here.
        Unset, origination falls back to the partner's signed location."""
        self.guard_open()
        # Empty unsets the override; keep the NULL the header documents there.
        buf, ptr = _byte_buf(raw_locator) if raw_locator else (None, None)
        _check_host(_host.pancake_host_session_set_exporter_location(
            self._ptr, ptr, len(raw_locator),
        ))

    # ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

    def with_gc(self) -> "Session":
        """Opt this session into distributed GC (ADR-0063), off by default.
        Once on, a far capability returned by :meth:`fetch` releases its import
        to the partner -- a single ``op:gc-exports`` delta, routed through the
        host to the import's home connection -- when the runtime reclaims the
        last :class:`Ref` to it, so the partner can release the matching
        export. CPython's refcounting makes that release prompt on the last
        ``del``. Capabilities lifted elsewhere (a ``send`` reply, a delivered
        argument, an ``enliven`` result the dedup cache owns) are outside this
        seam. Returns ``self`` for chaining."""
        self._gc.enable()
        return self
