"""The blocking TCP transport, pancake's ``libpancake_net_transport_tcp``
archive, surfaced à la carte.

This is a companion to the core :mod:`pancake` module, mirroring the C ABI's
symbol-disjoint archive split (ADR-0059). Importing it loads
``libpancake_net_transport_tcp`` on top of the core ``libpancake_ocapn``; it
shares the core's frame, context, and value layout but adds the
``pancake_tcp_*`` family — a host-owned blocking frame shuttle over a real
kernel socket — with its own thread-local last-error. A consumer that shuttles
whole frames over TCP by hand composes it with the core:

    from pancake.tcp import TcpNetlayer

    with TcpNetlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        conn = nl.connect("127.0.0.1", listener.port())
        conn.write_frame(frame)

This is the explicit, synchronous shuttle. The async, transport-neutral
application surface (:func:`pancake.connect`, :func:`pancake.listen`,
:class:`pancake.Session`) lives in the core and drives TCP over asyncio
without this archive, reach here only when you want the blocking connections
themselves.
"""

from __future__ import annotations

import ctypes
import threading
import weakref
from typing import Optional

from ._codec import _codec_id
from ._constants import FRAME_SHAPE_BYTE as _FRAME_SHAPE_BYTE, OK as _OK
from ._errors import PancakeError
from ._ffi_ocapn import _copy_managed_frame, _Frame, _ManagedFrame, _read_last_error, _str_buf
from ._ffi_tcp import _tcp_lib
from ._native import NativeHandle

__all__ = ["TcpNetlayer", "TcpListener", "TcpConnection"]


def _tcp_last_error() -> Optional[str]:
    """The calling thread's last error message from the TCP transport archive
    (``libpancake_net_transport_tcp``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so a tcp call's diagnostic is
    read here and never from the core family's :func:`pancake.last_error`."""
    return _read_last_error(_tcp_lib.pancake_tcp_last_error)


def _check_tcp(code: int) -> None:
    """Like :func:`pancake._check`, but reads the TCP transport's own
    thread-local last-error rather than the unrelated core one."""
    if code != _OK:
        raise PancakeError(code, _tcp_last_error())


def _release_connection(raw) -> None:
    _tcp_lib.pancake_tcp_conn_release(raw)


def _release_listener(raw) -> None:
    _tcp_lib.pancake_tcp_listener_release(raw)


def _release_netlayer(raw) -> None:
    _tcp_lib.pancake_tcp_netlayer_release(raw)


class TcpConnection:
    """A blocking TCP connection: the ``pancake_tcp_*`` frame shuttle over one
    socket. Closed on release / context exit."""

    def __init__(self, raw, netlayer: "TcpNetlayer"):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_connection,
            _tcp_lib.pancake_tcp_conn_shutdown,
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
        """Block for one whole frame. Raises PancakeError(ERR_CLOSED) on clean EOF."""
        with self._reads, self._native.lease() as raw:
            frame = _ManagedFrame()
            _check_tcp(_tcp_lib.pancake_tcp_conn_read_frame(raw, ctypes.byref(frame)))
            return _copy_managed_frame(frame)

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        with self._writes, self._native.lease() as raw:
            _check_tcp(_tcp_lib.pancake_tcp_conn_write_frame(raw, ctypes.byref(f)))


class TcpListener:
    """A bound TCP listener. Closed on release / context exit."""

    def __init__(self, raw, netlayer: "TcpNetlayer"):
        self._netlayer = netlayer
        self._native = NativeHandle(
            raw,
            _release_listener,
            _tcp_lib.pancake_tcp_listener_shutdown,
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
            _check_tcp(_tcp_lib.pancake_tcp_listener_port(raw, ctypes.byref(out)))
        return out.value

    def readiness_fd(self) -> int:
        """Return the borrowed listening descriptor for reactor integration.

        The listener owns it; callers must not close it or retain it after
        :meth:`close`.
        """
        out = ctypes.c_int32()
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.pancake_tcp_listener_readiness_fd(raw, ctypes.byref(out))
            )
        return out.value

    def accept(self, codec: str = "syrup", max_frame_bytes: int = 4096) -> TcpConnection:
        with self._accepts, self._native.lease() as raw:
            out = ctypes.c_void_p()
            _check_tcp(
                _tcp_lib.pancake_tcp_accept(
                    raw, _codec_id(codec), max_frame_bytes, ctypes.byref(out)
                )
            )
            return TcpConnection(out, self._netlayer)


class TcpNetlayer:
    """Owns the blocking-TCP I/O backend; outlives the connections made from it.
    Released on :meth:`release` / context exit."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_netlayer_new(ctypes.byref(out)))
        self._native = NativeHandle(
            out,
            _release_netlayer,
            _tcp_lib.pancake_tcp_netlayer_shutdown,
            label="TCP netlayer",
        )
        # Children borrow this netlayer's pinned std.Io backend. A weak set
        # lets each child retain the owner without forming an ownership cycle;
        # explicit release still retires every child before the backend.
        self._children: "weakref.WeakSet[TcpConnection | TcpListener]" = weakref.WeakSet()
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
            _check_tcp(_tcp_lib.pancake_tcp_transport_provider(raw, ctypes.byref(package)))
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
                _tcp_lib.pancake_tcp_listen(
                    raw, ctypes.cast(buf, ctypes.c_void_p), n, port, ctypes.byref(out)
                )
            )
            return TcpListener(out, self)

    def connect(self, host: str, port: int, codec: str = "syrup", max_frame_bytes: int = 4096) -> TcpConnection:
        buf, n = _str_buf(host)
        out = ctypes.c_void_p()
        with self._native.lease() as raw:
            _check_tcp(
                _tcp_lib.pancake_tcp_connect(
                    raw,
                    ctypes.cast(buf, ctypes.c_void_p),
                    n,
                    port,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                )
            )
            return TcpConnection(out, self)


def install_provider(loop) -> None:
    """Install this archive's complete TCP package once per native driver."""
    if loop._has_transport(b"tcp"):
        return
    netlayer = TcpNetlayer()
    try:
        loop._install_provider(lambda register: register(netlayer._transport_provider()))
    except BaseException:
        netlayer.release()
        raise
    netlayer._relinquish_provider_reference()
