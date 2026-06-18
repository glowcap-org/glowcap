"""The blocking TCP transport — pancake's ``libpancake_net_transport_tcp``
archive, surfaced à la carte.

This is a companion to the core :mod:`pancake` module, mirroring the C ABI's
symbol-disjoint archive split (ADR-0059). Importing it loads
``libpancake_net_transport_tcp`` on top of the core ``libpancake_ocapn``; it
shares the core's frame, context, and value layout but adds the
``pancake_tcp_*`` family — a host-owned blocking frame shuttle over a real
kernel socket — with its own thread-local last-error. A consumer that drives
peers over TCP by hand composes it with the core:

    from pancake import Peer
    from pancake.tcp import TcpNetlayer

    with TcpNetlayer() as nl:
        listener = nl.listen("127.0.0.1", 0)
        conn = nl.connect("127.0.0.1", listener.port())
        conn.write_frame(frame)

This is the explicit, synchronous shuttle. The async, transport-neutral
application surface (:func:`pancake.connect`, :func:`pancake.listen`,
:class:`pancake.Connection`) lives in the core and drives TCP over asyncio
without this archive — reach here only when you want the blocking endpoints
themselves.
"""

from __future__ import annotations

import ctypes
from typing import Optional

from . import (
    Context,
    PancakeError,
    _codec_id,
    _FRAME_SHAPE_BYTE,
    _Frame,
    _ManagedFrame,
    _OK,
)
from ._ffi_core import _lib
from ._ffi_tcp import _tcp_lib


def _tcp_last_error() -> Optional[str]:
    """The calling thread's last error message from the TCP transport archive
    (``libpancake_net_transport_tcp``), or ``None`` when there is none. The
    transport keeps its own thread-local slot, so a tcp call's diagnostic is
    read here and never from the core family's :func:`pancake.last_error`."""
    length = _tcp_lib.pancake_tcp_last_error(None, 0)
    if length == 0:
        return None
    buf = (ctypes.c_uint8 * (length + 1))()
    _tcp_lib.pancake_tcp_last_error(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


def _check_tcp(code: int) -> None:
    """Like :func:`pancake._check`, but reads the TCP transport's own
    thread-local last-error rather than the unrelated core one."""
    if code != _OK:
        raise PancakeError(code, _tcp_last_error())


class TcpEndpoint:
    """A blocking TCP endpoint: the ``pancake_tcp_*`` frame shuttle over one
    socket. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "TcpEndpoint":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _tcp_lib.pancake_tcp_conn_release(self._raw)
            self._raw = None

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises PancakeError(ERR_CLOSED) on clean EOF."""
        frame = _ManagedFrame()
        _check_tcp(_tcp_lib.pancake_tcp_conn_read_frame(self._raw, ctypes.byref(frame)))
        out = ctypes.string_at(frame.bytes, frame.len)
        # The managed frame is the shared core vocabulary, so it is released
        # through the core archive even though the read came from the tcp one.
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check_tcp(_tcp_lib.pancake_tcp_conn_write_frame(self._raw, ctypes.byref(f)))


class TcpListener:
    """A bound TCP listener. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "TcpListener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _tcp_lib.pancake_tcp_listener_release(self._raw)
            self._raw = None

    def port(self) -> int:
        out = ctypes.c_uint16()
        _check_tcp(_tcp_lib.pancake_tcp_listener_port(self._raw, ctypes.byref(out)))
        return out.value

    def accept(self, codec: str = "syrup", max_frame_bytes: int = 4096) -> TcpEndpoint:
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_accept(self._raw, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return TcpEndpoint(out)


def _host_buf(host: str):
    data = host.encode()
    buf = ctypes.create_string_buffer(data, len(data))
    return buf, len(data)


class TcpNetlayer:
    """Owns the blocking-TCP I/O backend; outlives the endpoints made from it.
    Released on :meth:`release` / context exit."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_netlayer_new(ctypes.byref(out)))
        self._raw = out
        self._context: Optional["Context"] = None

    @classmethod
    def new_in(cls, context: "Context") -> "TcpNetlayer":
        """Create a netlayer whose backend and per-connection buffers allocate
        through ``context``. The context must outlive the netlayer."""
        self = cls.__new__(cls)
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_netlayer_new_in(context._raw, ctypes.byref(out)))
        self._raw = out
        # Keep the context alive at least as long as this netlayer (see Peer.new_in).
        self._context = context
        return self

    def __enter__(self) -> "TcpNetlayer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _tcp_lib.pancake_tcp_netlayer_release(self._raw)
            self._raw = None

    def listen(self, host: str, port: int = 0) -> TcpListener:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_listen(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, ctypes.byref(out)))
        return TcpListener(out)

    def connect(self, host: str, port: int, codec: str = "syrup", max_frame_bytes: int = 4096) -> TcpEndpoint:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check_tcp(_tcp_lib.pancake_tcp_connect(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return TcpEndpoint(out)
