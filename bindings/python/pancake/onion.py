"""The Tor onion transport, pancake's ``libpancake_net_transport_onion`` archive,
surfaced à la carte.

``onion`` is the one netlayer the OCapN draft standardizes, and the one upstream
Spritely Goblins ships, so it is where a pancake peer and a Goblins vat meet on
ground neither invented. A locator is ``ocapn://<serviceid>.onion``, and the
designator this module takes is that bare service id: 56 base32 characters with no
``.onion`` suffix.

The product surface is this module's :func:`listen` plus
:class:`pancake.Runtime` composed with :func:`provider`; both yield ordinary
:class:`pancake.Session` objects. :class:`OnionNetlayer` remains the explicit raw
byte-stream embedding surface for callers that own their own loop and framing.

**pancake starts no Tor.** An :class:`OnionNetlayer` names where an already-running
daemon listens — its SOCKS endpoint to dial, its control endpoint to host — and
never spawns, supervises, or configures one. Each endpoint is an absolute Unix
socket path or a ``host:port``. Omit the control endpoint and the netlayer can dial
and cannot host, which :meth:`OnionNetlayer.listen` reports rather than pretending::

    from pancake.onion import OnionNetlayer

    with OnionNetlayer(socks="/run/tor/socks", control="/run/tor/control") as nl:
        listener = nl.listen()
        print(f"ocapn://{listener.service_id}.onion")
        conn = listener.accept()

Two limits are worth reading before relying on this, and both are ADR-0108
decisions rather than implementation details. A service id is an *address, not an
identity*: Tor proves the far end of the circuit holds the key the address encodes,
but the CapTP peer is whoever holds the local endpoint that service forwards to.
And an accepted circuit carries *no client identity at all*, because Tor tells a
hidden service nothing about who dialed it, so a partner's claimed location on that
side is unverified.

Every call that reaches Tor blocks the calling thread, and a circuit costs seconds
rather than milliseconds. Both handles expose ``readiness_fd()`` — the socket they
sit on — so a caller with its own loop can :func:`select.select` before accepting or
reading. The connection descriptor is only a byte-readiness hint: a fragmented
frame can make ``read_frame()`` wait for later bytes. An onion connection is an
ordinary socket, which is why a real descriptor is available here.
"""

from __future__ import annotations

import ctypes
import threading
import weakref
from dataclasses import dataclass

from ._abi_value import _DEFAULT_CODEC, _codec_id
from . import _constants as _c
from ._constants import OK as _OK
from ._errors import PancakeError
from ._ffi_ocapn import (
    _borrowed_byte_frame,
    _copy_managed_frame,
    _ManagedFrame,
    _read_last_error,
)
from ._ffi_onion import _onion_lib, _OnionConfig
from ._host import Host
from ._locator import Locator
from ._native import NativeHandle, _NativeHandleOwner
from ._server import DriverServer, prepare_driver_loop, _rollback_listener_construction
from ._transport import Provider, _rollback_failed_provider

__all__ = [
    "AUTH_COOKIE",
    "AUTH_NONE",
    "AUTH_PASSWORD",
    "OnionConfig",
    "SERVICE_ID_LENGTH",
    "OnionServer",
    "OnionConnection",
    "OnionListener",
    "OnionNetlayer",
    "locator",
    "listen",
    "provider",
]


def locator(service_id: str) -> Locator:
    """Build the standardized hint-free locator for an onion service."""
    return Locator(_c.TRANSPORT_ONION, service_id, {}, "boolean-false")

#: An unauthenticated control endpoint, which is what a Unix control socket with no
#: authentication gives and what upstream Goblins assumes.
AUTH_NONE = _c.ONION_AUTH_NONE
#: Authenticate with the bytes of the file ``CookieAuthFile`` names, which the
#: transport sends as hexadecimal. The common default on a distribution's Tor.
AUTH_COOKIE = _c.ONION_AUTH_COOKIE
#: Authenticate with the cleartext of a ``HashedControlPassword`` setup.
AUTH_PASSWORD = _c.ONION_AUTH_PASSWORD

#: A version 3 onion service id is always exactly this many characters.
SERVICE_ID_LENGTH = _c.ONION_SERVICE_ID_LEN

_SERVICE_KEY_CAP = _c.ONION_SERVICE_KEY_CAP


@dataclass(frozen=True, slots=True)
class OnionConfig:
    """Configuration for one Tor-backed native onion provider."""

    socks: str
    control: str = ""
    auth_kind: int = AUTH_NONE
    auth_secret: str | bytes | None = None
    service_key: bytes = b""
    forward: str = ""


def _onion_last_error() -> str | None:
    """The calling thread's last error message from the onion transport archive, or
    ``None`` when there is none. The transport keeps its own thread-local slot, so an
    onion call's diagnostic is read here and never from the core family's
    :func:`pancake.last_error`."""
    return _read_last_error(_onion_lib.pancake_onion_last_error)


def _check_onion(code: int) -> None:
    """Like :func:`pancake._check`, but reads the onion transport's own thread-local
    last-error rather than the unrelated core one."""
    if code != _OK:
        raise PancakeError(code, _onion_last_error())


def _bytes_of(value: str | bytes | None) -> bytes:
    if value is None:
        return b""
    return value.encode() if isinstance(value, str) else bytes(value)


def _release_conn(raw) -> None:
    _check_onion(_onion_lib.pancake_onion_conn_release(raw, None, 0, None))


def _release_listener(raw) -> None:
    _check_onion(_onion_lib.pancake_onion_listener_release(raw, None, 0, None))


def _release_netlayer(raw) -> None:
    _check_onion(_onion_lib.pancake_onion_netlayer_release(raw, None, 0, None))


def _shutdown_conn(raw) -> None:
    _check_onion(_onion_lib.pancake_onion_conn_shutdown(raw))


class OnionConnection(_NativeHandleOwner):
    """One onion connection carrying one OCapN session, framed on the codec its
    constructor named. Closed on release / context exit."""

    def __init__(self, raw, netlayer: "OnionNetlayer"):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_conn,
            _shutdown_conn,
            label="onion connection",
            keepalive=netlayer,
        )
        self._reads = threading.Lock()
        self._writes = threading.Lock()
        if not netlayer._adopt(self):
            self._native.close()
            raise RuntimeError("onion netlayer is released")

    def __enter__(self) -> OnionConnection:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._native.close()
        self._netlayer._forget(self)

    def readiness_fd(self) -> int:
        """The connection's byte-readiness descriptor for a caller-owned loop.

        Select before reading, but do not treat readability as a complete-frame
        guarantee: a fragmented frame can make :meth:`read_frame` wait for later
        bytes. The connection owns this descriptor; do not close it."""
        out = ctypes.c_int32()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_conn_readiness_fd(raw, ctypes.byref(out))
            )
        return out.value

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises PancakeError(ERR_CLOSED) on clean EOF.

        Prefer selecting on :meth:`readiness_fd` first; this parks when nothing has
        arrived."""
        with self._reads, self._native.lease() as raw:
            frame = _ManagedFrame()
            _check_onion(
                _onion_lib.pancake_onion_conn_read_frame(
                    raw, ctypes.byref(frame), None, 0, None
                )
            )
            return _copy_managed_frame(frame)

    def write_frame(self, frame: bytes) -> None:
        f, _borrowed = _borrowed_byte_frame(frame)
        with self._writes, self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_conn_write_frame(
                    raw, ctypes.byref(f), None, 0, None
                )
            )


class OnionListener(_NativeHandleOwner):
    """A live onion service: the control session keeping it published plus the local
    endpoint Tor forwards it to.

    Closing withdraws the service, so the address stops resolving. That is the one
    release in this family with an effect a partner can observe."""

    def __init__(
        self, raw, service_id: str, service_key: bytes, netlayer: "OnionNetlayer"
    ):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_listener,
            _onion_lib.pancake_onion_listener_shutdown,
            label="onion listener",
            keepalive=netlayer,
        )
        self._accepts = threading.Lock()
        if not netlayer._adopt(self):
            self._native.close()
            raise RuntimeError("onion netlayer is released")
        #: The version 3 service id Tor minted or restored, without its ``.onion``
        #: suffix. This is the designator a partner dials.
        self.service_id = service_id
        #: The key that restores this exact service, or empty when the service was
        #: restored rather than minted. Store it and pass it back as
        #: ``service_key=`` for an address that survives a restart.
        self.service_key = service_key

    def __enter__(self) -> OnionListener:
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._native.close()
        self._netlayer._forget(self)

    def readiness_fd(self) -> int:
        """The descriptor this listener's circuits arrive on.

        This is what keeps a caller with its own loop off the blocking path:
        :func:`select.select` on it and call :meth:`accept` only once it is readable.
        Owned by the listener: do not close it, and do not use it after
        :meth:`close`."""
        out = ctypes.c_int32()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_listener_readiness_fd(raw, ctypes.byref(out))
            )
        return out.value

    def wait(self, timeout_ms: int) -> bool:
        """Wait up to ``timeout_ms`` for :meth:`accept` to be able to make progress.
        ``False`` on timeout. Lets an accept loop check a stop flag instead of
        parking, without closing the listener from another thread."""
        out = ctypes.c_uint32()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_listener_wait(
                    raw, timeout_ms, ctypes.byref(out), None, 0, None
                )
            )
        return out.value != 0

    def accept(
        self,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = _c.RAW_TRANSPORT_DEFAULT_FRAME_CAP,
    ) -> OnionConnection:
        """Block until Tor forwards a circuit to this service.

        The partner's claimed location is unverified here: Tor tells a hidden service
        nothing about who dialed it."""
        with self._accepts, self._native.lease() as raw:
            out = ctypes.c_void_p()
            _check_onion(
                _onion_lib.pancake_onion_accept(
                    raw,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            return OnionConnection(out, self._netlayer)


class OnionNetlayer(_NativeHandleOwner):
    """Owns where Tor listens and the one I/O backend its streams block on; outlives
    the connections and listeners made from it. Released on :meth:`release` / context
    exit.

    ``socks`` is required. ``control`` empty means dial-only. ``service_key`` empty
    asks Tor for a fresh service; otherwise pass back the exact bytes an earlier
    :attr:`OnionListener.service_key` reported. ``forward`` empty binds a loopback
    port and reports it to Tor."""

    def __init__(
        self,
        socks: str,
        control: str = "",
        auth_kind: int = AUTH_NONE,
        auth_secret: str | bytes | None = None,
        service_key: bytes = b"",
        forward: str = "",
    ):
        socks_b = _bytes_of(socks)
        control_b = _bytes_of(control)
        secret_b = _bytes_of(auth_secret)
        key_b = _bytes_of(service_key)
        forward_b = _bytes_of(forward)

        # Held in locals for the duration of the call below: the config borrows these
        # pointers, and the native side copies out of them before returning.
        buffers = [
            ctypes.create_string_buffer(b, len(b)) if b else None
            for b in (socks_b, control_b, secret_b, key_b, forward_b)
        ]

        def ptr(index: int):
            buf = buffers[index]
            return ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None

        cfg = _OnionConfig()
        cfg.socks, cfg.socks_len = ptr(0), len(socks_b)
        cfg.control_endpoint, cfg.control_endpoint_len = ptr(1), len(control_b)
        cfg.auth_kind = auth_kind
        cfg.auth_secret, cfg.auth_secret_len = ptr(2), len(secret_b)
        cfg.service_key, cfg.service_key_len = ptr(3), len(key_b)
        cfg.forward, cfg.forward_len = ptr(4), len(forward_b)

        out = ctypes.c_void_p()
        _check_onion(
            _onion_lib.pancake_onion_netlayer_new(ctypes.byref(cfg), ctypes.byref(out))
        )
        # Annotated because `release` clears it, the same shape `_host.py` uses.
        self._native = NativeHandle(
            out,
            _release_netlayer,
            _onion_lib.pancake_onion_netlayer_shutdown,
            label="onion netlayer",
        )
        # Children retain this owner; weak membership avoids an ownership cycle
        # while still letting explicit release retire them before std.Io.
        self._children: "weakref.WeakSet[OnionConnection | OnionListener]" = (
            weakref.WeakSet()
        )
        self._children_lock = threading.Lock()
        self._release_lock = threading.Lock()
        self._release_requested = False

    def __enter__(self) -> OnionNetlayer:
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        with self._release_lock:
            with self._children_lock:
                if self._release_requested:
                    children = []
                else:
                    self._release_requested = True
                    children = list(self._children)
            for child in children:
                child.close()
            self._native.close()

    def _adopt(self, child: OnionConnection | OnionListener) -> bool:
        with self._children_lock:
            if self._release_requested:
                return False
            self._children.add(child)
            return True

    def _forget(self, child: OnionConnection | OnionListener) -> None:
        with self._children_lock:
            self._children.discard(child)

    def _transport_provider(self):
        from ._ffi_driver import _TransportProvider

        package = _TransportProvider()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_transport_provider(raw, ctypes.byref(package))
            )
        return package

    def _relinquish_provider_reference(self) -> None:
        """Transfer runtime lifetime to an already-retained provider lease."""
        with self._release_lock:
            with self._children_lock:
                if self._release_requested or self._children:
                    raise RuntimeError("onion netlayer is not transferable")
                self._release_requested = True
            self._native.drop_reference()

    def listen(self) -> OnionListener:
        """Ask Tor for an onion service and bind its local end.

        Requires a control endpoint; without one this raises rather than reporting a
        service nothing could reach."""
        id_buf = ctypes.create_string_buffer(SERVICE_ID_LENGTH)
        id_len = ctypes.c_size_t()
        key_buf = ctypes.create_string_buffer(_SERVICE_KEY_CAP)
        key_len = ctypes.c_size_t()
        out = ctypes.c_void_p()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_listen(
                    raw,
                    ctypes.cast(id_buf, ctypes.c_void_p),
                    SERVICE_ID_LENGTH,
                    ctypes.byref(id_len),
                    ctypes.cast(key_buf, ctypes.c_void_p),
                    _SERVICE_KEY_CAP,
                    ctypes.byref(key_len),
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            return OnionListener(
                out,
                id_buf.raw[: id_len.value].decode(),
                key_buf.raw[: key_len.value],
                self,
            )

    def connect(
        self,
        service_id: str,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = _c.RAW_TRANSPORT_DEFAULT_FRAME_CAP,
    ) -> OnionConnection:
        """Dial the onion service ``service_id`` through the configured Tor.

        ``service_id`` is the bare 56-character designator. One that is not a
        well-formed version 3 address is refused before any socket opens. Blocking: a
        circuit takes seconds."""
        d = _bytes_of(service_id)
        buf = ctypes.create_string_buffer(d, len(d))
        out = ctypes.c_void_p()
        with self._native.lease() as raw:
            _check_onion(
                _onion_lib.pancake_onion_connect(
                    raw,
                    ctypes.cast(buf, ctypes.c_void_p),
                    len(d),
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            return OnionConnection(out, self)


class OnionServer(DriverServer):
    """A driver-owned onion listener yielding generic :class:`Session` objects.

    The driver owns Tor provider execution and listener admission. The server
    only projects the driver's locator and restoration state into the Python
    API; CapTP remains owned by each yielded session.
    """

    def __init__(
        self,
        driver_loop,
        listener,
        service_key: bytes,
        *,
        retire_loop: bool,
    ):
        super().__init__(driver_loop, listener, retire_loop=retire_loop)
        self._service_key = bytes(service_key)

    @property
    def service_key(self) -> bytes:
        """The provider-owned key that restores this exact onion service."""
        return self._service_key

    @property
    def service_id(self) -> str:
        """The onion service designator without the ``.onion`` suffix."""
        return self.designator


async def listen(
    socks: str,
    *,
    control: str = "",
    auth_kind: int = AUTH_NONE,
    auth_secret: str | bytes | None = None,
    service_key: bytes = b"",
    forward: str = "",
    host: Host | None = None,
    codec: str | None = None,
) -> OnionServer:
    """Bind an onion service through the generic driver listener seam.

    ``socks`` and ``control`` name an already-running Tor daemon. The provider
    archive owns that configuration; the returned server owns neither Tor nor
    the supplied Host. ``service_key`` restores a prior service when supplied.
    Tor's control exchange runs synchronously before this function returns.
    """
    selected_codec = codec if codec is not None else (host.codec if host else _DEFAULT_CODEC)
    prepared = prepare_driver_loop(host, selected_codec)
    loop = prepared.loop
    listener = None
    try:
        await provider(OnionConfig(
            socks, control, auth_kind, auth_secret, service_key, forward
        )).install(loop)
        listener = loop.listen(_c.TRANSPORT_ONION, "")
        loop.start()
        await loop.wait_listener(listener)
        loop.select_listener(listener)
        restored_key = loop.listener_restoration_state(listener)
        return OnionServer(
            loop,
            listener,
            restored_key,
            retire_loop=prepared.owns_loop,
        )
    except BaseException as error:
        _rollback_listener_construction(error, loop, listener, prepared.owns_loop)
        raise


def provider(config: OnionConfig) -> Provider:
    """Build the configured native onion provider package."""
    async def install(loop) -> None:
        netlayer = OnionNetlayer(
            socks=config.socks,
            control=config.control,
            auth_kind=config.auth_kind,
            auth_secret=config.auth_secret,
            service_key=config.service_key,
            forward=config.forward,
        )
        try:
            loop._install_provider(
                lambda register: register(netlayer._transport_provider())
            )
        except BaseException as primary:
            _rollback_failed_provider(primary, netlayer.release)
            raise
        netlayer._relinquish_provider_reference()

    return Provider(install)
