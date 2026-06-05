"""Netlayer-seam abstraction over the TCP / TLS / iroh endpoint cdylibs.

The transports differ at exactly four per-connection frame ops plus the
``acceptable_location`` transport tag the handshake advertises. Bundling
them into :class:`TransportOps` lets one pump (:mod:`pancake.pump`) drive
cleartext TCP, TCP+TLS, or iroh without per-transport forks — exactly the
shape the Racket ``transport-ops`` struct + the per-transport bundles take.

``read_frame`` returns either ``bytes`` (a complete Syrup frame, copied out
of the netlayer's managed frame, which is released before return) or one of
the sentinels :data:`WOULD_BLOCK` / :data:`CLOSED` / :data:`MALFORMED`.
"""

from __future__ import annotations

from ctypes import byref, c_char, c_uint8, c_void_p, string_at
from dataclasses import dataclass
from typing import Callable, Optional, Union

from . import _net_iroh, _net_tcp
from ._abi import (
    PANCAKE_ENDPOINT_ERR_CLOSED,
    PANCAKE_ENDPOINT_ERR_MALFORMED,
    PANCAKE_ENDPOINT_ERR_WOULD_BLOCK,
    PANCAKE_OK,
    PancakeManagedFrame,
)

# Sentinels for non-bytes read_frame / accept outcomes.
WOULD_BLOCK = "would_block"
CLOSED = "closed"
MALFORMED = "malformed"

FrameResult = Union[bytes, str]


class EndpointError(RuntimeError):
    pass


@dataclass
class TransportOps:
    """The four frame ops + transport tag that distinguish a netlayer."""

    name: str
    _read: Callable
    _write: Callable
    _set_timeout: Callable
    _close: Callable
    _release_managed: Callable
    _last_error: Callable


class Connection:
    """One dialed or accepted connection, driven through :class:`TransportOps`."""

    def __init__(self, handle: int, ops: TransportOps):
        self.handle = handle
        self.ops = ops

    def set_read_timeout_ms(self, ms: int) -> None:
        rc = self.ops._set_timeout(self.handle, ms)
        if rc != PANCAKE_OK:
            raise EndpointError(
                f"{self.ops.name} set_read_timeout rc={rc}; {self.ops._last_error()}"
            )

    def read_frame(self) -> FrameResult:
        mf = PancakeManagedFrame()
        rc = self.ops._read(self.handle, byref(mf))
        if rc == PANCAKE_OK:
            data = string_at(mf.bytes, mf.len) if mf.len else b""
            self.ops._release_managed(byref(mf))
            return data
        if rc == PANCAKE_ENDPOINT_ERR_WOULD_BLOCK:
            return WOULD_BLOCK
        if rc == PANCAKE_ENDPOINT_ERR_CLOSED:
            return CLOSED
        if rc == PANCAKE_ENDPOINT_ERR_MALFORMED:
            return MALFORMED
        raise EndpointError(f"{self.ops.name} read_frame rc={rc}; {self.ops._last_error()}")

    def write_frame(self, data: bytes) -> None:
        buf = (c_uint8 * len(data)).from_buffer_copy(bytes(data)) if data else None
        rc = self.ops._write(self.handle, buf, len(data))
        if rc != PANCAKE_OK:
            raise EndpointError(
                f"{self.ops.name} write_frame rc={rc}; {self.ops._last_error()}"
            )

    def close(self) -> None:
        if self.handle:
            self.ops._close(self.handle)
        self.handle = 0


class Listener:
    def __init__(self, handle: int, accept_fn: Callable, close_fn: Callable,
                 ops: TransportOps, last_error: Callable, bound_addr: str = ""):
        self.handle = handle
        self._accept = accept_fn
        self._close = close_fn
        self.ops = ops
        self._last_error = last_error
        self.bound_addr = bound_addr

    def accept_timed(self, timeout_ms: int) -> Union[Connection, str]:
        out = c_void_p()
        rc = self._accept(self.handle, timeout_ms, byref(out))
        if rc == PANCAKE_OK:
            return Connection(out.value, self.ops)
        if rc == PANCAKE_ENDPOINT_ERR_WOULD_BLOCK:
            return WOULD_BLOCK
        raise EndpointError(f"{self.ops.name} accept rc={rc}; {self._last_error()}")

    def close(self) -> None:
        if self.handle:
            self._close(self.handle)
        self.handle = 0


# ─── TCP netlayer (cleartext + TLS, one cdylib) ──────────────────────────


class TcpNetlayer:
    def __init__(self, lib: Optional[_net_tcp.NetTcpLib] = None):
        self.lib = lib or _net_tcp.load()
        L = self.lib
        self.tcp_ops = TransportOps(
            "tcp-testing-only",
            L.pancake_endpoint_tcp_read_frame,
            L.pancake_endpoint_tcp_write_frame,
            L.pancake_endpoint_tcp_set_read_timeout_ms,
            L.pancake_endpoint_tcp_conn_close,
            L.pancake_managed_frame_release,
            L.last_error,
        )
        self.tls_ops = TransportOps(
            "tcp-tls",
            L.pancake_endpoint_tcp_tls_read_frame,
            L.pancake_endpoint_tcp_tls_write_frame,
            L.pancake_endpoint_tcp_tls_set_read_timeout_ms,
            L.pancake_endpoint_tcp_tls_conn_close,
            L.pancake_managed_frame_release,  # shared managed-frame release
            L.last_error,
        )

    # cleartext
    def connect(self, host: str, port: int) -> Connection:
        h = self.lib.pancake_endpoint_tcp_connect(f"{host}:{port}".encode())
        if not h:
            raise EndpointError(f"tcp connect {host}:{port} failed; {self.lib.last_error()}")
        return Connection(h, self.tcp_ops)

    def listen(self, host: str, port: int) -> Listener:
        out = (c_char * 64)()
        h = self.lib.pancake_endpoint_tcp_listen(f"{host}:{port}".encode(), out, 64)
        if not h:
            raise EndpointError(f"tcp listen {host}:{port} failed; {self.lib.last_error()}")
        return Listener(
            h,
            self.lib.pancake_endpoint_tcp_accept_timed,
            self.lib.pancake_endpoint_tcp_listener_close,
            self.tcp_ops,
            self.lib.last_error,
            out.value.decode("utf-8") if out.value else f"{host}:{port}",
        )

    # TLS
    def tls_connect(self, host: str, port: int) -> Connection:
        h = self.lib.pancake_endpoint_tcp_tls_connect(f"{host}:{port}".encode())
        if not h:
            raise EndpointError(f"tls connect {host}:{port} failed; {self.lib.last_error()}")
        return Connection(h, self.tls_ops)

    def tls_listen(self, host: str, port: int) -> Listener:
        out = (c_char * 64)()
        h = self.lib.pancake_endpoint_tcp_tls_listen(f"{host}:{port}".encode(), out, 64)
        if not h:
            raise EndpointError(f"tls listen {host}:{port} failed; {self.lib.last_error()}")
        return Listener(
            h,
            self.lib.pancake_endpoint_tcp_tls_accept_timed,
            self.lib.pancake_endpoint_tcp_tls_listener_close,
            self.tls_ops,
            self.lib.last_error,
            out.value.decode("utf-8") if out.value else f"{host}:{port}",
        )


# ─── iroh netlayer (QUIC) ────────────────────────────────────────────────


class IrohEndpoint:
    def __init__(self, netlayer: "IrohNetlayer", handle: int):
        self._nl = netlayer
        self.handle = handle

    def endpoint_id(self) -> str:
        buf = (c_char * _net_iroh.IROH_ID_CAP)()
        rc = self._nl.lib.pancake_endpoint_iroh_endpoint_id(
            self.handle, buf, _net_iroh.IROH_ID_CAP
        )
        if rc != PANCAKE_OK:
            raise EndpointError(f"iroh endpoint_id rc={rc}; {self._nl.lib.last_error()}")
        return buf.value.decode("utf-8")

    def bound_addr(self) -> str:
        buf = (c_char * 64)()
        rc = self._nl.lib.pancake_endpoint_iroh_bound_addr(self.handle, buf, 64)
        if rc != PANCAKE_OK:
            raise EndpointError(f"iroh bound_addr rc={rc}; {self._nl.lib.last_error()}")
        return buf.value.decode("utf-8")

    def connect(self, partner_endpoint_id: str, direct_addr: Optional[str] = None) -> Connection:
        h = self._nl.lib.pancake_endpoint_iroh_connect(
            self.handle,
            partner_endpoint_id.encode(),
            direct_addr.encode() if direct_addr else None,
        )
        if not h:
            raise EndpointError(
                f"iroh connect to {partner_endpoint_id} failed; {self._nl.lib.last_error()}"
            )
        return Connection(h, self._nl.ops)

    def listen(self) -> Listener:
        h = self._nl.lib.pancake_endpoint_iroh_listen(self.handle)
        if not h:
            raise EndpointError(f"iroh listen failed; {self._nl.lib.last_error()}")
        return Listener(
            h,
            self._nl.lib.pancake_endpoint_iroh_accept_timed,
            self._nl.lib.pancake_endpoint_iroh_listener_close,
            self._nl.ops,
            self._nl.lib.last_error,
        )

    def close(self) -> None:
        if self.handle:
            self._nl.lib.pancake_endpoint_iroh_close(self.handle)
        self.handle = 0


class IrohNetlayer:
    def __init__(self, lib: Optional[_net_iroh.NetIrohLib] = None):
        self.lib = lib or _net_iroh.load()
        L = self.lib
        self.ops = TransportOps(
            "iroh",
            L.pancake_endpoint_iroh_read_frame,
            L.pancake_endpoint_iroh_write_frame,
            L.pancake_endpoint_iroh_set_read_timeout_ms,
            L.pancake_endpoint_iroh_conn_close,
            L.pancake_managed_frame_release,
            L.last_error,
        )

    def new_endpoint(self) -> IrohEndpoint:
        h = self.lib.pancake_endpoint_iroh_new()
        if not h:
            raise EndpointError(f"iroh endpoint construction failed; {self.lib.last_error()}")
        return IrohEndpoint(self, h)
