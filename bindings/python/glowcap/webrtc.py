"""Optional WebRTC dial and listen for the asyncio driver loop.

``provider(signaling, config)`` installs the WebRTC archive's provider package.
A ``webrtc`` locator then dials through the ordinary ``Runtime.connect``. The
archive runs each dial as one signaling exchange and asks the application to
carry it, so the application owns the signaling channel and glowcap owns
everything after it. ``listen(signaling, config, options)`` composes the same
package into a Host that answers: the application hands each inbound offer to
``Server.provide_offer``, and iterating the server yields the session once the
channel opens. Python loads the WebRTC archive only when a program calls
``provider`` or ``listen``.

A dial whose answer never arrives fails at the driver's handshake deadline.
When ``offer`` or ``candidate`` fails after the dial began, the binding records
that error as a callerless failure on the Host and gives the dial up, so it
fails at the driver's next step with ``SignalingFailed`` instead. A callback
that raises before returning refuses the dial at once.
"""

from __future__ import annotations

import asyncio
import ctypes
from dataclasses import dataclass, field
import inspect
from typing import Awaitable, Callable, Optional, Protocol

from . import _constants as _c
from ._abi_value import _DEFAULT_CODEC
from ._constants import TRANSPORT_WEBRTC
from ._errors import GlowcapError
from ._ffi_ocapn import _read_last_error, _str_buf
from ._ffi_webrtc import (
    _webrtc,
    _WebrtcConfig,
    _WebrtcExchangeDoneFn,
    _WebrtcIceServer,
    _WebrtcSendAnswerFn,
    _WebrtcSendCandidateFn,
    _WebrtcSendOfferFn,
    _WebrtcSignaling,
    _WebrtcStringView,
)
from ._locator import Locator
from ._ffi import FfiHandle, _FfiHandleOwner
from ._host import Host
from ._server import (
    DriverServer,
    _rollback_listener_construction,
    listener_seed,
    prepare_driver_loop,
)
from ._transport import (
    Provider,
    _record_transport_cleanup_failure,
    _rollback_failed_provider,
)

__all__ = [
    "IceServer",
    "ListenOptions",
    "Server",
    "SignalingAuthority",
    "Target",
    "WebrtcConfig",
    "listen",
    "locator",
    "provider",
]

_NETLAYER_CONSTRUCTION = object()


@dataclass(frozen=True)
class IceServer:
    """One STUN or TURN server. ``username`` and ``credential`` are empty for
    plain STUN and set together for credentialed TURN."""

    urls: "tuple[str, ...]"
    username: str = ""
    credential: str = ""


@dataclass(frozen=True)
class WebrtcConfig:
    """One WebRTC endpoint's configuration. The default has no ICE servers, so
    peers reach each other on host candidates alone, and leaves loopback
    addresses out. ``include_loopback_candidates`` offers them too, for two
    peers on one machine."""

    ice_servers: "tuple[IceServer, ...]" = field(default_factory=tuple)
    include_loopback_candidates: bool = False


@dataclass(frozen=True)
class Target:
    """The peer one exchange is with. ``designator`` is the hex key designator of
    the dialed locator, or of the offerer whose offer ``Server.provide_offer``
    took. ``introducer`` is the designator of the session that handed over the
    reference this dial follows, so the application can carry signaling through
    the party that knows the peer. It is ``None`` for a dial the application
    started itself or whose introducing session signed no designator, and for
    every accept."""

    designator: str
    introducer: Optional[str] = None


class SignalingAuthority(Protocol):
    """How the application carries signaling to the peer a ``Target`` names.

    Every call names its exchange by the id the library minted. The calls that
    open an exchange's route, ``offer``, ``answer``, and ``on_candidate``, also
    name its target. The archive calls these on the thread that steps the
    driver, so none of them may block.

    For one dial, ``on_candidate`` is called first, then ``offer``, then
    ``candidate`` for each local candidate. For one accept, ``answer`` runs
    inside ``Server.provide_offer``, then ``on_candidate``, then ``candidate``
    for each local candidate. An authority that only dials never has ``answer``
    called, and one that only answers never has ``offer`` called.

    ``offer`` returns the far peer's SDP answer. ``answer`` carries the SDP
    answer to the offerer whose offer ``Server.provide_offer`` took, and raising
    refuses that offer. ``candidate`` carries one local ICE candidate, given as
    the JSON text of an ``RTCIceCandidateInit``, and may return an awaitable.
    ``on_candidate`` subscribes to the far peer's candidates for one exchange:
    call ``sink`` with each candidate's JSON text. It returns a function that
    ends the subscription.

    The far peer may trickle candidates before ``on_candidate`` subscribes, so
    the authority buffers what arrives for an exchange until its sink exists.
    Two exchanges with one peer run side by side, as when both peers dial each
    other at once. CapTP's crossed-hellos tiebreak keeps one session.
    """

    async def offer(self, exchange: int, target: Target, sdp: str) -> str: ...

    def answer(self, exchange: int, target: Target, sdp: str) -> None: ...

    def candidate(self, exchange: int, ice: str) -> "None | Awaitable[None]": ...

    def on_candidate(
        self, exchange: int, target: Target, sink: Callable[[str], None]
    ) -> Callable[[], None]: ...


def locator(designator: str) -> Locator:
    """Build a ``webrtc`` locator for the peer with this hex key designator."""
    return Locator(TRANSPORT_WEBRTC, designator, {}, "boolean-false")


def _webrtc_last_error() -> "Optional[str]":
    return _read_last_error(_webrtc().glowcap_webrtc_last_error)


def _check_webrtc(code: int) -> None:
    if code != _c.OK:
        raise GlowcapError(
            code, _webrtc_last_error() or f"webrtc transport call failed (code {code})"
        )


def _view(text: str, keep: list) -> _WebrtcStringView:
    data = text.encode()
    buffer = ctypes.create_string_buffer(data, max(len(data), 1))
    keep.append(buffer)
    return _WebrtcStringView(ctypes.cast(buffer, ctypes.POINTER(ctypes.c_uint8)), len(data))


def _ice_records(servers: "tuple[IceServer, ...]", keep: list):
    """The C ICE server records, borrowing buffers that ``keep`` holds."""
    records = (_WebrtcIceServer * max(len(servers), 1))()
    for index, server in enumerate(servers):
        urls = (_WebrtcStringView * max(len(server.urls), 1))()
        for url_index, url in enumerate(server.urls):
            urls[url_index] = _view(url, keep)
        keep.append(urls)
        records[index] = _WebrtcIceServer(
            urls, len(server.urls), _view(server.username, keep), _view(server.credential, keep)
        )
    keep.append(records)
    return records


class _Exchange:
    __slots__ = ("dispose", "offer")

    def __init__(self) -> None:
        self.dispose: "Optional[Callable[[], None]]" = None
        self.offer: "Optional[asyncio.Future]" = None


def _text(ptr, length: int) -> str:
    """Decode one borrowed UTF-8 view an archive callback received."""
    return ctypes.string_at(ptr, length).decode()


class _Signaler:
    """The four archive callbacks over one ``SignalingAuthority``, and the verbs
    that hand a far peer's offer, answer, candidates, and give-up to the archive.

    The archive calls the callbacks on the thread that steps the driver, which
    is the asyncio thread, so a task they start may call ``provide_*`` directly.
    """

    def __init__(self, signaling: SignalingAuthority, aio, host, wake) -> None:
        self._signaling = signaling
        self._aio = aio
        self._host = host
        self._wake = wake
        self._exchanges: "dict[int, _Exchange]" = {}
        self._tasks: "set[asyncio.Future]" = set()
        self.netlayer: "Optional[ctypes.c_void_p]" = None
        self.send_offer = _WebrtcSendOfferFn(self._on_send_offer)
        self.send_answer = _WebrtcSendAnswerFn(self._on_send_answer)
        self.send_candidate = _WebrtcSendCandidateFn(self._on_send_candidate)
        self.done = _WebrtcExchangeDoneFn(self._on_done)

    def table(self) -> _WebrtcSignaling:
        return _WebrtcSignaling(
            None, self.send_offer, self.send_answer, self.send_candidate, self.done
        )

    def _record(self, operation: str, error: BaseException) -> None:
        self._host._record_callerless_failure(operation, error)

    def _spawn(self, operation: str, work: Awaitable, exchange: int) -> asyncio.Future:
        """Run one signaling step for ``exchange``. Its failure is recorded and
        gives the dial up."""
        task = asyncio.ensure_future(work, loop=self._aio)
        self._tasks.add(task)

        def finished(done: asyncio.Future) -> None:
            self._tasks.discard(done)
            if done.cancelled():
                return
            error = done.exception()
            if error is not None:
                self._record(operation, error)
                self._give_up(exchange)

        task.add_done_callback(finished)
        return task

    def _provide(self, exchange: int, call, payload: str) -> None:
        if exchange not in self._exchanges or self.netlayer is None:
            return
        owner, length = _str_buf(payload)
        code = call(self.netlayer, exchange, owner, length)
        if code == _c.ERR_INVALID_ARGUMENT:
            return
        _check_webrtc(code)
        self._wake()

    def provide_offer(self, designator: str, sdp: str) -> int:
        """Hand the library an inbound offer from the peer ``designator`` names.
        It answers through ``SignalingAuthority.answer`` before this returns and
        gives the accept's exchange id. A refusal starts no exchange."""
        if self.netlayer is None:
            raise GlowcapError(_c.ERR_CLOSED, "the webrtc netlayer is not open")
        peer, peer_len = _str_buf(designator)
        offer, offer_len = _str_buf(sdp)
        exchange = ctypes.c_uint64(0)
        _check_webrtc(
            _webrtc().glowcap_webrtc_netlayer_provide_offer(
                self.netlayer, peer, peer_len, offer, offer_len, ctypes.byref(exchange)
            )
        )
        self._wake()
        return exchange.value

    def fail_exchange(self, exchange: int) -> None:
        """Give up on ``exchange`` because its signaling broke. A dial fails at
        the driver's next step instead of its handshake deadline, and an accept
        ends without a session. A refusal means no such exchange is signaling."""
        if self.netlayer is None:
            raise GlowcapError(_c.ERR_CLOSED, "the webrtc netlayer is not open")
        _check_webrtc(
            _webrtc().glowcap_webrtc_netlayer_fail_exchange(self.netlayer, exchange)
        )
        self._wake()

    def _give_up(self, exchange: int) -> None:
        """Give a dial up after its signaling failed. A dial that already ended
        is left alone."""
        if exchange not in self._exchanges or self.netlayer is None:
            return
        try:
            self.fail_exchange(exchange)
        except GlowcapError as error:
            if error.code != _c.ERR_INVALID_ARGUMENT:
                self._record("webrtc.fail_exchange", error)
        except BaseException as error:
            self._record("webrtc.fail_exchange", error)

    def _provide_answer(self, exchange: int, sdp: str) -> None:
        self._provide(exchange, _webrtc().glowcap_webrtc_netlayer_provide_answer, sdp)

    def _provide_candidate(self, exchange: int, ice: str) -> None:
        try:
            self._provide(
                exchange, _webrtc().glowcap_webrtc_netlayer_provide_candidate, ice
            )
        except BaseException as error:
            self._record("webrtc.provide_candidate", error)

    async def _offer(self, exchange: int, target: Target, sdp: str) -> None:
        answer = await self._signaling.offer(exchange, target, sdp)
        self._provide_answer(exchange, answer)

    def _register(self, exchange: int, target: Target) -> _Exchange:
        """Record ``exchange`` for ``target`` and subscribe to the far peer's
        candidates. A failing subscription leaves the entry for ``_end``."""
        entry = _Exchange()
        self._exchanges[exchange] = entry

        def sink(ice: str) -> None:
            self._provide_candidate(exchange, ice)

        entry.dispose = self._signaling.on_candidate(exchange, target, sink)
        return entry

    def _on_send_offer(
        self, _ctx, exchange, designator, dlen, introducer, ilen, sdp, slen
    ) -> int:
        try:
            target = Target(
                _text(designator, dlen),
                _text(introducer, ilen) if introducer and ilen else None,
            )
            offer = _text(sdp, slen)
            entry = self._register(exchange, target)
            entry.offer = self._spawn(
                "webrtc.offer", self._offer(exchange, target, offer), exchange
            )
            return _c.OK
        except BaseException as error:
            self._end(exchange)
            self._record("webrtc.send_offer", error)
            return _c.ERR_IO

    def _on_send_answer(self, _ctx, exchange, designator, dlen, sdp, slen) -> int:
        try:
            target = Target(_text(designator, dlen))
            answer = _text(sdp, slen)
            self._register(exchange, target)
            self._signaling.answer(exchange, target, answer)
            return _c.OK
        except BaseException as error:
            self._end(exchange)
            self._record("webrtc.send_answer", error)
            return _c.ERR_IO

    def _on_send_candidate(self, _ctx, exchange, ice, ice_len) -> int:
        try:
            entry = self._exchanges.get(exchange)
            if entry is None:
                return _c.OK
            text = _text(ice, ice_len)
            result = self._signaling.candidate(exchange, text)
            if inspect.isawaitable(result):
                self._spawn("webrtc.candidate", result, exchange)
            return _c.OK
        except BaseException as error:
            self._record("webrtc.send_candidate", error)
            return _c.ERR_IO

    def _on_done(self, _ctx, exchange) -> None:
        self._end(exchange)

    def _end(self, exchange: int) -> None:
        """Forget ``exchange``, stop waiting for its answer, and end its
        candidate subscription. Every exchange ends here, accepted or dialed,
        finished or refused."""
        entry = self._exchanges.pop(exchange, None)
        if entry is None:
            return
        if entry.offer is not None:
            entry.offer.cancel()
        self._dispose(entry)

    def _dispose(self, entry: _Exchange) -> None:
        dispose, entry.dispose = entry.dispose, None
        if dispose is None:
            return
        try:
            dispose()
        except BaseException as error:
            self._record("webrtc.dispose_candidates", error)


class _Netlayer(_FfiHandleOwner):
    """One WebRTC netlayer plus the callbacks it holds. The callback objects
    live here for the netlayer's life because the archive keeps their
    addresses."""

    def __init__(
        self,
        config: WebrtcConfig,
        signaler: _Signaler,
        *,
        _construction_token=None,
    ) -> None:
        if _construction_token is not _NETLAYER_CONSTRUCTION:
            raise RuntimeError("use 'await _Netlayer.open(...)'")
        keep: list = []
        records = _ice_records(config.ice_servers, keep)
        ffi_config = _WebrtcConfig(
            ice_servers=ctypes.cast(records, ctypes.POINTER(_WebrtcIceServer)),
            ice_server_count=len(config.ice_servers),
            include_loopback_candidates=int(config.include_loopback_candidates),
            signaling=signaler.table(),
        )
        out = ctypes.c_void_p()
        _check_webrtc(
            _webrtc().glowcap_webrtc_netlayer_new(ctypes.byref(ffi_config), ctypes.byref(out))
        )
        self._signaler = signaler
        signaler.netlayer = out
        self._ffi = FfiHandle(
            out,
            lambda raw: _check_webrtc(_webrtc().glowcap_webrtc_netlayer_release(raw)),
            label="webrtc netlayer",
        )

    @classmethod
    async def open(cls, config: WebrtcConfig, signaler: _Signaler) -> "_Netlayer":
        """Construct off the reactor and keep ownership through cancellation."""
        construction = asyncio.ensure_future(
            asyncio.to_thread(
                cls, config, signaler, _construction_token=_NETLAYER_CONSTRUCTION
            )
        )
        try:
            return await asyncio.shield(construction)
        except asyncio.CancelledError:
            while not construction.done():
                try:
                    await asyncio.shield(construction)
                except asyncio.CancelledError:
                    continue
                except BaseException:
                    break
            if not construction.cancelled() and construction.exception() is None:
                try:
                    await asyncio.to_thread(construction.result()._release_blocking)
                except BaseException as error:
                    _record_transport_cleanup_failure(
                        "webrtc-release-after-cancel", error
                    )
            raise

    def _transport_provider(self):
        """Borrow this netlayer's archive-owned provider package."""
        from ._ffi_driver import _TransportProvider

        package = _TransportProvider()
        with self._ffi.lease() as raw:
            code = _webrtc().glowcap_webrtc_transport_provider(
                raw, ctypes.byref(package)
            )
        _check_webrtc(code)
        return package

    def _relinquish_provider_reference(self) -> None:
        """Transfer netlayer lifetime to the already-retained provider lease."""
        self._ffi.drop_reference()

    def _release_blocking(self) -> None:
        self._ffi.close()


async def _install(
    loop, signaling: SignalingAuthority, config: WebrtcConfig
) -> _Signaler:
    """Put one netlayer on ``loop`` and return the signaler its callbacks and
    verbs run through."""
    signaler = _Signaler(
        signaling, asyncio.get_running_loop(), loop.wrapper_host(), loop.schedule_step
    )
    netlayer = await _Netlayer.open(config, signaler)
    try:
        loop._install_provider(
            lambda register: register(netlayer._transport_provider())
        )
        netlayer._relinquish_provider_reference()
        # The driver's lease keeps the C netlayer alive. The Python objects
        # behind its callbacks must live as long, so the loop keeps them.
        loop._retain_until_teardown(netlayer)
    except BaseException as primary:
        _rollback_failed_provider(primary, netlayer._release_blocking)
        raise
    return signaler


def provider(
    signaling: SignalingAuthority, config: "Optional[WebrtcConfig]" = None
) -> Provider:
    """Build the WebRTC provider package. ``signaling`` carries each dial's
    offer, answer, and candidates. A Host that should also answer offers uses
    :func:`listen` instead."""
    selected = config if config is not None else WebrtcConfig()

    async def install(loop):
        await _install(loop, signaling, selected)

    return Provider(install)


@dataclass(frozen=True)
class ListenOptions:
    """Where a listener's Host identity comes from. With neither field the Host
    is new. ``seed`` is a 32-byte Ed25519 secret that restores a Host's key.
    ``host`` shares an existing Host, so its sessions and publications stay.
    Pass at most one."""

    seed: Optional[bytes] = None
    host: Optional[Host] = None


class Server(DriverServer):
    """A Host answering WebRTC offers. The driver loop owns the netlayer, the
    listener, the accept handshake, and every accepted session. Iterate the
    server for each accepted :class:`glowcap.Session`, whose partner identity
    names the offerer. This type adds the one verb WebRTC needs,
    :meth:`provide_offer`, and its give-up, :meth:`fail_exchange`."""

    def __init__(self, driver_loop, listener, signaler: _Signaler, *, retire_loop: bool):
        super().__init__(driver_loop, listener, retire_loop=retire_loop)
        self._signaler = signaler

    def _guard_open(self) -> None:
        if self._closed or self._driver_loop._released:
            raise GlowcapError(_c.ERR_CLOSED, "the webrtc server is closed")

    def provide_offer(self, designator: str, sdp: str) -> int:
        """Hand in an SDP offer from the peer whose designator is ``designator``.
        The library answers it through the authority's ``answer`` before this
        returns, and the returned exchange id names the accept for
        :meth:`fail_exchange`. A :class:`GlowcapError` means no exchange was
        started: the listener is closed, the offerer's key is not a key, too
        many accepts are in flight, or the authority refused the answer.

        An accept has no deadline of its own. One whose offerer goes quiet holds
        its place until the application calls :meth:`fail_exchange`."""
        self._guard_open()
        return self._signaler.provide_offer(designator, sdp)

    def fail_exchange(self, exchange: int) -> None:
        """Give up on the accept ``exchange`` because its signaling broke or its
        offerer went quiet. It ends without a session and its candidate
        subscription is disposed. A :class:`GlowcapError` means no such accept is
        in progress or its channel has already opened, and nothing changed."""
        self._guard_open()
        self._signaler.fail_exchange(exchange)


async def listen(
    signaling: SignalingAuthority,
    config: WebrtcConfig = WebrtcConfig(),
    options: ListenOptions = ListenOptions(),
) -> Server:
    """Compose a WebRTC netlayer into the Host ``options`` names, open its
    listener, and select it as the Host's advertised location. Needs the WebRTC
    library (``zig build webrtc-abi``).

    A WebRTC peer is reachable only as its key, so the listener's designator is
    the Host's own. The same netlayer dials: a :class:`glowcap.Runtime` that
    adopts ``server.host`` with no further provider connects to a
    :func:`locator` through it. Each inbound offer reaches the library through
    :meth:`Server.provide_offer`, the offerer's candidates through the
    ``on_candidate`` sink the authority was given, and iterating the server
    yields the session once the channel opens."""
    host = options.host
    prepared = prepare_driver_loop(
        host,
        host.codec if host is not None else _DEFAULT_CODEC,
        seed=listener_seed(options.seed, host),
    )
    loop = prepared.loop
    listener = None
    try:
        signaler = await _install(loop, signaling, config)
        # An empty designator asks the library for the Host's own key.
        listener = loop.listen(TRANSPORT_WEBRTC, "")
        loop.start()
        await loop.wait_listener(listener)
        loop.select_listener(listener)
        return Server(loop, listener, signaler, retire_loop=prepared.owns_loop)
    except BaseException as error:
        _rollback_listener_construction(error, loop, listener, prepared.owns_loop)
        raise
