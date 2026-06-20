"""The in-process transport, pancake's ``libpancake_net_transport_inproc``
archive, surfaced à la carte.

This is the socket-free sibling of :mod:`pancake.tcp`: two peers in one process
wired by in-process pipes, with no kernel transport and no file descriptors. It
is a companion to the core :mod:`pancake` module, mirroring the C ABI's
symbol-disjoint archive split (ADR-0059). Importing it loads
``libpancake_net_transport_inproc`` on top of the core ``libpancake_ocapn``; it
shares the core's frame, context, and value layout but adds the
``pancake_inproc_*`` family with its own thread-local last-error.

A listener binds to an opaque string *designator* — any token, not a
``host:port`` — and a dialer names that same designator. The frame shuttle is
otherwise identical to TCP's, so the same peer machinery drives a full OCapN
conversation over it without touching a socket:

    from pancake import Peer
    from pancake.inproc import InprocNetlayer

    with InprocNetlayer() as nl:
        listener = nl.listen("demo")
        conn = nl.connect("demo")
        conn.write_frame(frame)

Every call blocks the calling thread, so run a listener's :meth:`accept` and a
connection's reads on their own threads, the same as the blocking TCP shuttle.
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
from ._ffi_inproc import _inproc_lib


def _inproc_last_error() -> Optional[str]:
    """The calling thread's last error message from the in-process transport
    archive (``libpancake_net_transport_inproc``), or ``None`` when there is
    none. The transport keeps its own thread-local slot, so an inproc call's
    diagnostic is read here and never from the core family's
    :func:`pancake.last_error`."""
    length = _inproc_lib.pancake_inproc_last_error(None, 0)
    if length == 0:
        return None
    buf = (ctypes.c_uint8 * (length + 1))()
    _inproc_lib.pancake_inproc_last_error(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


def _check_inproc(code: int) -> None:
    """Like :func:`pancake._check`, but reads the in-process transport's own
    thread-local last-error rather than the unrelated core one."""
    if code != _OK:
        raise PancakeError(code, _inproc_last_error())


def _designator_buf(designator: str):
    data = designator.encode()
    buf = ctypes.create_string_buffer(data, len(data))
    return buf, len(data)


class InprocConn:
    """One in-process connection carrying one OCapN session, framed on the
    netlayer's codec, the socket-free sibling of :class:`pancake.tcp.TcpEndpoint`.
    Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "InprocConn":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _inproc_lib.pancake_inproc_conn_release(self._raw)
            self._raw = None

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises PancakeError(ERR_CLOSED) on clean EOF."""
        frame = _ManagedFrame()
        _check_inproc(_inproc_lib.pancake_inproc_conn_read_frame(self._raw, ctypes.byref(frame)))
        out = ctypes.string_at(frame.bytes, frame.len)
        # The managed frame is the shared core vocabulary, so it is released
        # through the core archive even though the read came from the inproc one.
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check_inproc(_inproc_lib.pancake_inproc_conn_write_frame(self._raw, ctypes.byref(f)))


class InprocListener:
    """A bound in-process listener on a string designator. Closed on release /
    context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "InprocListener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _inproc_lib.pancake_inproc_listener_release(self._raw)
            self._raw = None

    def accept(self, codec: str = "syrup", max_frame_bytes: int = 4096) -> InprocConn:
        """Block until a dialer connects, returning an owned connection framing
        on ``codec``."""
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.pancake_inproc_accept(self._raw, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return InprocConn(out)


class InprocNetlayer:
    """Owns the in-process switchboard and its one I/O backend; outlives the
    endpoints and listeners made from it. Released on :meth:`release` / context
    exit."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.pancake_inproc_netlayer_new(ctypes.byref(out)))
        self._raw = out
        self._context: Optional["Context"] = None

    @classmethod
    def new_in(cls, context: "Context") -> "InprocNetlayer":
        """Create a netlayer whose switchboard, backend, and per-connection
        buffers allocate through ``context``. The context must outlive the
        netlayer."""
        self = cls.__new__(cls)
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.pancake_inproc_netlayer_new_in(context._raw, ctypes.byref(out)))
        self._raw = out
        # Keep the context alive at least as long as this netlayer (see Peer.new_in).
        self._context = context
        return self

    def __enter__(self) -> "InprocNetlayer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _inproc_lib.pancake_inproc_netlayer_release(self._raw)
            self._raw = None

    def listen(self, designator: str) -> InprocListener:
        """Bind a listener on ``designator``, any opaque token a dialer names."""
        buf, n = _designator_buf(designator)
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.pancake_inproc_listen(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, ctypes.byref(out)))
        return InprocListener(out)

    def connect(self, designator: str, codec: str = "syrup", max_frame_bytes: int = 4096) -> InprocConn:
        """Dial the listener bound at ``designator`` and return a framed
        connection."""
        buf, n = _designator_buf(designator)
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.pancake_inproc_connect(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, _codec_id(codec), max_frame_bytes, ctypes.byref(out)))
        return InprocConn(out)
