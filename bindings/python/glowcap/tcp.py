"""The blocking TCP transport, glowcap's ``libglowcap_net_transport_tcp``
archive, surfaced à la carte.

This is a companion to the core :mod:`glowcap` module, mirroring the C ABI's
symbol-disjoint archive split (ADR-0059). Importing it loads
``libglowcap_net_transport_tcp`` on top of the core ``libglowcap_ocapn``. It
shares the core's frame, context, and value layout but adds the
``glowcap_tcp_*`` family, a host-owned blocking frame shuttle over a real
kernel socket, with its own thread-local last-error. A consumer that shuttles
whole frames over TCP by hand composes it with the core:

    from glowcap.tcp import TcpNetlayer

    with TcpNetlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        conn = nl.connect("127.0.0.1", listener.port())
        conn.write_frame(frame)

This module also owns the async TCP listener package. Dial composes
:class:`glowcap.Runtime` with a typed locator. Listening is
:func:`glowcap.tcp.listen`, :attr:`keyed.listen`, or :attr:`noise.listen`.
"""

from __future__ import annotations

import asyncio
import ctypes
import threading
import weakref
from dataclasses import dataclass
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from ._host import Host

from ._abi_value import _DEFAULT_CODEC, _codec_id
from ._constants import OK as _OK
from ._constants import (
    BINDING_STREAM_READ_CHUNK_BYTES,
    HINT_DIRECT_ADDRESSES,
    RAW_TRANSPORT_DEFAULT_FRAME_CAP,
    TRANSPORT_KEYED_TCP,
    TRANSPORT_NOISE_TCP,
    TRANSPORT_TCP,
)
from ._errors import GlowcapError
from ._ffi_ocapn import (
    _borrowed_byte_frame,
    _copy_managed_frame,
    _ManagedFrame,
    _read_last_error,
    _str_buf,
)
from ._ffi_tcp import _TcpConfig, _TcpStreamOptions, _tcp_lib
from ._native import NativeHandle, _NativeHandleOwner
from ._locator import Locator, designator_host_port
from ._socket_address import address_designator
from ._transport import (
    Connector,
    Provider,
    _rollback_failed_provider,
    _rollback_failed_transport,
)

__all__ = [
    "Server",
    "TcpNetlayer",
    "TcpListener",
    "TcpConnection",
    "Config",
    "StreamOptions",
    "Keepalive",
    "address_designator",
    "locator",
    "listen",
    "keyed",
    "noise",
    "provider",
    "connector",
]


@dataclass(frozen=True)
class Keepalive:
    """TCP keepalive window. Every field is required when enabled."""

    idle_seconds: int
    interval_seconds: int
    count: int


@dataclass(frozen=True)
class StreamOptions:
    """Policy for one stream. ``None`` at an operation inherits the provider."""

    keepalive: "Optional[Keepalive]" = None


@dataclass(frozen=True)
class Config:
    """Defaults inherited by every stream in the TCP provider package."""

    stream: StreamOptions = StreamOptions()


def _stream_options(value: StreamOptions) -> _TcpStreamOptions:
    keepalive = value.keepalive
    if keepalive is None:
        return _TcpStreamOptions()
    return _TcpStreamOptions(
        keepalive.idle_seconds,
        keepalive.interval_seconds,
        keepalive.count,
    )


def _stream_options_ptr(value: "Optional[StreamOptions]"):
    if value is None:
        return None, None
    raw = _stream_options(value)
    return raw, ctypes.byref(raw)


class _TcpByteChannel:
    """One asyncio TCP stream as the byte-fed Host transport."""

    def __init__(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self._reader = reader
        self._writer = writer

    async def read(self) -> "Optional[bytes]":
        chunk = await self._reader.read(BINDING_STREAM_READ_CHUNK_BYTES)
        return chunk or None

    async def write(self, data: bytes) -> None:
        self._writer.write(data)
        await self._writer.drain()

    def close(self) -> None:
        self._writer.close()

    async def wait_closed(self) -> None:
        await self._writer.wait_closed()


async def _open_byte_channel(host: str, port: int) -> _TcpByteChannel:
    """Open the runtime-owned TCP channel used by a byte-fed Host."""
    reader, writer = await asyncio.open_connection(host, port)
    return _TcpByteChannel(reader, writer)


def locator(host: str, port: int) -> Locator:
    """Build the plain TCP profile's typed OCapN locator."""
    return Locator(
        TRANSPORT_TCP,
        address_designator(host, port),
        {},
        "boolean-false",
    )


class _KeyAddressedProfile:
    __slots__ = ("_transport",)

    def __init__(self, transport: str) -> None:
        self._transport = transport

    def locator(self, designator: str, host: str, port: int) -> Locator:
        """Build this key-addressed TCP profile's typed locator."""
        return Locator(
            self._transport,
            designator,
            {HINT_DIRECT_ADDRESSES: address_designator(host, port)},
            "map",
        )

    async def listen(
        self,
        bind_host: str,
        port: int = 0,
        *,
        seed: "Optional[bytes]" = None,
        codec: "Optional[str]" = None,
        advertised_host: "Optional[str]" = None,
        host: "Optional[Host]" = None,
        config: Config = Config(),
    ) -> "Server":
        """Bind this key-addressed profile through the TCP provider."""
        from ._tcp_listen import listen_keyed, listen_noise

        bind = (
            listen_keyed
            if self._transport == TRANSPORT_KEYED_TCP
            else listen_noise
        )
        return await bind(
            bind_host,
            port,
            seed=seed,
            codec=codec,
            advertised_host=advertised_host,
            host=host,
            config=config,
        )


keyed = _KeyAddressedProfile(TRANSPORT_KEYED_TCP)
noise = _KeyAddressedProfile(TRANSPORT_NOISE_TCP)


def _tcp_last_error() -> Optional[str]:
    """The calling thread's last error message from the TCP transport archive
    (``libglowcap_net_transport_tcp``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so a tcp call's diagnostic is
    read here and never from the core family's :func:`glowcap.last_error`."""
    return _read_last_error(_tcp_lib.glowcap_tcp_last_error)


def _check_tcp(code: int) -> None:
    """Like :func:`glowcap._check`, but reads the TCP transport's own
    thread-local last-error rather than the unrelated core one."""
    if code != _OK:
        raise GlowcapError(code, _tcp_last_error())


def _release_connection(raw) -> None:
    _check_tcp(_tcp_lib.glowcap_tcp_conn_release(raw, None, 0, None))


def _shutdown_connection(raw) -> None:
    _check_tcp(_tcp_lib.glowcap_tcp_conn_shutdown(raw))


def _release_listener(raw) -> None:
    _tcp_lib.glowcap_tcp_listener_release(raw)


def _release_netlayer(raw) -> None:
    _tcp_lib.glowcap_tcp_netlayer_release(raw)


class TcpConnection(_NativeHandleOwner):
    """A blocking TCP connection: the ``glowcap_tcp_*`` frame shuttle over one
    socket. Closed on release / context exit."""

    def __init__(self, raw, netlayer: "TcpNetlayer"):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_connection,
            _shutdown_connection,
            label="TCP connection",
            keepalive=netlayer,
        )
        self._reads = threading.Lock()
        self._writes = threading.Lock()
        if not netlayer._adopt(self):
            self._native.close()
            raise RuntimeError("TCP netlayer is released")

    def __enter__(self) -> "TcpConnection":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._native.close()
        self._netlayer._forget(self)

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises GlowcapError(ERR_CLOSED) on clean EOF."""
        with self._reads, self._native.lease() as raw:
            frame = _ManagedFrame()
            _check_tcp(
                _tcp_lib.glowcap_tcp_conn_read_frame(
                    raw, ctypes.byref(frame), None, 0, None
                )
            )
            return _copy_managed_frame(frame)

    def write_frame(self, frame: bytes) -> None:
        f, _borrowed = _borrowed_byte_frame(frame)
        with self._writes, self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.glowcap_tcp_conn_write_frame(
                    raw, ctypes.byref(f), None, 0, None
                )
            )


class TcpListener(_NativeHandleOwner):
    """A bound TCP listener. Closed on release / context exit."""

    def __init__(self, raw, netlayer: "TcpNetlayer"):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_listener,
            _tcp_lib.glowcap_tcp_listener_shutdown,
            label="TCP listener",
            keepalive=netlayer,
        )
        self._accepts = threading.Lock()
        if not netlayer._adopt(self):
            self._native.close()
            raise RuntimeError("TCP netlayer is released")

    def __enter__(self) -> "TcpListener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._native.close()
        self._netlayer._forget(self)

    def port(self) -> int:
        out = ctypes.c_uint16()
        with self._native.lease() as raw:
            _check_tcp(_tcp_lib.glowcap_tcp_listener_port(raw, ctypes.byref(out)))
        return out.value

    def readiness_fd(self) -> int:
        """Return the borrowed listening descriptor for reactor integration.

        The listener owns it. Callers must not close it or retain it after
        :meth:`close`.
        """
        out = ctypes.c_int32()
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.glowcap_tcp_listener_readiness_fd(raw, ctypes.byref(out))
            )
        return out.value

    def accept(
        self,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
        *,
        options: "Optional[StreamOptions]" = None,
    ) -> TcpConnection:
        raw_options, options_ptr = _stream_options_ptr(options)
        with self._accepts, self._native.lease() as raw:
            out = ctypes.c_void_p()
            _check_tcp(
                _tcp_lib.glowcap_tcp_accept(
                    raw,
                    options_ptr,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            _ = raw_options
            return TcpConnection(out, self._netlayer)


class TcpNetlayer(_NativeHandleOwner):
    """Owns the blocking-TCP I/O backend. Outlives the connections made from it.
    Released on :meth:`release` / context exit."""

    def __init__(self, config: Config = Config()):
        out = ctypes.c_void_p()
        raw_config = _TcpConfig(_stream_options(config.stream))
        _check_tcp(
            _tcp_lib.glowcap_tcp_netlayer_new(
                ctypes.byref(raw_config), ctypes.byref(out)
            )
        )
        self._native = NativeHandle(
            out,
            _release_netlayer,
            _tcp_lib.glowcap_tcp_netlayer_shutdown,
            label="TCP netlayer",
        )
        # Children borrow this netlayer's pinned std.Io backend. A weak set
        # lets each child retain the owner without forming an ownership cycle;
        # explicit release still retires every child before the backend.
        self._children: "weakref.WeakSet[TcpConnection | TcpListener]" = (
            weakref.WeakSet()
        )
        self._children_lock = threading.Lock()
        self._release_lock = threading.Lock()
        self._release_requested = False

    def __enter__(self) -> "TcpNetlayer":
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

    def _adopt(self, child: "TcpConnection | TcpListener") -> bool:
        with self._children_lock:
            if self._release_requested:
                return False
            self._children.add(child)
            return True

    def _forget(self, child: "TcpConnection | TcpListener") -> None:
        with self._children_lock:
            self._children.discard(child)

    def _transport_provider(self):
        """Borrow this runtime's complete tcp/keyed-tcp/noise-tcp package."""
        from ._ffi_driver import _TransportProvider

        package = _TransportProvider()
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.glowcap_tcp_transport_provider(raw, ctypes.byref(package))
            )
        return package

    def _relinquish_provider_reference(self) -> None:
        """Transfer runtime lifetime to an already-retained provider lease."""
        with self._release_lock:
            with self._children_lock:
                if self._release_requested or self._children:
                    raise RuntimeError("TCP netlayer is not transferable")
                self._release_requested = True
            self._native.drop_reference()

    def listen(self, host: str, port: int = 0) -> TcpListener:
        buf, n = _str_buf(host)
        out = ctypes.c_void_p()
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.glowcap_tcp_listen(
                    raw, ctypes.cast(buf, ctypes.c_void_p), n, port, ctypes.byref(out)
                )
            )
            return TcpListener(out, self)

    def connect(
        self,
        host: str,
        port: int,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
        *,
        options: "Optional[StreamOptions]" = None,
    ) -> TcpConnection:
        buf, n = _str_buf(host)
        out = ctypes.c_void_p()
        raw_options, options_ptr = _stream_options_ptr(options)
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.glowcap_tcp_connect(
                    raw,
                    ctypes.cast(buf, ctypes.c_void_p),
                    n,
                    port,
                    options_ptr,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            _ = raw_options
            return TcpConnection(out, self)


def provider(config: "Optional[Config]" = None) -> Provider:
    """Build the configured native package for all TCP profiles."""
    selected = config if config is not None else Config()

    async def install(loop) -> None:
        netlayer = TcpNetlayer(selected)
        try:
            loop._install_provider(
                lambda register: register(netlayer._transport_provider())
            )
        except BaseException as primary:
            _rollback_failed_provider(primary, netlayer.release)
            raise
        netlayer._relinquish_provider_reference()

    return Provider(install)


def connector() -> Connector:
    """Build the explicit asyncio byte connector for clear TCP."""

    async def realize(host, locator, handshake_timeout_ms):
        address, port = designator_host_port(locator.designator)
        channel = await _open_byte_channel(address, port)
        try:
            from ._session import Session

            return await Session.establish_dialed_locator(
                host,
                locator,
                channel,
                handshake_timeout_ms,
            )
        except BaseException as primary:
            await _rollback_failed_transport(primary, channel)
            raise

    return Connector((TRANSPORT_TCP,), realize)


# Public high-level listening lives with the transport package. Importing this
# after the provider definitions avoids a cycle: the implementation composes
# the package's Provider only when a listener is opened.
from ._tcp_listen import Server, listen  # noqa: E402
