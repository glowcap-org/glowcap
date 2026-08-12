"""Internal: the asyncio face of the driver archive (ADR-0112).

One thread drives one native loop, and this wrapper is that thread's
choreography: park the running asyncio loop on the archive's one readiness
descriptor (``add_reader``), step with a zero timeout when it signals, and
drain the one event queue into futures. Provider starts are nonblocking, while
transport completion and CapTP handshakes advance through those steps. Sessions
arrive as OPENED and ACCEPTED events carrying real ``PancakeHostSession``
handles, so every ``pancake_host_*`` verb (bound in :mod:`pancake._ffi_host`
against this same library) works on them unchanged.

This tier drives the statically composed providers plus sidecar transports
plugged in as multiplexed transports. Dial planning belongs to the host core; this
module starts an already-resolved native plan on a driver loop. The byte-fed
pump remains only for keyed-relay and other explicitly low-level seams that
are not native driver providers.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
from typing import TYPE_CHECKING, Optional, Union

if TYPE_CHECKING:
    from ._host import Host

from . import _constants as _c
from ._codec import _codec_id
from ._errors import _check_host, PancakeError, VowBroken
from ._ffi_driver import (
    _driver,
    _DriverEvent,
    _DriverOptions,
    _TransportProvider,
)
from ._ffi_host import _host
from ._host_action_gen import HOST_ACTION_SETTLE, Fail, Settle, decode
from ._locator import _OwnedLocator, Locator, parse_locator
from ._trampoline import _enter_deliver, _exit_deliver, _inside_turn

# Wakes every parked `accept` when the loop closes, so a server iteration ends
# instead of waiting on a queue nothing will ever feed again.
_ACCEPTS_CLOSED = object()


def _dial_failure(message: str) -> PancakeError:
    """Classify an OPEN_FAILED event. The loop reports an admitted dial's failure
    by error name; a handshake or settle budget overrun becomes the typed
    timeout the public dial contract promises, everything else is I/O."""
    if message in ("HandshakeTimedOut", "WaitTimedOut"):
        return PancakeError(
            _c.ERR_TIMEOUT,
            "the partner did not finish the OCapN handshake within the loop's handshake budget",
        )
    return PancakeError(_c.ERR_IO, f"dial failed: {message}")


def _driver_options(
    wire_buffer_bytes: int,
    max_pending_opens: int,
    handshake_ms: int,
    settle_ms: int,
) -> _DriverOptions:
    limits = (
        ("wire_buffer_bytes", wire_buffer_bytes, ctypes.c_size_t(-1).value),
        ("max_pending_opens", max_pending_opens, ctypes.c_size_t(-1).value),
        ("handshake_ms", handshake_ms, _c.DRIVER_MAX_WAIT_MS),
        ("settle_ms", settle_ms, _c.DRIVER_MAX_WAIT_MS),
    )
    for name, value, maximum in limits:
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0 or value > maximum:
            raise PancakeError(
                _c.ERR_INVALID_ARGUMENT,
                f"{name} must be a positive integer no greater than {maximum}",
            )
    return _DriverOptions(
        _c.DRIVER_OPTIONS_ABI_VERSION,
        ctypes.sizeof(_DriverOptions),
        wire_buffer_bytes,
        max_pending_opens,
        handshake_ms,
        settle_ms,
    )


def _last_driver_error() -> Optional[str]:
    buf = ctypes.create_string_buffer(512)
    n = _driver.pancake_driver_last_error(buf, len(buf))
    if n == 0:
        return None
    return buf.raw[: min(n, len(buf))].split(b"\x00", 1)[0].decode("utf-8", "replace")


def _check(rc: int) -> None:
    if rc != _c.OK:
        raise PancakeError(rc, _last_driver_error())


class _StepDeliverContext:
    """What a loop step's behavior callbacks read as the arriving deliver
    context. The byte-fed pump brackets its synchronous feed with the arriving
    :class:`Session`, and the trampoline reads ``.host`` off that bracket to
    latch the turn to its Host (turn-time spawn) and to own an async
    behavior's deferral. A loop step is the feed here, so it brackets itself
    with this carrier over the loop's adopted wrapper Host."""

    __slots__ = ("host",)

    def __init__(self, host) -> None:
        self.host = host


class LoopEvent:
    """One drained loop event, in owned form (the C views die at the next
    pop, so byte payloads are copied out here)."""

    __slots__ = ("kind", "ticket", "session", "message", "settled_ok", "decoded")

    def __init__(
        self,
        kind: int,
        ticket: int,
        session: Optional[int],
        message: str = "",
        settled_ok: bool = False,
        decoded: object = None,
    ) -> None:
        self.kind = kind
        self.ticket = ticket
        self.session = session
        self.message = message
        self.settled_ok = settled_ok
        self.decoded = decoded


class ListenerOwner:
    """Ownership of exactly one native driver listener.

    The owner closes admission for its listener and releases only accepted
    handles that have not crossed into a public Session. It never owns the
    loop, Host, or sibling listeners.
    """

    __slots__ = ("_loop", "listener", "_closed")

    def __init__(self, loop: "DriverLoop", listener: int) -> None:
        self._loop = loop
        self.listener = listener
        self._closed = False

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._loop._released:
            return
        self._loop.close_listener(self.listener)


class DriverLoop:
    """One stepping native loop over one multi-session host.

    Construct with :meth:`open` on the asyncio thread that will drive it,
    ``await start()`` to park on the readiness descriptor, and ``await
    close()`` before dropping it. ``host`` is a real ``PancakeHost`` handle
    for every application verb.
    """

    def __init__(self, handle: int, host: int) -> None:
        self._h = ctypes.c_void_p(handle)
        self._host = ctypes.c_void_p(host)
        self._aio: Optional[asyncio.AbstractEventLoop] = None
        self._fd: Optional[int] = None
        self._stepping = False
        self._pending_dials: dict[int, asyncio.Future[int]] = {}
        self._dial_timer: Optional[asyncio.TimerHandle] = None
        self._completions: dict[int, asyncio.Future[bool]] = {}
        self._accepts: "dict[int, asyncio.Queue[Union[int, object]]]" = {}
        self._unclaimed_sessions: dict[int, bool] = {}
        self._open_sessions: set[int] = set()
        self._close_requested = False
        self._wrapper: "Optional[Host]" = None
        self._seed_material: Optional[bytes] = None
        self._codec = "syrup"
        self._released = False
        self._started = False
        self._closed_event = asyncio.Event()

    # ── Lifecycle ────────────────────────────────────────────────────────────

    @classmethod
    def open(
        cls,
        seed: Optional[bytes] = None,
        *,
        codec: str = "syrup",
        frame_cap: int = 1 << 16,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Create the loop. ``seed`` is the host constructor's 64-byte
        contract (durable identity, then a fresh session-key root); ``None``
        draws both halves fresh."""
        options = _driver_options(wire_buffer_bytes, max_pending_opens, handshake_ms, settle_ms)
        material = seed if seed is not None else secrets.token_bytes(64)
        if len(material) != 64:
            raise PancakeError(_c.ERR_INVALID_ARGUMENT, "seed must be 64 bytes")
        host = ctypes.c_void_p(None)
        _check_host(
            _host.pancake_host_new(
                material,
                len(material),
                frame_cap,
                1,
                _codec_id(codec),
                _c.CAPTP_V1_0,
                _c.FEATURE_FULL,
                0,
                ctypes.byref(host),
            )
        )
        assert host.value is not None
        slot = ctypes.c_void_p(None)
        try:
            _check(
                _driver.pancake_driver_take_host(
                    host,
                    ctypes.byref(options),
                    ctypes.byref(slot),
                )
            )
        except BaseException:
            _host.pancake_host_release(host)
            raise
        assert slot.value is not None
        loop = cls(slot.value, host.value)
        loop._seed_material = material
        loop._codec = codec
        return loop

    @classmethod
    def take_host(
        cls,
        host: "Host",
        *,
        wire_buffer_bytes: int = _c.DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        max_pending_opens: int = _c.DRIVER_DEFAULT_MAX_PENDING_OPENS,
        handshake_ms: int = _c.DRIVER_DEFAULT_HANDSHAKE_MS,
        settle_ms: int = _c.DRIVER_DEFAULT_SETTLE_MS,
    ) -> "DriverLoop":
        """Transfer a byte-fed Host into a native driver transactionally.

        ``pancake_driver_take_host`` is called before the Python Host changes
        state. On failure the caller still owns the original Host; on success
        this exact Host wrapper becomes the loop's application face and the
        loop becomes its sole native release authority.
        """
        if getattr(host, "_loop_mode", False):
            raise PancakeError(_c.ERR_INVALID_ARGUMENT, "host already belongs to a driver loop")
        raw = host.raw
        options = _driver_options(wire_buffer_bytes, max_pending_opens, handshake_ms, settle_ms)
        out = ctypes.c_void_p(None)
        _check(
            _driver.pancake_driver_take_host(
                raw,
                ctypes.byref(options),
                ctypes.byref(out),
            )
        )
        assert out.value is not None
        loop = cls(out.value, raw.value)
        loop._codec = host.codec
        loop._wrapper = host
        host._adopt_driver_loop(loop)
        return loop

    @property
    def host(self) -> ctypes.c_void_p:
        """The wrapped ``PancakeHost`` handle for ``pancake_host_*`` verbs.
        Never release it separately; ``close`` releases the loop and the
        host together."""
        return self._host

    def schedule_step(self) -> None:
        """Schedule one loop step soon, from the driving thread — how a
        wrapper verb's kick reaches the drain. A thread-driven loop (no
        :meth:`start`) pumps continuously and needs no nudge."""
        if self._released:
            return
        if self._aio is not None:
            self._aio.call_soon(self.step_now)

    def _native_session_release(self, ptr: ctypes.c_void_p) -> None:
        value = ptr.value
        if value is not None:
            self._unclaimed_sessions.pop(value, None)
            self._open_sessions.discard(value)
        if self._released:
            return
        _check(_driver.pancake_driver_session_release(self._h, ptr))
        if self._close_requested and not self._open_sessions:
            self.close()

    def request_close(self) -> None:
        """Retire this loop after its application-owned sessions close.

        Listener owners seal admission before calling this. Existing Session
        wrappers retain the loop until their own close reaches
        ``_native_session_release``; a loop with no yielded sessions closes
        immediately.
        """
        if self._released or self._close_requested:
            return
        self._close_requested = True
        if not self._open_sessions:
            self.close()

    async def connect_session(
        self,
        locator: Union[Locator, str],
    ):
        """Dial through the loop and wrap the opened session as the public
        :class:`pancake.Session`, over the adopted wrapper Host: every session
        verb, promise, and trampoline works on it, with the native loop as
        the transport and the drain."""
        ptr = await self.dial(locator)
        return self.adopt_session(ptr)

    def adopt_session(self, ptr: int):
        """Transfer one event-delivered native handle into a Session wrapper."""
        from ._session import Session

        host = self.wrapper_host()
        existing = host.get_session(ptr)
        if existing is not None:
            return existing
        closed = self._unclaimed_sessions.pop(ptr, False)
        self._open_sessions.add(ptr)
        transport = _LoopTransport(self, ptr)
        session = Session(ctypes.c_void_p(ptr), host, transport)
        if closed:
            transport.mark_closed()
            session.close_transport()
        return session

    def wrapper_host(self) -> "Host":
        """The public :class:`pancake.Host` wrapper adopted over this loop's
        native host (ADR-0112): application verbs, publish trampolines, and
        ``RemotePromise`` settles all work on it, while the loop stays the one
        action drain and the one release authority. Built on first call; call
        it on the driving thread."""
        if self._wrapper is None:
            from ._host import Host

            assert self._seed_material is not None
            self._wrapper = Host(
                seed=self._seed_material[:32],
                codec=self._codec,
                _adopt_raw=self.host.value,
            )
            self._wrapper._driver_loop = self
        return self._wrapper

    def close(self) -> None:
        """Stop stepping and release the loop, its sessions, and its host."""
        if self._released:
            return
        if self._wrapper is not None:
            self._wrapper.close_sessions()
            self._wrapper._fail_outstanding_vows("host released")
            self._wrapper._release_started = True
        self._released = True
        if self._aio is not None and self._fd is not None:
            self._aio.remove_reader(self._fd)
        for listener in list(self._accepts):
            self._release_unclaimed(listener)
        for accepts in self._accepts.values():
            accepts.put_nowait(_ACCEPTS_CLOSED)
        for future in self._pending_dials.values():
            if not future.done():
                future.set_exception(PancakeError(_c.ERR_CLOSED, "the loop is closed"))
        self._pending_dials.clear()
        if self._dial_timer is not None:
            self._dial_timer.cancel()
            self._dial_timer = None
        try:
            _check(_driver.pancake_driver_release(self._h))
            if self._wrapper is not None:
                # Native release is the transfer's terminal boundary. Retire
                # wrapper-owned callbacks and its Context borrow only after
                # every native allocation has reached that allocator's free.
                self._wrapper._driver_did_release()
        finally:
            self._closed_event.set()

    async def wait_closed(self) -> None:
        """Wait until native loop and resident ownership have been released."""
        await self._closed_event.wait()

    def session_release(self, session: int) -> None:
        """Release one loop-owned session: the loop spelling of
        ``pancake_host_session_release``, which must not be called on
        sessions this loop minted."""
        _check(_driver.pancake_driver_session_release(self._h, ctypes.c_void_p(session)))

    # ── Extension transports ────────────────────────────────────────────────

    def _install_provider(self, prepare) -> None:
        """Install one package while its archive-owned construction owner is live.

        ``prepare`` receives a registrar valid only for the dynamic extent of
        this call, so copied callback tables cannot escape independently of
        the object they borrow.
        """
        registered = False
        active = True

        def register(package: _TransportProvider) -> None:
            nonlocal registered
            if not active or registered:
                raise RuntimeError("provider registrar is no longer active")
            _check(_driver.pancake_driver_add_provider(self._h, ctypes.byref(package)))
            registered = True

        try:
            prepare(register)
            if not registered:
                raise RuntimeError("provider installer did not register a package")
        finally:
            active = False

    def _has_transport(self, transport: Union[str, bytes]) -> bool:
        """Ask the native provider registry whether ``transport`` is owned."""
        name = transport.encode() if isinstance(transport, str) else transport
        present = ctypes.c_uint8(0)
        _check(
            _driver.pancake_driver_has_transport(
                self._h, name, len(name), ctypes.byref(present)
            )
        )
        return present.value != 0

    # ── Parking and stepping ─────────────────────────────────────────────────

    async def start(self) -> None:
        """Arm the readiness descriptor and park the running asyncio loop on
        it. From here the loop steps whenever native work is ready."""
        if self._started:
            return
        self._aio = asyncio.get_running_loop()
        fd = ctypes.c_int32(-1)
        _check(_driver.pancake_driver_readiness_fd(self._h, ctypes.byref(fd)))
        self._fd = fd.value
        self._aio.add_reader(self._fd, self._on_ready)
        self._started = True

    def _on_ready(self) -> None:
        if self._stepping or self._released or _inside_turn():
            return
        self.step_now()

    def step_now(self) -> None:
        """Drain zero-timeout steps and events through quiescence on the loop
        thread. Call after ``pancake_host_*`` verbs so queued flushes reach the
        wire before the next park."""
        self.step(0)

    def step(self, timeout_ms: int) -> None:
        """Wait up to ``timeout_ms``, then drain steps and events through
        quiescence. This is the whole pump for a loop driven by a plain thread
        instead of asyncio (a server that never calls :meth:`start`)."""
        if self._released or self._stepping or _inside_turn():
            return
        self._stepping = True
        try:
            wait_ms = timeout_ms
            while self._step_native(wait_ms):
                self._dispatch_many(self._pop_events())
                if self._wrapper is not None:
                    self._wrapper.drain_parked_releases()
                if self._released:
                    return
                wait_ms = 0
        finally:
            self._stepping = False

    def _step_native(self, timeout_ms: int) -> bool:
        """One native step, bracketed as the deliver it is: behaviors fire
        inside it, and the trampoline reads the bracket to latch their turns
        to this loop's wrapper Host. ``False`` is successful quiescence."""
        if self._wrapper is None:
            rc = _driver.pancake_driver_step(self._h, timeout_ms)
        else:
            prior = _enter_deliver(_StepDeliverContext(self._wrapper))
            try:
                rc = _driver.pancake_driver_step(self._h, timeout_ms)
            finally:
                _exit_deliver(prior)
        if rc == _c.WOULD_BLOCK:
            return False
        _check(rc)
        return True

    def _pop_events(self) -> list[LoopEvent]:
        out: list[LoopEvent] = []
        event = _DriverEvent()
        while True:
            rc = _driver.pancake_driver_next_event(self._h, ctypes.byref(event))
            if rc == _c.WOULD_BLOCK:
                return out
            _check(rc)
            message = ""
            settled_ok = False
            ticket = event.ticket
            if event.kind == _c.DRIVER_EVENT_OPEN_FAILED and event.message:
                message = ctypes.string_at(event.message, event.message_len).decode(
                    "utf-8", "replace"
                )
            decoded: object = None
            if event.kind == _c.DRIVER_EVENT_COMPLETION:
                ticket = event.action.ticket
                settled_ok = event.action.kind == HOST_ACTION_SETTLE
                # Decode into owned Python values while the C views are live
                # (they die at the next pop): the same generated decoder the
                # byte-fed drain uses, so a wrapper-routed settle carries the
                # same value shapes.
                decoded = decode(event.action)
                if not settled_ok and event.action.message:
                    message = ctypes.string_at(
                        event.action.message, event.action.message_len
                    ).decode("utf-8", "replace")
            out.append(
                LoopEvent(event.kind, ticket, event.session, message, settled_ok, decoded)
            )

    def _dispatch_many(self, events: list[LoopEvent]) -> None:
        for event in events:
            self._dispatch(event)
        if self._wrapper is not None and events:
            # A behavior that closed its session inside a step parked the
            # release (the C tier refuses mid-callback); the loop is the
            # feed here, so it drains the park the way the pump does.
            self._wrapper.drain_parked_releases()

    def _dispatch(self, event: LoopEvent) -> None:
        if event.kind == _c.DRIVER_EVENT_OPENED:
            future = self._pending_dials.pop(event.ticket, None)
            if future is not None and not future.done():
                assert event.session is not None
                self._unclaimed_sessions[event.session] = False
                future.set_result(event.session)
            elif event.session is not None:
                self._native_session_release(ctypes.c_void_p(event.session))
        elif event.kind == _c.DRIVER_EVENT_OPEN_FAILED:
            future = self._pending_dials.pop(event.ticket, None)
            if future is not None and not future.done():
                future.set_exception(_dial_failure(event.message))
        elif event.kind == _c.DRIVER_EVENT_ACCEPTED:
            if event.session is not None:
                accepts = self._accepts.get(event.ticket)
                if accepts is not None:
                    self._unclaimed_sessions[event.session] = False
                    accepts.put_nowait(event.session)
                else:
                    self._native_session_release(ctypes.c_void_p(event.session))
                    raise PancakeError(
                        _c.ERR_INTERNAL,
                        f"accepted session names unknown listener {event.ticket}",
                    )
        elif event.kind == _c.DRIVER_EVENT_SESSION_CLOSED:
            if event.session is not None:
                wrapped = (
                    self._wrapper.get_session(event.session)
                    if self._wrapper is not None
                    else None
                )
                if wrapped is not None:
                    # The pump's EOF choreography, one tier up: mark
                    # teardown first (ordered before this wire's FAIL
                    # completions, so they classify as the typed closed
                    # error), end the serve task, then release the dead
                    # session so a later verb refuses ERR_CLOSED instead
                    # of minting a vow nothing can settle. The native
                    # side already broke the far vows in its close.
                    wrapped.closing_flag = True
                    transport = wrapped.transport
                    if isinstance(transport, _LoopTransport):
                        transport.mark_closed()
                    wrapped.close_transport()
                elif event.session in self._unclaimed_sessions:
                    self._unclaimed_sessions[event.session] = True
                else:
                    self._native_session_release(ctypes.c_void_p(event.session))
        elif event.kind == _c.DRIVER_EVENT_COMPLETION:
            if self._wrapper is not None and isinstance(event.decoded, (Settle, Fail)):
                # The wrapper's vow table is the byte-fed drain's, one tier
                # up: SETTLE fulfills, FAIL classifies a teardown break as the
                # typed closed error and everything else as a partner break.
                host = self._wrapper
                if isinstance(event.decoded, Settle):
                    host.settle_vow(event.decoded.ticket, True, event.decoded.value)
                else:
                    if host.vow_session_closing(event.decoded.ticket):
                        failure: Exception = PancakeError(
                            _c.ERR_CLOSED, "the session closed before the vow settled"
                        )
                    else:
                        failure = VowBroken(event.decoded.message)
                    host.settle_vow(event.decoded.ticket, False, failure)
            done = self._completions.pop(event.ticket, None)
            if done is not None and not done.done():
                if event.settled_ok:
                    done.set_result(True)
                else:
                    done.set_exception(PancakeError(_c.ERR_IO, f"vow failed: {event.message}"))

    # ── Dial, accept, listen ─────────────────────────────────────────────────

    async def dial(
        self,
        locator: Union[Locator, str],
    ) -> int:
        """Begin a nonblocking dial and await its session handle. Connect
        completion and the handshake advance through zero-timeout native steps
        on the event-loop thread."""
        assert self._aio is not None, "call start() before dial()"
        owned = parse_locator(locator) if isinstance(locator, str) else Locator(
            locator.transport,
            locator.designator,
            dict(locator.hints),
            locator.hint_wire_form,
        )
        future: asyncio.Future[int] = self._aio.create_future()
        self._begin_dial(owned, future)
        self.schedule_step()
        self._arm_dial_timer()
        return await future

    def _begin_dial(
        self,
        locator: Locator,
        future: "asyncio.Future[int]",
    ) -> None:
        ticket = ctypes.c_uint64(0)
        with _OwnedLocator.create(locator) as owned:
            _check(
                _driver.pancake_driver_dial(
                    self._h, owned.borrow_view(), ctypes.byref(ticket)
                )
            )
        self._pending_dials[ticket.value] = future

    def _arm_dial_timer(self) -> None:
        """Keep handshake deadlines observable when no fd becomes readable."""
        if self._aio is None or self._dial_timer is not None or self._released:
            return

        def tick() -> None:
            self._dial_timer = None
            if self._released or not self._pending_dials:
                return
            self.step_now()
            self._arm_dial_timer()

        self._dial_timer = self._aio.call_later(0.05, tick)

    async def accept(self, listener: int) -> int:
        """Await the next accepted session handle (bind a listener first).
        Raises the typed ``ERR_CLOSED`` once the loop closes, so a server
        iteration ends rather than parking forever."""
        accepts = self._accepts.get(listener)
        if accepts is None:
            raise PancakeError(_c.ERR_CLOSED, "the listener is closed")
        if self._released:
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        item = await accepts.get()
        if not isinstance(item, int):
            # The close sentinel: re-arm it so every sibling accept ends too.
            accepts.put_nowait(_ACCEPTS_CLOSED)
            raise PancakeError(_c.ERR_CLOSED, "the loop is closed")
        return item

    def listen(self, transport: Union[str, bytes], designator: Union[str, bytes]) -> int:
        transport_b = transport.encode() if isinstance(transport, str) else transport
        designator_b = designator.encode() if isinstance(designator, str) else designator
        listener = ctypes.c_uint64(0)
        _check(
            _driver.pancake_driver_listen(
                self._h,
                transport_b,
                len(transport_b),
                designator_b,
                len(designator_b),
                ctypes.byref(listener),
            )
        )
        self._accepts[listener.value] = asyncio.Queue()
        return ListenerOwner(self, listener.value)

    def _listener_id(self, listener: Union[int, "ListenerOwner"]) -> int:
        return listener.listener if isinstance(listener, ListenerOwner) else listener

    def listener_locator(self, listener: int) -> Locator:
        """Copy the listener's complete typed OCapN locator."""
        listener = self._listener_id(listener)
        from ._ffi_ocapn import _LocatorView

        view = _LocatorView()
        _check(_driver.pancake_driver_listener_locator(self._h, listener, ctypes.byref(view)))
        with _OwnedLocator.clone_view(ctypes.byref(view)) as owned:
            return owned.value()

    def advertise_listener(self, listener: int, locator: Union[Locator, str]) -> None:
        """Replace this listener's advertised locator through its native owner."""
        listener = self._listener_id(listener)
        parsed = parse_locator(locator) if isinstance(locator, str) else locator
        with _OwnedLocator.create(parsed) as owned:
            _check(
                _driver.pancake_driver_listener_advertise(
                    self._h, listener, owned.borrow_view()
                )
            )

    def select_listener(self, listener: int) -> None:
        """Select this listener's locator as the Host's acceptable location."""
        _check(_driver.pancake_driver_listener_select(self._h, self._listener_id(listener)))

    def close_listener(self, listener: int) -> None:
        """Stop one listener after preserving already committed accepts."""
        listener = self._listener_id(listener)
        if listener not in self._accepts:
            return
        _check(_driver.pancake_driver_listener_close(self._h, listener))
        self._dispatch_many(self._pop_events())
        accepts = self._accepts.get(listener)
        if accepts is not None:
            self._release_unclaimed(listener)
            accepts.put_nowait(_ACCEPTS_CLOSED)

    def _release_unclaimed(self, listener: int) -> None:
        accepts = self._accepts.get(listener)
        if accepts is None:
            return
        while True:
            try:
                item = accepts.get_nowait()
            except asyncio.QueueEmpty:
                return
            if isinstance(item, int):
                self._native_session_release(ctypes.c_void_p(item))

    # ── Vows ─────────────────────────────────────────────────────────────────

    def completion(self, vow: int) -> "asyncio.Future[bool]":
        """A future settled by the vow's COMPLETION event (True on SETTLE;
        FAIL raises). Register before the next step."""
        assert self._aio is not None, "call start() before completion()"
        future: asyncio.Future[bool] = self._aio.create_future()
        self._completions[vow] = future
        return future

    async def accept_session(self, listener: Union[int, "ListenerOwner"]):
        """Await the next accepted session, wrapped as the public
        :class:`pancake.Session` over the adopted wrapper Host — the
        accept-side twin of :meth:`connect_session`. The handshake already
        ran inside the accepting step; the session arrives open."""
        ptr = await self.accept(self._listener_id(listener))
        return self.adopt_session(ptr)


class _LoopTransport:
    """The loop-backed :class:`pancake.Session` transport duck: no byte verbs
    (the native loop owns the wire), one closed event the serve task and
    ``wait_closed`` share, and the back-reference `Session`'s branched arms
    dispatch on. Constructed on the asyncio thread that drives the loop."""

    def __init__(self, driver_loop: DriverLoop, ptr: int) -> None:
        self._driver_loop = driver_loop
        self._ptr = ptr
        self._closed = asyncio.Event()

    def mark_closed(self) -> None:
        self._closed.set()

    def close(self) -> None:
        self._closed.set()

    async def wait_closed(self) -> None:
        await self._closed.wait()


async def dial_shared_loop(
    driver_loop: "DriverLoop",
    locator: Locator,
):
    """Begin one dial through an already-composed provider package."""
    if not driver_loop._has_transport(locator.transport):
        raise PancakeError(
            _c.ERR_INVALID_ARGUMENT,
            f"the native loop has no registered provider for {locator.transport!r}",
        )
    return await driver_loop.connect_session(locator)
