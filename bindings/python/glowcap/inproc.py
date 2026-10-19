"""The in-process transport, glowcap's ``libglowcap_net_transport_inproc``
archive, surfaced à la carte.

This is the socket-free sibling of :mod:`glowcap.tcp`: two peers in one process
wired by in-process pipes, with no kernel transport. The C listener adds a wake
descriptor for reactor integration. No application bytes flow through it. It is
a companion to the core :mod:`glowcap` module, mirroring the C ABI's
symbol-disjoint archive split (ADR-0022). Importing it loads
``libglowcap_net_transport_inproc`` on top of the core ``libglowcap_ocapn``. It
shares the core's frame, context, and value layout but adds the
``glowcap_inproc_*`` family with its own thread-local last-error.

A listener binds to an opaque string *designator*, any token, not a
``host:port``, and a dialer names that same designator. The frame shuttle is
otherwise identical to TCP's, so the same machinery drives a full OCapN
conversation over it without touching a socket:

    from glowcap.inproc import InprocNetlayer

    with InprocNetlayer() as nl:
        listener = nl.listen("demo")
        conn = nl.connect("demo")
        conn.write_frame(frame)

Accept and frame I/O block the calling thread, so run them on their own threads,
the same as the blocking TCP shuttle. Dialing an already-bound in-process
designator is immediate.
"""

from __future__ import annotations

import ctypes
import threading
import weakref
from typing import Optional

from ._abi_value import _DEFAULT_CODEC, _codec_id
from ._constants import OK as _OK, RAW_TRANSPORT_DEFAULT_FRAME_CAP, TRANSPORT_INPROC
from ._errors import GlowcapError
from ._ffi_ocapn import (
    _borrowed_byte_frame,
    _copy_managed_frame,
    _ManagedFrame,
    _read_last_error,
    _str_buf,
)
from ._ffi_inproc import _inproc_lib
from ._ffi import FfiHandle, _FfiHandleOwner
from ._locator import Locator

__all__ = ["InprocNetlayer", "InprocListener", "InprocConnection", "locator"]


def locator(designator: str) -> Locator:
    """Build a hint-free locator for an in-process switchboard name."""
    return Locator(TRANSPORT_INPROC, designator, {}, "boolean-false")


def _inproc_last_error() -> Optional[str]:
    """The calling thread's last error message from the in-process transport
    archive (``libglowcap_net_transport_inproc``), or ``None`` when there is
    none. The transport keeps its own thread-local slot, so an inproc call's
    diagnostic is read here and never from the core family's
    :func:`glowcap.last_error`."""
    return _read_last_error(_inproc_lib.glowcap_inproc_last_error)


def _check_inproc(code: int) -> None:
    """Like :func:`glowcap._check`, but reads the in-process transport's own
    thread-local last-error rather than the unrelated core one."""
    if code != _OK:
        raise GlowcapError(code, _inproc_last_error())


def _release_conn(raw) -> None:
    _inproc_lib.glowcap_inproc_conn_release(raw)


def _release_listener(raw) -> None:
    _check_inproc(_inproc_lib.glowcap_inproc_listener_release(raw, None, 0, None))


def _release_netlayer(raw) -> None:
    _inproc_lib.glowcap_inproc_netlayer_release(raw)


class InprocConnection(_FfiHandleOwner):
    """One in-process connection carrying one OCapN session, framed on the
    netlayer's codec, the socket-free sibling of :class:`glowcap.tcp.TcpConnection`.
    Closed on release / context exit."""

    def __init__(self, raw, netlayer: "InprocNetlayer"):
        self._netlayer = netlayer
        self._ffi = FfiHandle(
            raw,
            _release_conn,
            _inproc_lib.glowcap_inproc_conn_shutdown,
            label="inproc connection",
            keepalive=netlayer,
        )
        self._reads = threading.Lock()
        self._writes = threading.Lock()
        if not netlayer._adopt(self):
            self._ffi.close()
            raise RuntimeError("inproc netlayer is released")

    def __enter__(self) -> "InprocConnection":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._ffi.close()
        self._netlayer._forget(self)

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises GlowcapError(ERR_CLOSED) on clean EOF."""
        with self._reads, self._ffi.lease() as raw:
            frame = _ManagedFrame()
            _check_inproc(
                _inproc_lib.glowcap_inproc_conn_read_frame(
                    raw, ctypes.byref(frame), None, 0, None
                )
            )
            return _copy_managed_frame(frame)

    def write_frame(self, frame: bytes) -> None:
        f, _borrowed = _borrowed_byte_frame(frame)
        with self._writes, self._ffi.lease() as raw:
            _check_inproc(
                _inproc_lib.glowcap_inproc_conn_write_frame(
                    raw, ctypes.byref(f), None, 0, None
                )
            )


class InprocListener(_FfiHandleOwner):
    """A bound in-process listener on a string designator. Closed on release /
    context exit."""

    def __init__(self, raw, netlayer: "InprocNetlayer"):
        self._netlayer = netlayer
        self._ffi = FfiHandle(
            raw,
            _release_listener,
            _inproc_lib.glowcap_inproc_listener_shutdown,
            label="inproc listener",
            keepalive=netlayer,
        )
        self._accepts = threading.Lock()
        if not netlayer._adopt(self):
            self._ffi.close()
            raise RuntimeError("inproc netlayer is released")

    def __enter__(self) -> "InprocListener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        self._ffi.close()
        self._netlayer._forget(self)

    def accept(
        self,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
    ) -> InprocConnection:
        """Block until a dialer connects, returning an owned connection framing
        on ``codec``."""
        with self._accepts, self._ffi.lease() as raw:
            out = ctypes.c_void_p()
            _check_inproc(
                _inproc_lib.glowcap_inproc_accept(
                    raw,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            return InprocConnection(out, self._netlayer)

    def readiness_fd(self) -> int:
        """Return the borrowed wake descriptor for reactor integration.

        The listener owns it. Callers must not close it or retain it after
        :meth:`close`.
        """
        out = ctypes.c_int32()
        with self._ffi.lease() as raw:
            _check_inproc(
                _inproc_lib.glowcap_inproc_listener_readiness_fd(raw, ctypes.byref(out))
            )
        return out.value


class InprocNetlayer(_FfiHandleOwner):
    """Owns the in-process switchboard and its one I/O backend. Outlives the
    connections and listeners made from it. Released on :meth:`release` / context
    exit."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check_inproc(_inproc_lib.glowcap_inproc_netlayer_new(ctypes.byref(out)))
        self._ffi = FfiHandle(out, _release_netlayer, label="inproc netlayer")
        self._children: "weakref.WeakSet[InprocConnection | InprocListener]" = weakref.WeakSet()
        self._children_lock = threading.Lock()
        self._release_lock = threading.Lock()
        self._release_requested = False

    def __enter__(self) -> "InprocNetlayer":
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
            self._ffi.close()

    def _adopt(self, child: "InprocConnection | InprocListener") -> bool:
        with self._children_lock:
            if self._release_requested:
                return False
            self._children.add(child)
            return True

    def _forget(self, child: "InprocConnection | InprocListener") -> None:
        with self._children_lock:
            self._children.discard(child)

    def listen(self, designator: str) -> InprocListener:
        """Bind a listener on ``designator``, any opaque token a dialer names."""
        buf, n = _str_buf(designator)
        out = ctypes.c_void_p()
        with self._ffi.lease() as raw:
            _check_inproc(
                _inproc_lib.glowcap_inproc_listen(
                    raw, ctypes.cast(buf, ctypes.c_void_p), n, ctypes.byref(out)
                )
            )
            return InprocListener(out, self)

    def connect(
        self,
        designator: str,
        codec: str = _DEFAULT_CODEC,
        max_frame_bytes: int = RAW_TRANSPORT_DEFAULT_FRAME_CAP,
    ) -> InprocConnection:
        """Dial the listener bound at ``designator`` and return a framed
        connection."""
        buf, n = _str_buf(designator)
        out = ctypes.c_void_p()
        with self._ffi.lease() as raw:
            _check_inproc(
                _inproc_lib.glowcap_inproc_connect(
                    raw,
                    ctypes.cast(buf, ctypes.c_void_p),
                    n,
                    _codec_id(codec),
                    max_frame_bytes,
                    ctypes.byref(out),
                    None,
                    0,
                    None,
                )
            )
            return InprocConnection(out, self)
