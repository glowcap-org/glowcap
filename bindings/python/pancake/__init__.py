"""Idiomatic Python API for pancake, an OCapN/CapTP peer you drive.

This is the core package: it rides the universal ``libpancake_ocapn`` archive
and is usable on its own. The raw ``ctypes`` FFI lives in the internal
:mod:`pancake._ffi_core` module; this package is just the public surface over
it. What you use is a :class:`Peer` (a context manager that releases itself),
native Python values as arguments
(``int``/``float``/``bool``/``bytes``/``str``/``list``, plus :class:`Symbol` and
references), and typed :class:`Event` objects out of :meth:`Peer.poll`. The
default :class:`Peer` negotiates an authenticated session; raw direct-frame
fixtures use :meth:`Peer.raw_open`.

    with Peer.raw_open() as peer:
        peer.register_import(5)
        peer.send_deliver(Far(5), [42, b"hi"], answer=9)
        peer.step()
        frame = peer.take_outbound()

The C ABI ships as a set of composable, symbol-disjoint archives (ADR-0059), and
this package mirrors that à la carte: the core here, plus one submodule per
transport. Each transport submodule loads only its own archive, so importing
:mod:`pancake` never loads a transport and importing one transport never loads
another. Compose what you need:

    from pancake import Peer, connect, listen
    from pancake.tcp import TcpNetlayer        # libpancake_net_transport_tcp
    from pancake.inproc import InprocNetlayer  # libpancake_net_transport_inproc
    from pancake.iroh import listen_iroh       # libpancake_net_transport_iroh

The async :func:`connect` / :func:`listen` / :class:`Connection` surface here is
transport-neutral and pure-asyncio over a TCP socket, so a plain TCP application
needs only this core. The blocking ``pancake_tcp_*`` frame shuttle lives in
:mod:`pancake.tcp`; the socket-free in-process transport in
:mod:`pancake.inproc`; the encrypted-QUIC transport in :mod:`pancake.iroh`. An
``iroh`` locator handed to :func:`connect` reaches the iroh submodule lazily, so
the core never hard-depends on the optional iroh artifact.
"""

from __future__ import annotations

import asyncio
import ctypes
import secrets
import weakref
from dataclasses import dataclass, field
from typing import Callable, NamedTuple, Optional, Union

from . import _constants as _abi
from ._ffi_core import (
    _AllocFn,
    _Allocator,
    _AnyEvent,
    _Argument,
    _EnlivenStart,
    _Frame,
    _FreeFn,
    _LastAbort,
    _ManagedFrame,
    _ManagedFrameRelease,
    _NodeAction,
    _Reference,
    _lib,
)


_OK = _abi.OK
_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT
_WOULD_BLOCK = _abi.WOULD_BLOCK
_ERR_CLOSED = _abi.ERR_CLOSED
_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE
_FRAME_SHAPE_BYTE = _abi.FRAME_SHAPE_BYTE
_PROJECTION_DELIVER = _abi.PROJECTION_DELIVER
_PROJECTION_RESOLVE = _abi.PROJECTION_RESOLVE
_NODE_ACTION_DIAL = _abi.NODE_ACTION_DIAL
_NODE_ACTION_FLUSH = _abi.NODE_ACTION_FLUSH
_NODE_ACTION_SETTLE = _abi.NODE_ACTION_SETTLE
_NODE_ACTION_FAIL = _abi.NODE_ACTION_FAIL
_NODE_ACTION_NEED_GIFT_ID = _abi.NODE_ACTION_NEED_GIFT_ID
_REDEEM_OUTCOME_FAR = _abi.REDEEM_OUTCOME_FAR
_REDEEM_OUTCOME_BROKEN = _abi.REDEEM_OUTCOME_BROKEN
_REDEEM_OUTCOME_NOT_CAPABILITY = _abi.REDEEM_OUTCOME_NOT_CAPABILITY

_REF_NEAR, _REF_FAR, _REF_PROMISE, _REF_STURDY, _REF_BROKEN = (
    _abi.REF_NEAR,
    _abi.REF_FAR,
    _abi.REF_PROMISE,
    _abi.REF_STURDY,
    _abi.REF_BROKEN,
)
_REF_SUB_OBJECT, _REF_SUB_PROMISE = _abi.REF_SUB_OBJECT, _abi.REF_SUB_PROMISE

_ARG_INTEGER, _ARG_FLOAT64, _ARG_BOOLEAN, _ARG_BYTES = (
    _abi.ARG_INTEGER,
    _abi.ARG_FLOAT64,
    _abi.ARG_BOOLEAN,
    _abi.ARG_BYTES,
)
_ARG_STRING, _ARG_SYMBOL, _ARG_VOID, _ARG_REFERENCE, _ARG_LIST = (
    _abi.ARG_STRING,
    _abi.ARG_SYMBOL,
    _abi.ARG_VOID,
    _abi.ARG_REFERENCE,
    _abi.ARG_LIST,
)
_ARG_SET, _ARG_TAGGED, _ARG_KEYWORD = _abi.ARG_SET, _abi.ARG_TAGGED, _abi.ARG_KEYWORD
_ARG_BIG_INTEGER = _abi.ARG_BIG_INTEGER

_RESOLUTION_FULFILL, _RESOLUTION_BREAK = _abi.RESOLUTION_FULFILL, _abi.RESOLUTION_BREAK
_RESOLUTION_HANDOFF = _abi.RESOLUTION_HANDOFF
_ENLIVEN_CACHED = _abi.ENLIVEN_CACHED
_ENLIVEN_OUTCOME_FULFILLED, _ENLIVEN_OUTCOME_BROKEN = (
    _abi.ENLIVEN_OUTCOME_FULFILLED,
    _abi.ENLIVEN_OUTCOME_BROKEN,
)
_HINTS_EMPTY_MAP, _HINTS_EMPTY_FALSE = _abi.HINTS_EMPTY_MAP, _abi.HINTS_EMPTY_FALSE


# ── Public value vocabulary ──────────────────────────────────────────────────


def abi_version() -> tuple[int, int, int]:
    """The linked library's ``(major, minor, patch)`` ABI version."""
    major = ctypes.c_uint32()
    minor = ctypes.c_uint32()
    patch = ctypes.c_uint32()
    _lib.pancake_abi_version(ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch))
    return (major.value, minor.value, patch.value)


def last_error() -> Optional[str]:
    """The calling thread's last error message, or ``None`` when there is none."""
    length = _lib.pancake_last_error(None, 0)
    if length == 0:
        return None
    # The C side reserves one byte for a NUL and copies at most cap-1 message
    # bytes, so allocate length + 1 to receive all `length` of them.
    buf = (ctypes.c_uint8 * (length + 1))()
    _lib.pancake_last_error(buf, length + 1)
    return bytes(buf[:length]).decode(errors="replace")


@dataclass(frozen=True)
class AbortDetail:
    """The typed cause of a peer's most recent local dispatch failure, the
    counterpart of the C ABI's ``PancakeLastAbort``. ``domain`` names the layer
    that refused (``"codec"``, ``"session"``, or ``"foreign"``), ``kind`` the
    projected ``op:abort`` kind when one exists, ``message`` the static
    diagnostic, and ``error_name`` the originating error."""

    domain: str
    kind: Optional[str]
    message: str
    error_name: str


class PancakeError(Exception):
    """A failed C ABI call, carrying the negative ``PANCAKE_ERR_*`` code.

    When a per-thread error message is available it is captured at raise time
    (the message is thread-local and may be overwritten by a later call) and
    shown by ``str(err)``. When the failure was a refused inbound frame,
    ``abort`` carries the typed :class:`AbortDetail` naming which layer refused
    and why.
    """

    def __init__(self, code: int, message: Optional[str] = None, abort: Optional[AbortDetail] = None):
        if message:
            super().__init__(f"pancake error {code}: {message}")
        else:
            super().__init__(f"pancake error {code}")
        self.code = code
        self.message = message
        self.abort = abort


def _check(code: int) -> None:
    if code != _OK:
        # Capture the thread-local message now, before any later call clobbers it.
        raise PancakeError(code, last_error())


@dataclass(frozen=True)
class Near:
    """A local export this peer hosts."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Far:
    """A partner-hosted import this peer holds."""

    id: int
    promise: bool = False


@dataclass(frozen=True)
class Promise:
    """A pipeline promise on an answer."""

    answer: int


@dataclass(frozen=True)
class Sturdy:
    pass


@dataclass(frozen=True)
class Broken:
    pass


Reference = Union[Near, Far, Promise, Sturdy, Broken]


class Symbol(str):
    """A string that marshals as an OCapN symbol rather than a string."""


class Keyword(str):
    """A string that marshals as an OCapN keyword."""


class Set(list):
    """A list that marshals as an OCapN set (elements may be unhashable)."""


@dataclass(frozen=True)
class Tagged:
    """An OCapN tagged record: a tag symbol over a value list."""

    tag: str
    value: list


# An argument is a native Python value or a wrapper:
#   int, float, bool, bytes, str, Symbol, Keyword, None (void), Reference, list,
#   Set, Tagged.
Argument = Union[int, float, bool, bytes, str, "Symbol", "Keyword", None, Reference, list, "Set", "Tagged"]

# An application value mirrors an Argument but carries a capability as a `Ref`
# (the binding marshals it to/from a wire reference at the boundary), so an app
# works with capabilities as ordinary values; this is the vocabulary the
# application-surface `Connection` speaks. See :class:`Connection`.
Value = Union[int, float, bool, bytes, str, "Symbol", "Keyword", None, "Ref", list, "Set", "Tagged"]

# An actor: handle a ``(verb, args)`` call and return a reply (``None`` is the
# OCapN void). ``args`` may contain :class:`Ref`s (capabilities handed to you);
# raise to break the caller's promise.
Behavior = Callable[[str, "list[Value]"], "Optional[Value]"]


@dataclass(frozen=True)
class Fulfill:
    value: Argument


@dataclass(frozen=True)
class Break:
    message: str


@dataclass(frozen=True)
class Handoff:
    """A ``desc:handoff-give`` an answer resolved to (ADR-0009/ADR-0056): the
    recipient must redeem it against the named exporter rather than read an
    immediate value. ``give`` is the verbatim signed envelope to relay unaltered
    to the exporter; ``exporter_locator`` is the exporter's dialable
    ``ocapn://`` URI, or ``""`` when the give's location is not a flat locator;
    ``recipient_key`` is the 32-byte Ed25519 key the give is addressed to. The
    high-level :class:`Connection` redeems this transparently through the
    node's serve step (ADR-0067)."""

    give: bytes
    exporter_locator: str
    recipient_key: bytes


Resolution = Union[Fulfill, Break, Handoff]


@dataclass(frozen=True)
class Deliver:
    target: Reference
    args: list
    answer: Optional[int] = None


@dataclass(frozen=True)
class Resolve:
    answer: int
    resolution: Resolution


@dataclass(frozen=True)
class Other:
    """Any other surfaced event (abort, gc, handoff, …), with its raw frame."""

    kind: int
    frame: bytes


Event = Union[Deliver, Resolve, Other]


# ── Marshalling ──────────────────────────────────────────────────────────────


def _ref_to_c(ref: Reference) -> _Reference:
    if isinstance(ref, Near):
        sub = _REF_SUB_PROMISE if ref.promise else _REF_SUB_OBJECT
        return _Reference(_REF_NEAR, sub, ref.id)
    if isinstance(ref, Far):
        sub = _REF_SUB_PROMISE if ref.promise else _REF_SUB_OBJECT
        return _Reference(_REF_FAR, sub, ref.id)
    if isinstance(ref, Promise):
        return _Reference(_REF_PROMISE, 0, ref.answer)
    raise PancakeError(_ERR_UNSUPPORTED_VALUE, "sturdy/broken ref not carried on send")


def _arg_to_c(value: Argument, keepalive: list) -> _Argument:
    a = _Argument()
    if isinstance(value, bool):  # before int; bool is an int subclass
        a.kind, a.boolean = _ARG_BOOLEAN, 1 if value else 0
    elif isinstance(value, int):
        # ctypes silently wraps an out-of-range int mod 2**64; OCapN integers are
        # bignums, so refuse anything the C ABI int64 cannot carry rather than
        # send a corrupted value.
        if not (-(2**63) <= value < 2**63):
            # Outside the C ABI int64: ARG_BIG_INTEGER carries the canonical
            # decimal digits in bytes/bytes_len and the sign in boolean (ADR-0049).
            _set_bytes(a, _ARG_BIG_INTEGER, str(abs(value)).encode(), keepalive)
            a.boolean = 1 if value < 0 else 0
        else:
            a.kind, a.integer = _ARG_INTEGER, value
    elif isinstance(value, float):
        a.kind, a.float64 = _ARG_FLOAT64, value
    elif isinstance(value, Symbol):  # before str
        _set_bytes(a, _ARG_SYMBOL, value.encode(), keepalive)
    elif isinstance(value, Keyword):  # before str
        _set_bytes(a, _ARG_KEYWORD, value.encode(), keepalive)
    elif isinstance(value, str):
        _set_bytes(a, _ARG_STRING, value.encode(), keepalive)
    elif isinstance(value, (bytes, bytearray)):
        _set_bytes(a, _ARG_BYTES, bytes(value), keepalive)
    elif value is None:
        a.kind = _ARG_VOID
    elif isinstance(value, (Near, Far, Promise, Sturdy, Broken)):
        a.kind, a.reference = _ARG_REFERENCE, _ref_to_c(value)
    elif isinstance(value, Tagged):
        a.kind = _ARG_TAGGED
        _set_bytes(a, _ARG_TAGGED, value.tag.encode(), keepalive)
        a.items, a.items_len = _args_to_c(list(value.value), keepalive)
    elif isinstance(value, Set):  # before list
        a.kind = _ARG_SET
        a.items, a.items_len = _args_to_c(list(value), keepalive)
    elif isinstance(value, list):
        a.kind = _ARG_LIST
        a.items, a.items_len = _args_to_c(value, keepalive)
    else:
        raise PancakeError(_ERR_UNSUPPORTED_VALUE, "unsupported argument value")
    return a


def _set_bytes(a: _Argument, kind: int, data: bytes, keepalive: list) -> None:
    buf = ctypes.create_string_buffer(data, len(data))
    keepalive.append(buf)
    a.kind = kind
    a.bytes = ctypes.cast(buf, ctypes.c_void_p)
    a.bytes_len = len(data)


def _args_to_c(args: list, keepalive: list):
    n = len(args)
    arr = (_Argument * n)(*[_arg_to_c(v, keepalive) for v in args])
    keepalive.append(arr)
    return (arr if n else None, n)


def _ref_from_c(r: _Reference) -> Reference:
    promise = r.sub_kind == _REF_SUB_PROMISE
    if r.kind == _REF_NEAR:
        return Near(r.id, promise)
    if r.kind == _REF_FAR:
        return Far(r.id, promise)
    if r.kind == _REF_PROMISE:
        return Promise(r.id)
    if r.kind == _REF_STURDY:
        return Sturdy()
    return Broken()


def _bytes_from_c(a: _Argument) -> bytes:
    if not a.bytes or a.bytes_len == 0:
        return b""
    return ctypes.string_at(a.bytes, a.bytes_len)


def _arg_from_c(a: _Argument) -> Argument:
    if a.kind == _ARG_INTEGER:
        return a.integer
    if a.kind == _ARG_FLOAT64:
        return a.float64
    if a.kind == _ARG_BOOLEAN:
        return a.boolean != 0
    if a.kind == _ARG_BYTES:
        return _bytes_from_c(a)
    # Syrup strings/symbols are unchecked partner bytes; decode leniently so a
    # hostile non-UTF-8 payload surfaces as a value (matching Rust's
    # from_utf8_lossy and Deno's non-fatal TextDecoder) instead of crashing the
    # poll with UnicodeDecodeError.
    if a.kind == _ARG_STRING:
        return _bytes_from_c(a).decode(errors="replace")
    if a.kind == _ARG_SYMBOL:
        return Symbol(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_REFERENCE:
        return _ref_from_c(a.reference)
    if a.kind == _ARG_LIST:
        return [_arg_from_c(a.items[i]) for i in range(a.items_len)]
    if a.kind == _ARG_SET:
        return Set(_arg_from_c(a.items[i]) for i in range(a.items_len))
    if a.kind == _ARG_TAGGED:
        return Tagged(_bytes_from_c(a).decode(errors="replace"), [_arg_from_c(a.items[i]) for i in range(a.items_len)])
    if a.kind == _ARG_KEYWORD:
        return Keyword(_bytes_from_c(a).decode(errors="replace"))
    if a.kind == _ARG_VOID:
        return None
    if a.kind == _ARG_BIG_INTEGER:
        # Canonical decimal digits + sign flag back to a native int (ADR-0049).
        magnitude = int(_bytes_from_c(a))
        return -magnitude if a.boolean != 0 else magnitude
    raise PancakeError(_ERR_INVALID_ARGUMENT, "unrecognized arg kind")


# ── The allocation context ───────────────────────────────────────────────────


class Context:
    """An allocation scope. Peers and netlayers created *in* a context route
    every allocation through it. The context must outlive every handle created
    in it: release the handles first, then the context. Released on
    :meth:`close` / context exit / GC.

    :meth:`Context.with_allocator` takes two callables backing the context:

        alloc(size: int, alignment: int) -> int     # address, or 0 on failure
        free(address: int, size: int, alignment: int) -> None

    The callables own the memory they hand out; the library calls them from any
    thread that touches a handle in the context, so they must be thread-safe.
    """

    def __init__(self):
        out = ctypes.c_void_p()
        _check(_lib.pancake_context_new(ctypes.byref(out)))
        self._raw = out
        # No callbacks for the default-allocator path.
        self._callbacks: tuple = ()

    @classmethod
    def with_allocator(cls, alloc, free) -> "Context":
        """A context that routes every allocation through host callables."""
        self = cls.__new__(cls)
        self._raw = None

        def _alloc(_user_data, size, alignment):
            return alloc(size, alignment) or 0

        def _free(_user_data, ptr, size, alignment):
            free(ptr or 0, size, alignment)

        # Hold the CFUNCTYPE trampolines (and the Python callables they close
        # over) alive for as long as the context can call them.
        alloc_cb = _AllocFn(_alloc)
        free_cb = _FreeFn(_free)
        self._callbacks = (alloc_cb, free_cb, alloc, free)
        allocator = _Allocator(alloc_cb, free_cb, None)

        out = ctypes.c_void_p()
        _check(_lib.pancake_context_new_with_allocator(ctypes.byref(allocator), ctypes.byref(out)))
        self._raw = out
        return self

    def __enter__(self) -> "Context":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        # Release the context first — it frees its tables through the allocator
        # — then drop the callbacks the trampolines borrowed.
        if self._raw:
            _lib.pancake_context_release(self._raw)
            self._raw = None
        self._callbacks = ()

    def release(self) -> None:
        """Alias for :meth:`close`."""
        self.close()

    def __del__(self):
        self.close()


# ── The Peer ─────────────────────────────────────────────────────────────────


# Release callbacks handed to the library with owned frames must outlive the
# frame; the library invokes them on its own schedule. Hold them here keyed by
# id until they fire (each clears its own entry); CFUNCTYPE values are not
# hashable, so a set will not do.
_owned_frame_callbacks: dict = {}


def _version_id(version: str) -> int:
    if version == "v1.0":
        return _abi.CAPTP_VERSION_V1_0
    if version == "pre-spec":
        return _abi.CAPTP_VERSION_PRE_SPEC
    raise ValueError(f"unknown OCapN profile {version!r}")


def _codec_id(codec: str) -> int:
    if codec == "syrup":
        return _abi.CODEC_SYRUP
    if codec == "capnp":
        return _abi.CODEC_CAPNP
    raise ValueError(f"unknown OCapN codec {codec!r}")


class Peer:
    """An authenticated OCapN/CapTP peer in the negotiating state.

    Use :meth:`start_session` and drive frames until
    :meth:`session_is_open` before application traffic. Raw already-open peers
    are available only through :meth:`raw_open` for tests and low-level fixtures.
    """

    def __init__(self, version: str = "v1.0", codec: str = "syrup"):
        ptr = ctypes.c_void_p()
        if version == "v1.0" and codec == "syrup":
            _check(_lib.pancake_peer_new(ctypes.byref(ptr)))
        else:
            _check(_lib.pancake_peer_new_negotiated(_version_id(version), _codec_id(codec), ctypes.byref(ptr)))
        self._raw = ptr
        # Library-allocator peer: no backing context to keep alive.
        self._context: Optional["Context"] = None
        # This wrapper owns the peer and releases it. A node-owned peer
        # (:meth:`from_node_raw`) sets this False, the node frees it.
        self._owned = True

    @classmethod
    def raw_open(cls) -> "Peer":
        """Create an already-open peer for tests and direct-frame fixtures."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_raw_open(ctypes.byref(ptr)))
        self._raw = ptr
        self._context = None
        self._owned = True
        return self

    @classmethod
    def raw_open_in(cls, context: "Context") -> "Peer":
        """Context-backed counterpart of :meth:`raw_open`. The context must
        outlive the peer."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_raw_open_in(context._raw, ctypes.byref(ptr)))
        self._raw = ptr
        # Hold a strong reference so the context cannot be GC-collected (and its
        # allocator released) before this peer; CPython does not order
        # finalizers by allocation dependency.
        self._context = context
        self._owned = True
        return self

    @classmethod
    def from_node_raw(cls, raw: ctypes.c_void_p) -> "Peer":
        """Wrap a node-owned peer (ADR-0066) for pumping, *without owning it*. A
        :class:`Node` registers each connection with its
        :class:`PancakeNode`, which allocates the peer and frees it on
        ``remove_conn`` / ``free``; this wrapper drives that peer with the
        ordinary ``pancake_peer_*`` surface but never releases it. Binding-internal:
        a :class:`Connection` sources its peer here from ``register_conn``."""
        self = cls.__new__(cls)
        self._raw = raw
        self._context = None
        self._owned = False
        return self

    def __enter__(self) -> "Peer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        # A node-owned peer (`_owned` False) is freed by the node, not here; drop
        # the handle either way so a double call is a no-op.
        if self._raw and self._owned:
            _lib.pancake_peer_release(self._raw)
        self._raw = None

    def __del__(self):
        self.release()

    def register_export(self, export_position: int) -> None:
        _check(_lib.pancake_peer_register_export(self._raw, export_position))

    def next_export(self) -> int:
        """Allocate and register the next free export position from the
        session's one export allocator, the counter that also mints bootstrap
        and resolver exports, so a spawned position can never alias one."""
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_next_export(self._raw, ctypes.byref(out)))
        return out.value

    def register_import(self, import_position: int) -> None:
        _check(_lib.pancake_peer_register_import(self._raw, import_position))

    def next_answer(self) -> int:
        """Allocate the next outbound answer position from the session's one
        answer allocator, the counter that backs every outbound question, so a
        privately-counted answer can never alias a live one."""
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_next_answer(self._raw, ctypes.byref(out)))
        return out.value

    def start_session(
        self,
        seed: bytes,
        *,
        transport: str = "tcp",
        designator: str,
        hints_empty_false: bool = True,
    ) -> None:
        """Sign and queue ``op:start-session`` from this negotiating peer. The
        handshake speaks the profile the peer was constructed with
        (``Peer("pre-spec")`` for upstream OCapN). The 32-byte ``seed`` is the
        session key (the library refuses any other length);
        ``transport``/``designator`` form the locator the partner verifies, so
        they must be what it expects, for a Goblins partner, ``"tcp"`` with
        ``hints_empty_false`` true (Goblins emits the empty hints as the
        boolean ``#f``). Flush it, then pump until :meth:`session_is_open`."""
        if len(seed) != 32:
            raise ValueError("a session seed must be 32 bytes")
        transport_b = transport.encode()
        designator_b = designator.encode()
        _check(_lib.pancake_peer_start_session(
            self._raw,
            transport_b, len(transport_b),
            designator_b, len(designator_b),
            _HINTS_EMPTY_FALSE if hints_empty_false else _HINTS_EMPTY_MAP,
            seed, len(seed),
        ))

    def session_is_open(self) -> bool:
        """Whether the authenticated handshake has completed and the session is open for
        traffic. Pump the connection and poll this before sending application
        messages."""
        rc = _lib.pancake_peer_session_is_open(self._raw)
        if rc < 0:
            raise PancakeError(rc)
        return rc == 1

    def last_abort(self) -> Optional[AbortDetail]:
        """The typed cause of this peer's most recent local dispatch failure,
        or ``None`` when no failure has been recorded. The per-call
        :class:`PancakeError` code names the failure family; this names the
        member. Errors raised by :meth:`feed`, :meth:`feed_owned`, and
        :meth:`recv_stream` carry it already as ``err.abort``."""
        info = _LastAbort()
        rc = _lib.pancake_peer_last_abort(self._raw, ctypes.byref(info))
        if rc == _WOULD_BLOCK:
            return None
        _check(rc)

        def text(ptr, length) -> str:
            return ctypes.string_at(ptr, length).decode(errors="replace") if ptr and length else ""

        domain = {
            _abi.ABORT_DOMAIN_CODEC: "codec",
            _abi.ABORT_DOMAIN_SESSION: "session",
            _abi.ABORT_DOMAIN_FOREIGN: "foreign",
        }.get(info.domain, str(info.domain))
        return AbortDetail(
            domain=domain,
            kind=text(info.kind_name, info.kind_name_len) if info.has_kind else None,
            message=text(info.message, info.message_len),
            error_name=text(info.error_name, info.error_name_len),
        )

    def _dispatch_error(self, code: int) -> PancakeError:
        """A :class:`PancakeError` for a refused frame, carrying the typed abort
        cause. Captures the thread-local message first, before any later call
        clobbers it."""
        message = last_error()
        try:
            abort = self.last_abort()
        except PancakeError:
            abort = None
        return PancakeError(code, message, abort=abort)

    def feed(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        rc = _lib.pancake_peer_feed_borrowed(self._raw, ctypes.byref(f))
        if rc != _OK:
            raise self._dispatch_error(rc)

    def feed_owned(self, frame: bytes) -> None:
        """Transfer owned frame bytes into the inbound queue for the next
        :meth:`step` — the library owns the copy until it calls our release.

        A Python buffer owning a copy of ``frame`` is handed to the library
        with a release callback. On success the library owns it and calls the
        callback when done; on failure we reclaim it ourselves.
        """
        n = len(frame)
        buf = (ctypes.c_uint8 * n).from_buffer_copy(frame) if n else (ctypes.c_uint8 * 0)()

        # The owning buffer must outlive the descriptor: park it on the callback
        # closure so it lives exactly as long as the release callback does.
        state = {"buf": buf}

        def _release(_frame_ptr):
            # Drop the owning buffer and stop holding the callback alive.
            state.pop("buf", None)
            _owned_frame_callbacks.pop(id(release_cb), None)

        release_cb = _ManagedFrameRelease(_release)
        _owned_frame_callbacks[id(release_cb)] = release_cb

        managed = _ManagedFrame(
            ctypes.cast(buf, ctypes.c_void_p),
            n,
            _FRAME_SHAPE_BYTE,
            ctypes.cast(release_cb, ctypes.c_void_p),
            None,
        )
        rc = _lib.pancake_peer_feed_owned(self._raw, ctypes.byref(managed))
        if rc != _OK:
            # The descriptor was not adopted; reclaim the bytes ourselves and
            # drop the callback. Capture the message before it is clobbered.
            err = self._dispatch_error(rc)
            state.pop("buf", None)
            _owned_frame_callbacks.pop(id(release_cb), None)
            raise err

    def step(self) -> None:
        _check(_lib.pancake_peer_step(self._raw))

    def step_to_idle(self) -> None:
        """Advance to quiescence: encode every pending outbound message, including
        the ones a cascading settlement queues (a resolve that drains a
        projection whose own resolve fires a listener that queues a deliver), so
        one :meth:`take_outbound` sweep drains the whole batch. A single
        :meth:`step` does one unit of work; this runs them all."""
        _check(_lib.pancake_peer_step_to_idle(self._raw))

    def recv_stream(self, data: "Union[bytes, bytearray]") -> Optional[int]:
        """Frame and dispatch one whole frame out of a streamed read buffer.

        Returns the number of bytes consumed when a whole frame was framed and
        dispatched, ``None`` when ``data`` holds only a partial frame (read more
        and retry with the larger buffer), and raises :class:`PancakeError` on a
        fatal framing or dispatch error (malformed, frame too large, …).
        """
        n = len(data)
        # Copy into a C array (from_buffer_copy accepts a bytes or bytearray).
        # A borrowed `from_buffer` view is deliberately avoided: it would keep a
        # buffer export alive that blocks the caller's `del inbox[:consumed]`
        # resize (BufferError). Accepting the bytearray directly already removes
        # the redundant `bytes(inbox)` wrapper copy the drain loop used to make.
        buf = (ctypes.c_uint8 * n).from_buffer_copy(data) if n else (ctypes.c_uint8 * 0)()
        ptr = ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8))
        consumed = ctypes.c_size_t(0)
        rc = _lib.pancake_peer_recv_stream(self._raw, ptr, n, ctypes.byref(consumed))
        if rc == _OK:
            return consumed.value
        if rc == _WOULD_BLOCK:
            return None
        # The error carries the thread-local message and the typed abort cause.
        raise self._dispatch_error(rc)

    def register_bootstrap_cap(self, swissnum: bytes) -> int:
        buf = ctypes.create_string_buffer(swissnum, len(swissnum))
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_register_bootstrap_cap(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(swissnum), ctypes.byref(out)))
        return out.value

    def send_bootstrap_fetch(self, name: bytes) -> int:
        """Queue the canonical bootstrap ``fetch`` for the capability published
        behind ``name``, returning the answer position the partner's resolution
        arrives on (as a :class:`Resolve` event). Registers the bootstrap
        import and allocates the answer from the session's own counters."""
        buf = ctypes.create_string_buffer(name, len(name))
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_send_bootstrap_fetch(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(name), ctypes.byref(out)))
        return out.value

    def prepare_enliven(self, swissnum: bytes) -> _EnlivenStart:
        """Begin enlivening the sturdyref published behind ``swissnum``
        (ADR-0012): the requester half over bootstrap-fetch with the dedup
        cache. Returns the :class:`_EnlivenStart` — a ``status`` plus either the
        cached far reference (``import_position``/``kind``) or the ``answer`` to
        drive. Requires the session to have negotiated the sturdyref feature and
        be open."""
        buf = ctypes.create_string_buffer(swissnum, len(swissnum))
        out = _EnlivenStart()
        _check(_lib.pancake_peer_prepare_enliven(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(swissnum), ctypes.byref(out)))
        return out

    def record_enlivenment(self, swissnum: bytes, outcome: int, import_position: int, kind: int) -> None:
        """Settle a fresh enliven once its bootstrap-fetch resolution arrives:
        cache the fulfilled far reference (``import_position``/``kind``) under
        ``swissnum`` so a repeat short-circuits, or clear the in-flight marker
        on a break (``outcome`` is an ``ENLIVEN_OUTCOME_*`` value)."""
        buf = ctypes.create_string_buffer(swissnum, len(swissnum))
        _check(_lib.pancake_peer_record_enlivenment(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(swissnum), outcome, import_position, kind))

    def send_gc_export(self, positions: list, deltas: list) -> None:
        """Queue an ``op:gc-export`` releasing wire-delta counts on imports
        this peer holds: ``positions[i]`` is released by ``deltas[i]``. The
        lists are parallel and must be non-empty and the same length."""
        if len(positions) != len(deltas):
            raise ValueError("positions and deltas must be the same length")
        n = len(positions)
        pos_arr = (ctypes.c_uint64 * n)(*positions)
        delta_arr = (ctypes.c_uint64 * n)(*deltas)
        _check(_lib.pancake_peer_send_gc_export(self._raw, pos_arr, delta_arr, n))

    def send_get(self, receiver: Reference, field: str, answer: int) -> None:
        """Queue an ``op:get`` projection (ADR-0050): export a fresh promise at
        ``answer`` that resolves to the ``field`` member of whatever ``receiver``
        resolves to. ``receiver`` is typically a promise (a pending answer), so
        the projection pipelines ahead of that answer settling. ``answer`` must
        come from :meth:`next_answer`."""
        t = _ref_to_c(receiver)
        buf = field.encode()
        sbuf = ctypes.create_string_buffer(buf, len(buf))
        _check(_lib.pancake_peer_send_get(self._raw, ctypes.byref(t), ctypes.cast(sbuf, ctypes.c_void_p), len(buf), answer))

    def send_index(self, receiver: Reference, index: int, answer: int) -> None:
        """Queue an ``op:index`` projection (ADR-0050): like :meth:`send_get` but
        for the element at ``index`` of a List the ``receiver`` resolves to."""
        t = _ref_to_c(receiver)
        _check(_lib.pancake_peer_send_index(self._raw, ctypes.byref(t), index, answer))

    def send_untag(self, receiver: Reference, tag: str, answer: int) -> None:
        """Queue an ``op:untag`` projection (ADR-0052): export a fresh promise at
        ``answer`` that resolves to the payload of whatever ``receiver`` resolves
        to, requiring a Tagged record whose tag equals ``tag``."""
        t = _ref_to_c(receiver)
        buf = tag.encode()
        sbuf = ctypes.create_string_buffer(buf, len(buf))
        _check(_lib.pancake_peer_send_untag(self._raw, ctypes.byref(t), ctypes.cast(sbuf, ctypes.c_void_p), len(buf), answer))

    def send_deliver(self, target: Reference, args: list, answer: Optional[int] = None) -> None:
        t = _ref_to_c(target)
        keepalive: list = []
        arr_ptr, arr_len = _args_to_c(list(args), keepalive)
        _check(
            _lib.pancake_peer_send_deliver(
                self._raw, ctypes.byref(t), arr_ptr, arr_len, 1 if answer is not None else 0, answer or 0
            )
        )

    def send_resolve(self, answer: int, resolution: Resolution) -> None:
        if isinstance(resolution, Fulfill):
            keepalive: list = []
            value = _arg_to_c(resolution.value, keepalive)
            _check(
                _lib.pancake_peer_send_resolve(
                    self._raw, answer, _RESOLUTION_FULFILL, ctypes.byref(value), None, 0
                )
            )
        else:
            msg = resolution.message.encode()
            buf = ctypes.create_string_buffer(msg, len(msg))
            _check(
                _lib.pancake_peer_send_resolve(
                    self._raw, answer, _RESOLUTION_BREAK, None, ctypes.cast(buf, ctypes.c_void_p), len(msg)
                )
            )

    def take_outbound(self) -> Optional[bytes]:
        frame = _ManagedFrame()
        rc = _lib.pancake_peer_take_outbound(self._raw, ctypes.byref(frame))
        if rc == _WOULD_BLOCK:
            return None
        # Any other non-OK code (e.g. an OOM after the frame was dequeued and
        # then freed) is a real failure: surface it instead of silently dropping
        # an outbound frame and ending the drain as if the queue were empty.
        if rc != _OK:
            raise PancakeError(rc, last_error())
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def poll(self) -> Optional[Event]:
        """Drive the engine to idle and take the next event, fully projected by
        the core (``pancake_peer_next_event``): the waist owns the pump-then-poll
        rule and the typed-or-opaque routing, so this only marshals the live arm
        into a Python event. Write queued outbound (:meth:`take_outbound`) when
        it returns ``None``, before parking on a read."""
        ev = _AnyEvent()
        rc = _lib.pancake_peer_next_event(self._raw, ctypes.byref(ev))
        if rc == _WOULD_BLOCK:
            return None
        _check(rc)
        try:
            if ev.projection == _PROJECTION_DELIVER:
                d = ev.deliver
                return Deliver(
                    target=_ref_from_c(d.target),
                    args=[_arg_from_c(d.args[i]) for i in range(d.args_len)],
                    answer=d.answer if d.has_answer else None,
                )
            if ev.projection == _PROJECTION_RESOLVE:
                r = ev.resolve
                if r.resolution_kind == _RESOLUTION_FULFILL:
                    resolution: Resolution = Fulfill(_arg_from_c(r.fulfill))
                elif r.resolution_kind == _RESOLUTION_HANDOFF:
                    h = r.handoff
                    give = ctypes.string_at(h.give, h.give_len) if h.give else b""
                    locator = (
                        ctypes.string_at(h.exporter_locator, h.exporter_locator_len).decode("utf-8", errors="replace")
                        if h.exporter_locator else ""
                    )
                    recipient = ctypes.string_at(h.recipient_key, h.recipient_key_len) if h.recipient_key else b""
                    resolution = Handoff(give=give, exporter_locator=locator, recipient_key=recipient)
                else:
                    msg = ctypes.string_at(r.break_message, r.break_message_len).decode(errors="replace") if r.break_message else ""
                    resolution = Break(msg)
                return Resolve(answer=r.answer, resolution=resolution)
            # The frame arm: an event with no typed projection (or whose value
            # the typed surface cannot carry), as its original wire bytes.
            frame = ctypes.string_at(ev.frame.bytes, ev.frame.len) if ev.frame.bytes else b""
            return Other(kind=ev.kind, frame=frame)
        finally:
            # Always free the C-owned projection, even if marshalling raises on
            # a hostile payload — otherwise every bad frame leaks it.
            _lib.pancake_any_event_release(ctypes.byref(ev))


# ── Actors ───────────────────────────────────────────────────────────────────
#
# This is pancake's Goblins-shaped actor model in Python. It is where the actor
# layer meets the OCapN peer. It mirrors the Zig ``actors.vat`` and the Racket
# binding's actor section in idiomatic Python: callables for behaviors, exceptions
# for broken resolutions, and dataclasses for the unified reference and promise.
#
# An actor is a callable ``behavior(verb, args) -> value``. It returns a reply
# value, or raises to break the resolution. A :class:`VatRef` names an object the
# vat can eventual-send to, wherever it lives: a local actor in this vat, or a
# far object the bound peer holds as an import. :meth:`Vat.call` is the
# synchronous near-call and is local-only; :meth:`Vat.send` is the
# location-transparent eventual-send and routes by where the ref lives. The
# application never handles a :class:`VatRef`; it holds a :class:`Ref` (below),
# the capability the :class:`Connection` surface hands back and accepts, and the
# connection lowers it to a :class:`VatRef` when it enters the vat.


@dataclass(frozen=True)
class VatRef:
    """The vat's internal reference to an object it can eventual-send to.

    A *local* ref names an actor in this vat; :meth:`Vat.call` and
    :meth:`Vat.send` run its turns here. A *far* ref wraps a :class:`Far`
    import the bound peer holds; :meth:`Vat.send` routes to it as an
    ``op:deliver`` and :meth:`Vat.call` (near) is illegal. Binding-internal:
    the application holds a :class:`Ref`, which lowers to this.
    """

    local_id: Optional[int] = None
    far: Optional[Far] = None

    @classmethod
    def local(cls, actor_id: int) -> "VatRef":
        """A reference to a local actor by its vat id."""
        return cls(local_id=actor_id)

    @classmethod
    def to(cls, far: Far) -> "VatRef":
        """A reference to a partner-hosted object the peer holds as an import."""
        return cls(far=far)

    @property
    def is_local(self) -> bool:
        return self.local_id is not None


@dataclass(frozen=True)
class Ref:
    """An application capability: what :meth:`Connection.fetch`,
    :meth:`Connection.spawn`, and a :meth:`Connection.send` reply hand back, and
    what ``send``/``tell`` accept as a target or argument.

    It names a local actor this connection hosts (carrying the ``Near`` export it
    marshals to) or a far object imported over the wire. The vat itself works in
    :class:`VatRef`; this lowers to one via :meth:`_vat` when it crosses into the
    vat.
    """

    local_id: Optional[int] = None
    far: Optional[Far] = None
    # The wire reference this marshals to when handed to a partner as a capability
    # argument. A locally-spawned actor carries a `Near` (our export); set by the
    # :class:`Connection` layer.
    near: Optional[Near] = None

    @property
    def is_local(self) -> bool:
        return self.local_id is not None

    def _vat(self) -> VatRef:
        """Lower this capability to the vat's internal reference for a near-call
        or eventual-send. The ``near`` export is an app-marshaling detail the vat
        never reads, so it is dropped here."""
        return VatRef(local_id=self.local_id, far=self.far)

    def _wire(self) -> Reference:
        """The wire reference to marshal this capability to in a `send` argument:
        a local actor's `Near` export, else the `Far` import it names."""
        if self.near is not None:
            return self.near
        if self.far is not None:
            return self.far
        raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this ref has no wire reference to marshal")


class VowBroken(Exception):
    """Raised when an awaited vow settles broken; the message is the break reason."""


class FetchFailed(Exception):
    """Raised when a ``fetch`` settles, but not with a capability.

    This is the application-level outcome — the partner answered, and the
    answer was not a reference — distinct from a marshalling failure or a
    broken promise. ``name`` is the swiss-number the fetch asked for."""

    def __init__(self, name: str):
        super().__init__(f'fetch("{name}") did not resolve to a capability')
        self.name = name


@dataclass(frozen=True)
class Vow:
    """A handle to the eventual result of a :meth:`Vat.send`.

    A vow is awaitable: ``value = await vat.send(ref, verb, args)`` resolves with
    the value, or raises :class:`VowBroken` on a break. You can also observe it
    with :meth:`Vat.on` for the callback style. A *local* vow settles during
    :meth:`Vat.drive`; a *far* vow settles when :meth:`Vat.serve` dispatches the
    matching inbound resolve, so something must be driving the vat (e.g. an
    ``async for event in conn`` loop) for the await to complete.
    """

    local_id: Optional[int] = None
    answer: Optional[int] = None
    # The vat that issued this vow, so `await` can register for its settlement.
    # Excluded from equality/repr, two vows are the same by position, not vat.
    vat: Optional["Vat"] = field(default=None, compare=False, repr=False)

    @property
    def is_local(self) -> bool:
        return self.local_id is not None

    def __await__(self):
        future = asyncio.get_running_loop().create_future()

        def fulfilled(value: object) -> None:
            if not future.done():
                future.set_result(value)

        def broken(message: str) -> None:
            if not future.done():
                future.set_exception(VowBroken(message))

        assert self.vat is not None, "an awaitable vow must come from Vat.send"
        self.vat.on(self, on_fulfilled=fulfilled, on_broken=broken)
        return future.__await__()


class RemotePromise(asyncio.Future):
    """The handle :meth:`Connection.send` returns: the eventual result of one
    eventual-send, and -- the point of promise pipelining (ADR-0007) -- a target
    you can ``send`` to before it resolves.

    It is a real :class:`asyncio.Future`, so ``await conn.send(...)``,
    ``asyncio.gather(...)``, and ``isinstance(_, asyncio.Future)`` all work
    natively. Pass it *unawaited* as the ``target`` of a later ``send`` to
    address the object the answer will resolve to: the dependent call rides a
    ``desc:answer`` deliver and the partner queues it until the answer settles,
    so a ``create -> use`` chain costs one round trip::

        task = conn.send(root, "create", ["x"])     # not awaited
        conn.send(task, "assign", ["alice"])          # pipelined at the answer
        status = await conn.send(task, "status", [])  # settles the chain

    The send is queued when this is created, but its bytes leave the wire only
    when this -- or any send pipelined behind it -- is first awaited, so a
    pipelined batch travels together. A handle that is never awaited is a
    fire-and-forget send; prefer :meth:`Connection.tell` for that. Because the
    send is lazy, an unawaited anchor whose far answer *breaks* never starts its
    reply wait, so it sets no exception and cannot raise "exception was never
    retrieved". Like any ``asyncio.Future``, construct it within a running event
    loop (``send`` is always called from one). ``answer`` is the outbound answer
    position a far send resolves, or ``None`` for a local send (not pipelinable).
    """

    def __init__(self, answer: Optional[int], begin, project=None) -> None:
        # The future is created empty -- no flush runs here, so construction is
        # side-effect-free and the send stays lazy.
        super().__init__()
        self._answer = answer
        self._begin = begin
        # Issues a projection op (get/index/untag) at this answer and returns the
        # new RemotePromise; None for a local-send handle (no answer to project).
        self._project = project
        self._started = False

    @property
    def answer(self) -> Optional[int]:
        return self._answer

    def _project_op(self, op: str, key) -> "RemotePromise":
        if self._project is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot project a local-send promise; await it for a value")
        return self._project(op, key)

    def index(self, i: int) -> "RemotePromise":
        """Pipeline an ``op:index`` for ``i`` at this answer (ADR-0050): a new
        :class:`RemotePromise` for the List element of whatever this resolves
        to."""
        return self._project_op("index", int(i))

    def untag(self, tag: str) -> "RemotePromise":
        """Pipeline an ``op:untag`` for ``tag`` at this answer (ADR-0052): a new
        :class:`RemotePromise` for the payload of whatever this resolves to,
        which must be a Tagged record whose tag equals ``tag``."""
        return self._project_op("untag", tag)

    def __await__(self):
        # First observation schedules the send's flush + reply wait, exactly
        # once, and chains its outcome onto this future. An unawaited handle
        # never starts ``begin``, so its answer breaking never settles us.
        if not self._started:
            self._started = True
            task = asyncio.ensure_future(self._begin())
            task.add_done_callback(self._chain)
        return super().__await__()

    __iter__ = __await__  # `yield from` compatibility, mirroring asyncio.Future

    def _chain(self, task: "asyncio.Future") -> None:
        # Copy the begin task's outcome onto this future. Guard the states a
        # future can already be in so a late settlement never raises.
        if self.cancelled():
            return
        if task.cancelled():
            self.cancel()
            return
        exc = task.exception()
        if exc is not None:
            self.set_exception(exc)
        else:
            self.set_result(task.result())


@dataclass
class _Listener:
    """A one-shot promise listener: at most one of ``on_fulfilled`` /
    ``on_broken`` fires when the vow settles."""

    on_fulfilled: Optional[object] = None
    on_broken: Optional[object] = None


class Forward:
    """A behavior's tail-forward of its answer to another reference — the binding's
    `Turn.forward` (ADR-0064). Return ``Forward(target, verb, args)`` from a
    behavior and the vat resolves the caller's answer from ``target <- verb(args)``
    instead of from a value: a local target near-calls (composing if it forwards
    again), a far target eventual-sends and defers until the reply settles. It is
    the whole mechanism behind a caretaker/attenuator — each is an ordinary actor
    whose behavior forwards (or raises to refuse), so the proxy is a plain `Ref`
    you delegate and may call locally or over the wire alike."""

    __slots__ = ("target", "verb", "args")

    def __init__(self, target: "Ref", verb: str, args=None):
        self.target = target
        self.verb = verb
        self.args = list(args or [])


class Vat:
    """A turn loop over a heap of actors, local and remote alike.

    A vat owns local actors (callables ``behavior(verb, args) -> value``), a
    queue of pending local eventual-sends, listeners for local and far vows, and
    an export map when it is bound to a peer. That export map lets inbound
    deliveries run published actors. You drive the vat; it owns no I/O and no
    scheduler thread.

    A pure-local vat (``Vat()``) sends and drives over local actors only. A vat
    bound to a peer (``Vat(peer)``) also routes far sends out as ``op:deliver``
    and serves inbound peer events through :meth:`serve`.
    """

    def __init__(self, peer: Optional[Peer] = None):
        self._peer = peer
        self._actors: dict = {}
        self._exports: dict = {}  # export id -> local actor id
        self._listeners: dict = {}  # local vow id -> _Listener
        self._far_listeners: dict = {}  # far answer -> _Listener
        # A far answer can settle before its handle is ever awaited: a sibling op
        # on the same connection (a pipelined projection's flush, say) pumps the
        # inbound loop, so the source answer's resolve can land before anyone
        # awaits it. Stash it here so a late `on` settles from it, not hangs.
        self._far_resolutions: dict = {}  # far answer -> Resolution
        self._queue: list = []  # pending local sends: (actor_id, verb, args, vow_id)
        self._next_actor = 1
        self._next_vow = 1
        # An optional hook the Connection installs to originate a three-party
        # handoff: when a published actor's reply is a capability that lives on a
        # *different* connection, the ordinary resolve would mis-send a
        # cross-connection reference. The interceptor `(answer, value) -> bool`
        # claims such a reply (returning True) and resolves it itself as a signed
        # give; a False return falls through to the ordinary resolve.
        self._resolve_interceptor = None

    def set_resolve_interceptor(self, interceptor) -> None:
        """Install the foreign-home resolve interceptor (binding-internal; the
        :class:`Connection` sets it). ``interceptor(answer, value)`` returns True
        to claim a deliver's reply for handoff origination, False to let the vat
        resolve it normally."""
        self._resolve_interceptor = interceptor

    @property
    def peer(self) -> Optional[Peer]:
        """The bound peer, to feed/step/take_outbound around :meth:`serve`."""
        return self._peer

    def spawn(self, behavior) -> VatRef:
        """Spawn a local actor with ``behavior``, returning a local :class:`VatRef`."""
        actor_id = self._next_actor
        self._next_actor += 1
        self._actors[actor_id] = behavior
        return VatRef.local(actor_id)

    def call(self, ref: VatRef, verb: str, args: Optional[list] = None):
        """The synchronous near-call (``$``): run ``ref``'s handler now and
        return its value. Legal only for a *local* ref, a far ref raises, since
        only :meth:`send` reaches one. Raises if no such actor exists, or
        propagates whatever the behavior itself raises."""
        if not ref.is_local:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot near-call a far ref; use send")
        behavior = self._actors.get(ref.local_id)
        if behavior is None:
            raise KeyError(f"no such actor: {ref.local_id}")
        return behavior(verb, list(args or []))

    def send(self, ref: VatRef, verb: str, args: Optional[list] = None) -> Vow:
        """The eventual send (``<-``): location-transparent. A local target
        queues a turn for :meth:`drive` and returns a local :class:`Vow`. A far
        target sends an ``op:deliver`` over the bound peer — a leading
        :class:`Symbol` carries the verb, matching Goblins's
        ``($ obj 'method …)`` — and returns a far vow carrying the answer."""
        rest = list(args or [])
        if ref.is_local:
            vow_id = self._next_vow
            self._next_vow += 1
            self._queue.append((ref.local_id, verb, rest, vow_id))
            return Vow(local_id=vow_id, vat=self)
        if self._peer is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this vat has no peer; far sends need Vat(peer)")
        answer = self._peer.next_answer()
        payload = [Symbol(verb), *rest] if verb else rest
        self._peer.send_deliver(ref.far, payload, answer=answer)
        return Vow(answer=answer, vat=self)

    def send_to_answer(self, answer_pos: int, verb: str, args: Optional[list] = None) -> Vow:
        """Pipeline an eventual send (ADR-0007): deliver ``verb(args)`` to the
        object the still-pending ``answer_pos`` will resolve to -- the call rides
        a ``desc:answer`` target -- and return a far vow on a fresh answer. The
        partner queues the call until that answer settles, so a dependent call
        need not wait for the one it depends on."""
        if self._peer is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this vat has no peer; pipelined sends need Vat(peer)")
        rest = list(args or [])
        answer = self._peer.next_answer()
        payload = [Symbol(verb), *rest] if verb else rest
        self._peer.send_deliver(Promise(answer_pos), payload, answer=answer)
        return Vow(answer=answer, vat=self)

    def on(self, vow: Vow, on_fulfilled=None, on_broken=None) -> None:
        """Register a one-shot listener for ``vow``. A local vow fires during
        :meth:`drive`; a far vow fires when :meth:`serve` dispatches the
        partner's resolution. ``on_fulfilled(value)`` runs on a fulfill,
        ``on_broken(message)`` on a break."""
        listener = _Listener(on_fulfilled, on_broken)
        if vow.is_local:
            self._listeners[vow.local_id] = listener
        else:
            # If the answer already settled (awaited late, after a sibling op
            # pumped the loop), fire from the stash now rather than waiting for a
            # resolve that has already come and gone.
            settled = self._far_resolutions.pop(vow.answer, None)
            if settled is not None:
                self._fire(listener, settled)
                return
            self._far_listeners[vow.answer] = listener

    def break_far_vows(self, message: str) -> None:
        """Break every outstanding far vow with ``message``, firing each
        listener's ``on_broken``. A far vow settles only when the partner's
        resolution arrives over the wire, so once the connection is gone those
        replies can never come. The connection driver calls this on disconnect,
        so an awaiting :meth:`send` raises :class:`VowBroken` instead of hanging
        forever. Local vows are untouched: they settle synchronously in
        :meth:`drive` and never wait on the wire."""
        # Snapshot then clear before firing: a listener may register another far
        # vow, and mutating the dict mid-iteration would lose it.
        pending = list(self._far_listeners.values())
        self._far_listeners.clear()
        for listener in pending:
            if listener.on_broken is not None:
                listener.on_broken(message)

    def drive(self) -> None:
        """Run queued local eventual-sends to quiescence, settling each vow with
        the handler's value (a break carrying the message on a raised exception)
        and firing its listener. Turns queued by a turn run in the same drive
        (FIFO)."""
        index = 0
        while index < len(self._queue):
            actor_id, verb, args, vow_id = self._queue[index]
            index += 1
            try:
                value = self.call(VatRef.local(actor_id), verb, args)
            except Exception as error:  # noqa: BLE001, a raise breaks the resolution
                self._settle_local(vow_id, Break(str(error)))
                continue
            self._resolve(
                value,
                lambda v, vid=vow_id: self._settle_local(vid, Fulfill(v)),
                lambda m, vid=vow_id: self._settle_local(vid, Break(m)),
            )
        self._queue.clear()

    def _resolve(self, value, on_fulfilled, on_broken) -> None:
        """Settle an answer from a behavior's result. A plain value fulfills it; a
        :class:`Forward` tail-resolves it from the forwarded send — a local target
        near-calls (and recurses, so caretaker-over-attenuator composes), a far
        target eventual-sends and defers the settle onto the reply (ADR-0064). This
        is the one place the vat interprets a forward, shared by the inbound-deliver
        and local-drive paths so a proxy behaves identically whoever calls it."""
        if not isinstance(value, Forward):
            on_fulfilled(value)
            return
        target = value.target._vat()
        if target.is_local:
            try:
                inner = self.call(target, value.verb, value.args)
            except Exception as error:  # noqa: BLE001 — a refusal breaks the answer
                on_broken(str(error))
                return
            self._resolve(inner, on_fulfilled, on_broken)
        else:
            vow = self.send(target, value.verb, value.args)
            self.on(vow, on_fulfilled=on_fulfilled, on_broken=on_broken)

    def publish(self, export_position: int, behavior) -> VatRef:
        """Spawn ``behavior`` and publish it at ``export_position`` so a partner's
        deliveries to that export run the actor (dispatched by :meth:`serve`).
        Requires a bound peer. Returns the new local :class:`VatRef`."""
        if self._peer is None:
            raise PancakeError(_ERR_UNSUPPORTED_VALUE, "this vat has no peer; publish needs Vat(peer)")
        ref = self.spawn(behavior)
        self._peer.register_export(export_position)
        self._exports[export_position] = ref.local_id
        return ref

    def serve(self, event: Event) -> bool:
        """Dispatch one inbound peer event. A deliver to a published export runs
        its actor (a leading :class:`Symbol` is the verb) and resolves the
        answer with the reply (a break if the actor raised). A resolve for a
        pending far vow fires its listener. Returns whether the event belonged
        to this vat, ``False`` means the caller handles it."""
        if isinstance(event, Deliver):
            return self._serve_deliver(event)
        if isinstance(event, Resolve):
            return self._serve_resolve(event)
        return False

    def _serve_deliver(self, event: Deliver) -> bool:
        if not isinstance(event.target, Near):
            return False
        actor_id = self._exports.get(event.target.id)
        if actor_id is None:
            return False

        # A leading symbol is the method verb; the rest are its arguments.
        args = event.args
        if args and isinstance(args[0], Symbol):
            verb, rest = str(args[0]), args[1:]
        else:
            verb, rest = "", args

        try:
            value = self.call(VatRef.local(actor_id), verb, rest)
        except Exception as error:  # noqa: BLE001, broken resolution carries the message
            if event.answer is not None and self._peer is not None:
                self._peer.send_resolve(event.answer, Break(str(error)))
            return True

        answer = event.answer
        peer = self._peer

        def on_fulfilled(reply) -> None:
            if answer is None or peer is None:
                return
            # A reply that is a capability living on another connection trips the
            # gifter half: the interceptor deposits it with its exporter and
            # answers with a signed give instead of an ordinary cross-connection
            # resolve (ADR-0009).
            if self._resolve_interceptor is not None and self._resolve_interceptor(answer, reply):
                return
            peer.send_resolve(answer, Fulfill(reply))

        def on_broken(message) -> None:
            if answer is not None and peer is not None:
                peer.send_resolve(answer, Break(message))

        # A plain value resolves now; a `Forward` (a caretaker/attenuator proxy)
        # tail-resolves the answer from the forwarded send — deferring it for a
        # far target — through the one shared `_resolve` path (ADR-0064).
        self._resolve(value, on_fulfilled, on_broken)
        return True

    def _serve_resolve(self, event: Resolve) -> bool:
        resolution = event.resolution
        if isinstance(resolution, Handoff):
            # A handoff give reaches the vat only when no dial-capable layer above
            # it intercepted it first (the :class:`Connection` redeems
            # transparently). The vat cannot dial, so break the vow rather than
            # hang it forever.
            resolution = Break("handoff give arrived at a vat with no redeemer")
        listener = self._far_listeners.pop(event.answer, None)
        if listener is None:
            # No one is awaiting this answer yet. It may be awaited later (a source
            # handle awaited after its projection pumped the loop), so stash the
            # resolution for a late `on`. Still ours to claim.
            self._far_resolutions[event.answer] = resolution
            return True
        self._fire(listener, resolution)
        return True

    def _settle_local(self, vow_id: int, resolution: Resolution) -> None:
        listener = self._listeners.pop(vow_id, None)
        if listener is not None:
            self._fire(listener, resolution)

    @staticmethod
    def _fire(listener: _Listener, resolution: Resolution) -> None:
        if isinstance(resolution, Fulfill):
            if listener.on_fulfilled is not None:
                listener.on_fulfilled(resolution.value)
        else:
            if listener.on_broken is not None:
                listener.on_broken(resolution.message)


# ── Async driver ──────────────────────────────────────────────────────────────


class _KeyedLocator(NamedTuple):
    """The locator a keyed ``op:start-session`` signs for a transport: the
    transport name, its designator, and whether empty hints encode as ``#f``."""

    transport: str
    designator: str
    hints_empty_false: bool = True


class _FramePump:
    """How one transport moves a frame, a complete, codec-self-delimited CapTP
    message, the same unit :meth:`Peer.take_outbound` yields and
    :meth:`Peer.feed`/:meth:`Peer.recv_stream` consume. A transport differs only
    in how it moves that unit, never in the pump that drives the peer over it, so
    :class:`AsyncConnection` holds a pump and is otherwise transport-blind."""

    def locator(self) -> _KeyedLocator:
        raise NotImplementedError

    def dispatch_buffered(self, peer: Peer) -> bool:
        """Frame and dispatch one already-buffered inbound frame without
        blocking; ``True`` when one was dispatched (the caller loops). A
        one-frame-per-receive transport buffers nothing and returns ``False``."""
        raise NotImplementedError

    async def receive(self, peer: Peer) -> bool:
        """Block for more inbound and dispatch it; ``False`` on a clean EOF."""
        raise NotImplementedError

    async def write_frame(self, frame: bytes) -> None:
        raise NotImplementedError

    def shutdown(self) -> bool:
        """Unblock a transport read parked on a worker thread so the inbound loop
        can finish before the transport is freed, without freeing it here. Return
        ``True`` if the read was unblocked (the caller awaits the loop to drain),
        ``False`` if the transport has no parked-thread read to release (the
        caller cancels the loop task instead). Default: nothing to unblock."""
        return False

    async def close(self) -> None:
        raise NotImplementedError


class _TcpPump(_FramePump):
    """The TCP pump: an asyncio stream pair plus the inbound byte buffer the peer
    frames. The keyed locator signs the socket's own ``host:port``, a true ``tcp``
    locator a Goblins partner accepts."""

    _READ_CHUNK = 65536

    def __init__(self, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter"):
        self._reader = reader
        self._writer = writer
        self._inbox = bytearray()

    def locator(self) -> _KeyedLocator:
        host, port, *_ = self._writer.get_extra_info("sockname")
        return _KeyedLocator("tcp", f"{host}:{port}")

    def dispatch_buffered(self, peer: Peer) -> bool:
        if not self._inbox:
            return False
        consumed = peer.recv_stream(self._inbox)
        if consumed is None:
            return False
        del self._inbox[:consumed]
        return True

    async def receive(self, peer: Peer) -> bool:
        chunk = await self._reader.read(self._READ_CHUNK)
        if chunk == b"":
            return False  # clean EOF
        self._inbox.extend(chunk)
        return True

    async def write_frame(self, frame: bytes) -> None:
        self._writer.write(frame)
        await self._writer.drain()

    async def close(self) -> None:
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (OSError, asyncio.CancelledError):
            pass


class AsyncConnection:
    """An OCapN/CapTP peer driven asynchronously over a transport pump.

    The sync :class:`Peer` is sans-io, it never blocks and never owns a socket.
    This owns one peer and one :class:`_FramePump` and *drives* the peer over it:
    source whole frames (or raw bytes the peer frames), let the peer dispatch
    them, write the peer's outbound frames back, and surface events. The pump is
    the only thing that differs between transports (TCP today, iroh through the
    sidecar); the drive loop is identical.

    The peer is a single-owner state machine: one ``AsyncConnection`` owns one
    peer and must be driven from a single task. Use as an ``async with`` context
    manager, or call :meth:`aclose`. This is the pump layer :class:`Connection`
    builds on; an application usually holds a :class:`Connection`.
    """

    def __init__(self, peer: Peer, pump: _FramePump):
        self._peer = peer
        self._pump = pump
        self._vat: Optional[Vat] = None

    @classmethod
    async def connect(cls, host: str, port: int) -> "AsyncConnection":
        """Connect to ``host:port`` and complete the keyed OCapN handshake."""
        reader, writer = await asyncio.open_connection(host, port)
        ac = cls(Peer(), _TcpPump(reader, writer))
        await _open_keyed_session(ac)
        return ac

    @classmethod
    def from_stream(cls, peer: Peer, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter") -> "AsyncConnection":
        """Wrap an already-connected stream pair and a peer you have configured
        (registered exports/imports, bootstrap caps, …)."""
        return cls(peer, _TcpPump(reader, writer))

    @classmethod
    def from_pump(cls, peer: Peer, pump: _FramePump) -> "AsyncConnection":
        """Wrap a peer and an already-built frame pump, the transport-neutral
        constructor the iroh path uses."""
        return cls(peer, pump)

    @property
    def locator(self) -> _KeyedLocator:
        """The locator this connection's transport signs in its start-session."""
        return self._pump.locator()

    @property
    def peer(self) -> Peer:
        """The owned peer, e.g. to register exports/imports before driving."""
        return self._peer

    def vat(self) -> "Vat":
        """A :class:`Vat` bound to this connection's peer, created once and
        cached. This is how you drive actors over the wire: ``publish`` an actor
        to host it, ``send`` to a far :class:`Ref` to call a remote object, and
        hand each event from :meth:`next_event` to :meth:`Vat.serve`. The vat
        enqueues on the peer; :meth:`next_event` and :meth:`flush` move bytes."""
        if self._vat is None:
            self._vat = Vat(self._peer)
        return self._vat

    async def flush(self) -> None:
        """Flush whatever is already queued on the peer's outbound to the wire.

        A :meth:`Vat.send` only enqueues; the bytes leave when something pumps
        the peer. :meth:`next_event` pumps at the top of its loop, so a reply
        queued while serving an event leaves on the next turn. But work another
        task queues onto this peer — a server pushing a broadcast to a subscriber
        whose own task is parked reading — would sit unsent until that task woke.
        Call :meth:`flush` right after such a cross-task send to put the bytes on
        the wire now."""
        await self._pump_outbound()

    async def send_deliver(self, target: Reference, args: list, answer: Optional[int] = None) -> None:
        """Queue a call to ``target`` and flush it to the wire. ``answer``
        requests a reply."""
        self._peer.send_deliver(target, args, answer)
        await self._pump_outbound()

    async def send_resolve(self, answer: int, resolution: Resolution) -> None:
        """Queue a reply settling ``answer`` and flush it to the wire."""
        self._peer.send_resolve(answer, resolution)
        await self._pump_outbound()

    def __aiter__(self):
        """The connection as a native event stream: ``async for event in conn:``.
        Yields each event the peer surfaces and ends on a clean disconnect, so the
        idiomatic receive loop is just an ``async for``. (Same as looping on
        :meth:`next_event` until it returns ``None``.)"""
        return self._events()

    async def _events(self):
        event = await self.next_event()
        while event is not None:
            yield event
            event = await self.next_event()

    async def next_event(self) -> Optional[Event]:
        """Await the next application event, driving the transport as needed.
        Returns ``None`` on a clean end of stream."""
        while True:
            # The poll drives the engine to idle itself (a settlement cascade —
            # resolve, drained projection, fired listener, queued deliver —
            # surfaces in full), so a returned None means one thing: nothing to
            # do until bytes move.
            event = self._peer.poll()
            if event is not None:
                return event
            # Write what the drive queued, dispatch every whole frame already
            # buffered, and only then block on the wire.
            await self._pump_outbound()
            if self._pump.dispatch_buffered(self._peer):
                continue
            if not await self._pump.receive(self._peer):
                return None  # clean EOF

    async def _drive_until_session_open(self) -> None:
        """Pump handshake frames without consuming application events."""
        while not self._peer.session_is_open():
            await self._pump_outbound()
            dispatched = False
            while self._pump.dispatch_buffered(self._peer):
                dispatched = True
                if self._peer.session_is_open():
                    return
            if dispatched:
                continue
            if not await self._pump.receive(self._peer):
                raise PancakeError(_ERR_CLOSED, "connection closed during the OCapN handshake")

    async def _pump_outbound(self) -> None:
        """Encode every pending outbound message and write the queued frames.
        Stepping to idle (not once) is what makes a pipelined batch leave
        whole; a single step would strand a cascade's tail in the queue."""
        self._peer.step_to_idle()
        while (frame := self._peer.take_outbound()) is not None:
            await self._pump.write_frame(frame)

    def shutdown(self) -> bool:
        """Unblock a transport read parked on a worker thread (see
        :meth:`_FramePump.shutdown`) without freeing the transport, the unblock
        half of a teardown that drains the inbound loop before :meth:`aclose`."""
        return self._pump.shutdown()

    async def aclose(self) -> None:
        """Close the transport and release the owned peer."""
        await self._pump.close()
        self._peer.release()

    async def __aenter__(self) -> "AsyncConnection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()


# ── Connection: the application surface ──────────────────────────────────────
#
# This is what an application holds. It composes a peer, a vat, and the asyncio
# I/O driver into one object, so a consumer never stitches those three together
# by hand. The verbs — ``connect``/``listen``, ``fetch``/``publish``, ``spawn``,
# ``send``, ``serve``, ``close`` — are the whole common surface. The raw
# :class:`Peer`, :class:`Vat`, and :class:`AsyncConnection` remain for power
# users (reach ``conn.peer``), but no application needs them.

async def _open_keyed_session(ac: "AsyncConnection", seed: Optional[bytes] = None) -> None:
    """Complete the keyed ``op:start-session`` handshake over a negotiating peer:
    sign the transport's locator with a session key, flush it, and pump until the
    partner's start-session opens the session. Entropy is generated here, at the
    I/O boundary, never in the sans-io core. A handoff recipient passes its
    node's retained identity ``seed`` so the exporter recognizes it as the
    party the give names; an ordinary dial gets a fresh per-connection key. The
    locator comes from the transport pump — the socket's real local address for
    ``tcp`` (a true locator a Goblins partner accepts), the local endpoint id for
    ``iroh`` — so the signed locator always matches what the partner expects."""
    if seed is None:
        seed = secrets.token_bytes(32)
    if len(seed) != 32:
        raise ValueError("a session seed must be 32 bytes")
    loc = ac.locator
    ac.peer.start_session(
        seed,
        transport=loc.transport,
        designator=loc.designator,
        hints_empty_false=loc.hints_empty_false,
    )
    await ac.flush()
    await ac._drive_until_session_open()


def encode_peer_locator(transport: str, designator: str, direct_addresses: str = "") -> bytes:
    """Build the verbatim exporter location-record bytes a gifter embeds in a give
    when the exporter is reachable only by a dial hint (ADR-0009), the
    construct-it-yourself counterpart of the partner's signed session record, for
    an exporter whose own record carries no hint. ``transport``/``designator`` name
    the exporter; a non-empty ``direct_addresses`` (comma-separated socket
    addresses) adds a ``direct-addresses`` hint so a cross-process recipient dials
    it directly with no discovery service (an iroh exporter reachable only by
    address). The result feeds :meth:`Connection.set_exporter_locator`. An empty
    ``direct_addresses`` yields a hint-less location identical to the exporter's
    own signed record, so a TCP or discovery-reachable exporter needs no
    override."""
    out_loc = ctypes.c_void_p()
    out_len = ctypes.c_size_t()
    t_b = ctypes.create_string_buffer(transport.encode(), len(transport.encode()))
    d_b = ctypes.create_string_buffer(designator.encode(), len(designator.encode()))
    a_b = ctypes.create_string_buffer(direct_addresses.encode(), len(direct_addresses.encode()))
    _check(_lib.pancake_encode_peer_locator(
        ctypes.cast(t_b, ctypes.c_void_p), len(transport.encode()),
        ctypes.cast(d_b, ctypes.c_void_p), len(designator.encode()),
        ctypes.cast(a_b, ctypes.c_void_p), len(direct_addresses.encode()),
        ctypes.byref(out_loc), ctypes.byref(out_len),
    ))
    try:
        return ctypes.string_at(out_loc, out_len.value)
    finally:
        _lib.pancake_peer_locator_bytes_release(out_loc, out_len.value)


# A redeemed-handoff token is a far id from a reserved high range, disjoint from
# any wire import, so it can never alias one (PANCAKE_REDEEMED_TOKEN_BASE).
REDEEMED_TOKEN_BASE = _abi.REDEEMED_TOKEN_BASE


class _NodeRaw:
    """Thin ctypes marshalling over the `PancakeNode` (ADR-0066), the
    cross-connection handoff router in the Zig core. The semantics are the node's
    (`src/c_abi/ocapn/node.zig`); :class:`Node` documents how the binding uses
    them and keeps this alive while any connection borrows a node-owned peer."""

    def __init__(self, seed: bytes):
        out = ctypes.c_void_p()
        buf = (ctypes.c_uint8 * len(seed)).from_buffer_copy(seed)
        _check(_lib.pancake_node_new(ctypes.cast(buf, ctypes.c_void_p), len(seed), ctypes.byref(out)))
        self._raw = out

    @property
    def raw(self) -> ctypes.c_void_p:
        return self._raw

    def register_conn(self) -> "tuple[int, Peer]":
        # The peer is node-owned (do not free it, remove_conn / free does).
        conn_id = ctypes.c_uint64()
        peer_ptr = ctypes.c_void_p()
        _check(_lib.pancake_node_register_conn(self._raw, ctypes.byref(conn_id), ctypes.byref(peer_ptr)))
        return conn_id.value, Peer.from_node_raw(peer_ptr)

    def remove_conn(self, conn_id: int) -> None:
        if self._raw:
            _check(_lib.pancake_node_remove_conn(self._raw, conn_id))

    def route(self, default_conn: int, far_id: int) -> "Optional[tuple[int, int]]":
        out_conn = ctypes.c_uint64()
        out_far = ctypes.c_uint64()
        routed = ctypes.c_uint32()
        _check(_lib.pancake_node_route(
            self._raw, default_conn, far_id,
            ctypes.byref(out_conn), ctypes.byref(out_far), ctypes.byref(routed),
        ))
        if routed.value == 0:
            return None
        return out_conn.value, out_far.value

    def record_foreign_home(self, far_id: int, home: int) -> None:
        _check(_lib.pancake_node_record_foreign_home(self._raw, far_id, home))

    def arg_is_foreign(self, default_conn: int, far_id: int) -> bool:
        foreign = ctypes.c_uint32()
        _check(_lib.pancake_node_arg_is_foreign(self._raw, default_conn, far_id, ctypes.byref(foreign)))
        return bool(foreign.value)

    def accept_give(self, recipient_conn: int, answer: int, give: bytes, exporter_locator: str) -> None:
        gbuf = (ctypes.c_uint8 * len(give)).from_buffer_copy(give)
        loc = exporter_locator.encode("utf-8")
        lbuf = (ctypes.c_uint8 * len(loc)).from_buffer_copy(loc) if loc else None
        _check(_lib.pancake_node_accept_give(
            self._raw, recipient_conn, answer,
            ctypes.cast(gbuf, ctypes.c_void_p), len(give),
            ctypes.cast(lbuf, ctypes.c_void_p) if lbuf is not None else None, len(loc),
        ))

    def exporter_dialed(self, pending: int, exporter_conn: int) -> None:
        _check(_lib.pancake_node_exporter_dialed(self._raw, pending, exporter_conn))

    def dial_failed(self, pending: int, reason: str) -> None:
        msg = reason.encode("utf-8")
        buf = (ctypes.c_uint8 * len(msg)).from_buffer_copy(msg) if msg else None
        _check(_lib.pancake_node_dial_failed(
            self._raw, pending,
            ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None, len(msg),
        ))

    def claim_resolve(self, conn_id: int, answer: int, outcome: int, far_id: int, reason: str) -> bool:
        msg = reason.encode("utf-8")
        buf = (ctypes.c_uint8 * len(msg)).from_buffer_copy(msg) if msg else None
        claimed = ctypes.c_uint32()
        _check(_lib.pancake_node_claim_resolve(
            self._raw, conn_id, answer, outcome, far_id,
            ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None, len(msg),
            ctypes.byref(claimed),
        ))
        return bool(claimed.value)

    def intercept_fulfilled_ref(self, conn_id: int, answer: int, far_id: int) -> bool:
        claimed = ctypes.c_uint32()
        _check(_lib.pancake_node_intercept_fulfilled_ref(self._raw, conn_id, answer, far_id, ctypes.byref(claimed)))
        return bool(claimed.value)

    def provide_gift_id(self, ticket: int, gift_id: bytes) -> None:
        buf = (ctypes.c_uint8 * len(gift_id)).from_buffer_copy(gift_id)
        _check(_lib.pancake_node_provide_gift_id(self._raw, ticket, ctypes.cast(buf, ctypes.c_void_p), len(gift_id)))

    def set_exporter_location(self, conn_id: int, location: bytes) -> None:
        buf = (ctypes.c_uint8 * len(location)).from_buffer_copy(location) if location else None
        _check(_lib.pancake_node_set_exporter_location(
            self._raw, conn_id,
            ctypes.cast(buf, ctypes.c_void_p) if buf is not None else None, len(location),
        ))

    def next_action(self) -> "Optional[_PoppedAction]":
        action = _NodeAction()
        rc = _lib.pancake_node_next_action(self._raw, ctypes.byref(action))
        if rc == _WOULD_BLOCK:
            return None
        _check(rc)
        # Copy the borrowed views out before the next node call frees them. The
        # locator originates in a partner-authored give, so decode leniently
        # rather than let hostile bytes raise mid-drain.
        locator = ctypes.string_at(action.locator, action.locator_len).decode("utf-8", errors="replace") if action.locator else ""
        reason = ctypes.string_at(action.reason, action.reason_len).decode(errors="replace") if action.reason else ""
        return _PoppedAction(action.kind, action.pending, locator, action.conn_id, action.answer, action.token, reason)

    def free(self) -> None:
        """Release the node, every registered peer, the routing tables, and the
        shared gift registry. Idempotent."""
        if self._raw:
            _lib.pancake_node_free(self._raw)
            self._raw = ctypes.c_void_p()

    def __del__(self):
        self.free()


class _PoppedAction(NamedTuple):
    """One serve-step action popped off the node, its borrowed views already
    copied into Python values."""

    kind: int
    pending: int
    locator: str
    conn_id: int
    answer: int
    token: int
    reason: str


class Node:
    """The CapTP node — pancake's analogue of Goblins' ``mycapn``,
    kept deliberately distinct from the per-partner netlayer
    (:class:`AsyncConnection`) and the actor layer (:class:`Vat`). The
    cross-connection handoff machinery lives in the Zig core (``engine.Node``,
    ADR-0066/ADR-0067): the retained identity, the shared gift registry, one
    node-owned peer per connection, the redeemed-token / foreign-home routing
    tables, and the whole redeem serve step — the exporter cache, the pending
    dials and withdraws, and every decision between them. This is the thin
    host-idiom residue over it: the ``conn_id``→:class:`Connection` map, the
    action executor that performs the I/O the serve step asks for (dial, flush,
    settle, entropy), the node-giftable factories, and the iroh redeem
    posture."""

    def __init__(self, seed: Optional[bytes] = None):
        self.seed = seed if seed is not None else secrets.token_bytes(32)
        if len(self.seed) != 32:
            raise ValueError("a session seed must be 32 bytes")
        # The sans-io node in the core. Held for the node's whole life; every
        # `Connection` holds a strong reference to this `Node`, so the node
        # (and the per-connection peers it owns) outlives every borrower and is
        # freed only when the last connection is gone.
        self._node = _NodeRaw(self.seed)
        # Every live connection by `conn_id`, so a serve-step action names a
        # `Connection` and a node-giftable published once appears on all of
        # them — including connections accepted later.
        self._connections: "dict[int, Connection]" = {}
        # Whether the action executor is running; feeds kick it exactly once.
        self._draining = False
        # The running drain, retained because the event loop holds tasks only
        # weakly: an unreferenced drain could be garbage-collected mid-flight.
        self._drain_task: "Optional[asyncio.Future]" = None
        # Node-giftable objects by swiss name: capabilities this node exports under
        # one identity on *every* connection. A handoff recipient withdraws a gift
        # on a connection it dialed itself, separate from the gifter's deposit
        # connection; the exporter can only honor it if the gifted object is
        # published on the withdrawing connection too.
        self._giftable: "dict[str, Behavior]" = {}
        # The iroh reachability posture this node uses to redeem a *hint-less*
        # handoff give — one whose exporter location names the exporter by node id
        # alone, so the recipient must resolve it by id. Defaults to Discovery, the
        # maximal-reach choice; a relay-policy deployment lowers it to
        # DiscoveryNoRelay. A hinted give always dials Direct and ignores it.
        # Stored as the numeric Reachability value so the core stays free of the
        # optional iroh module.
        self._redeem_reachability = 1  # Reachability.DISCOVERY

    @property
    def redeem_reachability(self) -> int:
        """The iroh reachability posture this node uses to redeem a *hint-less*
        handoff give (the exporter named by node id alone, with no direct-address
        hints). Defaults to ``Reachability.DISCOVERY`` (n0 relays + DNS/pkarr); set
        it to ``Reachability.DISCOVERY_NO_RELAY`` to honor a no-relay deployment
        policy. A hinted give always dials ``Reachability.DIRECT`` and ignores it.
        Assign a :class:`pancake.iroh.Reachability` (or its int)."""
        return self._redeem_reachability

    @redeem_reachability.setter
    def redeem_reachability(self, reachability) -> None:
        self._redeem_reachability = int(reachability)

    def register_conn(self) -> "tuple[int, Peer]":
        """Register a fresh connection with the node, returning its ``conn_id`` and
        the node-owned peer to drive. Binding-internal: a :class:`Connection`
        sources its peer here before its handshake."""
        return self._node.register_conn()

    def remove_conn(self, conn_id: int) -> None:
        """Free a connection's node-owned peer once its loop has stopped pumping,
        then kick the action drain: the core fails the removed connection's
        stranded withdraws closed and evicts its exporter-cache rows, and the
        resulting settle actions need the executor to deliver them.
        Binding-internal: a :class:`Connection` calls it during teardown."""
        self._node.remove_conn(conn_id)
        self._kick_actions()

    def publish_giftable(self, name: str, behavior: "Behavior") -> None:
        """Publish ``behavior`` under ``name`` on every connection of this node —
        those open now and any accepted later — so a recipient can withdraw a gift
        naming it on a connection it dialed itself (the exporter half of a
        three-party handoff, ADR-0009)."""
        self._giftable[name] = behavior
        for conn in self._connections.values():
            conn.publish(name, behavior)

    def register(self, conn: "Connection") -> None:
        """Track a connection by its ``conn_id`` and publish every node-giftable on
        it. Binding-internal: the :class:`Connection` constructor calls it."""
        self._connections[conn._conn_id] = conn
        for name, behavior in self._giftable.items():
            conn.publish(name, behavior)

    def unregister(self, conn: "Connection") -> None:
        """Stop tracking a closed connection. Binding-internal."""
        self._connections.pop(conn._conn_id, None)

    def record_foreign_home(self, reference: Reference, home: int) -> None:
        """Record that fetched far ``reference`` lives on connection ``home`` so a
        later foreign-home return is re-gifted, not mis-encoded (ADR-0009)."""
        if isinstance(reference, Far):
            self._node.record_foreign_home(reference.id, home)

    def arg_is_foreign(self, default_conn: int, reference: Reference) -> bool:
        """Whether ``reference`` names a capability foreign to ``default_conn`` as
        a ``send``/``tell`` argument — a redeemed token or a far the node recorded
        as living on another connection (ADR-0066). The node owns the verdict; a
        send fails closed on it rather than mis-encoding the reference."""
        return isinstance(reference, Far) and self._node.arg_is_foreign(default_conn, reference.id)

    def route(self, default_conn: int, reference: Reference) -> "Optional[tuple[Connection, Far]]":
        """The exporter route for a redeemed token addressed from ``default_conn``:
        the destination :class:`Connection` and the real exporter-side reference to
        swap in. ``None`` for an ordinary reference (it rides its own connection),
        and ``None`` — fail closed — when the token's exporter connection is gone."""
        if not isinstance(reference, Far) or reference.id < REDEEMED_TOKEN_BASE:
            return None
        routed = self._node.route(default_conn, reference.id)
        if routed is None:
            return None
        conn_id, far_id = routed
        conn = self._connections.get(conn_id)
        if conn is None:
            return None
        return conn, Far(id=far_id, promise=False)

    def accept_give(self, recipient_conn: int, answer: int, give: Handoff) -> None:
        """Feed an intercepted handoff give to the core's serve step (ADR-0067):
        the node decides what happens next — reuse a cached exporter, join a dial
        in flight, or ask for a fresh dial — and this side only executes the
        actions. Binding-internal: the serve loop calls it and kicks the
        executor."""
        self._node.accept_give(recipient_conn, answer, give.give, give.exporter_locator)

    def _kick_actions(self) -> None:
        """Run the serve step's action executor. Idempotent while a drain is
        already running: feeds queue actions and the running drain picks them
        up (asyncio is single-threaded, and the drain resets its flag with no
        await between the empty check and the reset, so a kick can never race
        into a lost action)."""
        if self._draining:
            return
        self._draining = True
        self._drain_task = asyncio.ensure_future(self._drain_actions())

    async def _drain_actions(self) -> None:
        try:
            while True:
                action = self._node.next_action()
                if action is None:
                    return
                try:
                    await self._run_action(action)
                except Exception:  # noqa: BLE001 — one failed action must not strand the drain
                    # A failing arm (a flush to a dead socket, say) is that
                    # connection's fault to surface at its own teardown; the
                    # remaining actions still execute. Cancellation propagates.
                    pass
        finally:
            self._draining = False

    async def _run_action(self, action: _PoppedAction) -> None:
        # The executor is deliberately dumb: every decision was already made in
        # the core; each arm is pure I/O or marshaling.
        if action.kind == _NODE_ACTION_DIAL:
            try:
                conn = await Connection._dial_exporter(action.locator, self)
            except Exception as error:  # noqa: BLE001 — the node turns a failed dial into a broken answer
                self._node.dial_failed(action.pending, str(error) or type(error).__name__)
                return
            conn._node_dialed = True
            conn.serve()
            self._node.exporter_dialed(action.pending, conn._conn_id)
        elif action.kind == _NODE_ACTION_FLUSH:
            conn = self._connections.get(action.conn_id)
            if conn is not None:
                await conn._flush_outbound()
        elif action.kind == _NODE_ACTION_SETTLE:
            conn = self._connections.get(action.conn_id)
            if conn is not None:
                conn._vat.serve(Resolve(answer=action.answer, resolution=Fulfill(Far(id=action.token, promise=False))))
        elif action.kind == _NODE_ACTION_FAIL:
            conn = self._connections.get(action.conn_id)
            if conn is not None:
                conn._vat.serve(Resolve(answer=action.answer, resolution=Break(action.reason)))
        elif action.kind == _NODE_ACTION_NEED_GIFT_ID:
            # Entropy is a host effect, drawn only when a reply actually
            # becomes a gift.
            self._node.provide_gift_id(action.pending, secrets.token_bytes(32))

    def claim_resolve(self, conn_id: int, event: "Resolve") -> bool:
        """Offer a polled resolve to the core's serve step. True when it settled
        a pending withdraw (the node consumed it; do not surface it); false when
        the resolve is the application's. Binding-internal: only a node-dialed
        exporter connection's loop offers, so an ordinary connection's reply
        path pays nothing."""
        resolution = event.resolution
        if isinstance(resolution, Fulfill) and isinstance(resolution.value, Far):
            return self._node.claim_resolve(conn_id, event.answer, _REDEEM_OUTCOME_FAR, resolution.value.id, "")
        if isinstance(resolution, Break):
            return self._node.claim_resolve(conn_id, event.answer, _REDEEM_OUTCOME_BROKEN, 0, resolution.message)
        # A non-capability fulfillment — a nested handoff give included: a
        # withdraw must resolve to a capability, never recurse.
        return self._node.claim_resolve(conn_id, event.answer, _REDEEM_OUTCOME_NOT_CAPABILITY, 0, "")

    async def close_exporters(self) -> None:
        """Close every exporter connection this node dialed for redeems."""
        for conn in [c for c in self._connections.values() if c._node_dialed]:
            await conn._close_transport()


class Caretaker:
    """A revocable caretaker over a capability (ADR-0064), returned by
    :meth:`Connection.caretaker`. Hand :attr:`proxy` to a partner; call
    :meth:`revoke` to sever it, after which every call through the proxy breaks
    with ``Revoked``."""

    def __init__(self, proxy: Ref, live: list):
        self.proxy = proxy
        self._live = live

    def revoke(self) -> None:
        """Sever the proxy: subsequent calls through it break with ``Revoked``.
        Idempotent."""
        self._live[0] = False


class Connection:
    """A live connection to one OCapN partner, the one object an app holds.

        conn = await connect(tcp_locator("127.0.0.1", 9099))
        conn.serve()
        board = await conn.fetch("board")
        inbox = conn.spawn(lambda verb, args: None)
        await conn.send(board, "watch", [inbox])
    """

    def __init__(self, ac: AsyncConnection, node: Node, conn_id: int):
        self._ac = ac
        self._vat = ac.vat()
        self._node = node
        # This connection's node-assigned id (ADR-0066): the router resolves a
        # redeemed token to the exporter connection by it, and a fetch stamps a far
        # import's foreign home with it.
        self._conn_id = conn_id
        self._serve_task: Optional[asyncio.Task] = None
        self._closing = False
        # Whether the transport and node-owned peer have been released; the
        # serve loop's own teardown and :meth:`_close_transport` both land in
        # :meth:`_release_transport`, which must run once.
        self._released = False
        # Distributed GC (ADR-0063), opt-in and off by default. When on, a
        # `fetch` result is tracked by a `weakref.finalize`; its release is
        # parked here and a single drain enqueues the `op:gc-exports`. The loop is
        # captured now (construction runs under the running loop) so a finalizer
        # firing during GC — possibly off the loop thread — can hop back to it.
        self._gc = False
        self._gc_pending: "list[int]" = []
        self._gc_drain_task: Optional[asyncio.Task] = None
        self._loop = asyncio.get_event_loop()
        # True for an exporter connection the node's serve step asked the
        # executor to dial: only such a connection's loop offers resolves to
        # `Node.claim_resolve` (pending withdraws exist nowhere else), so an
        # ordinary connection's reply path pays nothing for handoffs.
        self._node_dialed = False
        # Originate a three-party handoff when a published actor returns a
        # capability whose home is a different connection (ADR-0009).
        self._vat.set_resolve_interceptor(self._intercept_resolve)
        # Join the node so every node-giftable is published on this connection too
        # — including this one, accepted after the giftable was registered.
        self._node.register(self)

    @classmethod
    async def connect(cls, host: str, port: int, node: Optional[Node] = None) -> "Connection":
        """Dial ``host:port``, complete the keyed OCapN handshake, and return a
        ready connection. The session is open before this resolves, so a
        ``fetch``/``send`` rides an established session, the same handshake a
        real Goblins peer requires. Pass ``node`` to share one node identity
        and gift registry across several connections (the gifter side of a
        three-party handoff); omit it for a standalone connection."""
        node = node if node is not None else Node()
        reader, writer = await asyncio.open_connection(host, port)
        conn_id, peer = node.register_conn()
        try:
            ac = AsyncConnection.from_stream(peer, reader, writer)
            await _open_keyed_session(ac, node.seed)
        except BaseException:
            # The handshake failed with the socket open: close it so the dial
            # leaks no fd, then free the node-owned peer.
            writer.close()
            node.remove_conn(conn_id)
            raise
        return cls(ac, node, conn_id)

    @classmethod
    async def _accept(cls, reader, writer, node: Optional[Node] = None) -> "Connection":
        """Wrap an accepted stream and complete the keyed handshake from the
        responder side. Resolves once the session is open. Construct *before*
        driving the handshake to completion so the node's giftables are published
        as bootstrap caps before a dialer's pipelined bootstrap fetch is
        answered, a recipient redeeming a gift fetches it the instant the
        session opens."""
        node = node if node is not None else Node()
        conn_id, peer = node.register_conn()
        ac = AsyncConnection.from_stream(peer, reader, writer)
        conn = cls(ac, node, conn_id)
        try:
            await _open_keyed_session(ac, node.seed)
        except BaseException:
            await conn._close_transport()
            raise
        return conn

    @classmethod
    async def _dial_exporter(cls, uri: str, node: Node) -> "Connection":
        """Dial an exporter named by a handoff give's ``ocapn://`` locator, keyed
        with ``node``'s retained identity, and bind the result to that same
        node so the redeemed capability and any further handoff it triggers
        share one identity and connection table. Binding-internal: the node
        calls this to redeem a give. Dispatches on the locator's transport, a
        ``tcp`` host:port, or an ``iroh`` endpoint id whose posture the give's
        hints imply: direct-address hints dial them with no discovery service
        (Direct), a bare node id resolves by id under the recipient node's
        configured redeem posture (default Discovery; a relay-policy node lowers
        it to DiscoveryNoRelay), so one give shape covers an offline direct dial
        and an internet dial-by-id alike."""
        loc = parse_locator(uri)
        if loc.transport == "tcp":
            if loc.host is None or loc.port is None:
                raise PancakeError(_ERR_INVALID_ARGUMENT, f"tcp locator designator is not host:port: {loc.designator}")
            reader, writer = await asyncio.open_connection(loc.host, loc.port)
            conn_id, peer = node.register_conn()
            try:
                ac = AsyncConnection.from_stream(peer, reader, writer)
                await _open_keyed_session(ac, node.seed)
            except BaseException:
                # The handshake failed with the socket open: close it so the
                # redeem dial leaks no fd, then free the node-owned peer.
                writer.close()
                node.remove_conn(conn_id)
                raise
            return cls(ac, node, conn_id)
        if loc.transport == "iroh":
            from . import iroh as _iroh_transport
            addrs = loc.hints.get("direct-addresses", "")
            reachability = (
                _iroh_transport.Reachability.DIRECT if addrs else node.redeem_reachability
            )
            return await _iroh_transport.connect_iroh_with_node(loc.designator, addrs, reachability, node)
        raise PancakeError(
            _ERR_INVALID_ARGUMENT,
            f'handoff redeem: unsupported exporter transport "{loc.transport}" in {uri}',
        )

    @property
    def peer(self) -> Peer:
        """The underlying sans-io peer, the escape hatch for handoff, pipelining,
        and session control. Applications do not need it."""
        return self._ac.peer

    @property
    def node(self) -> Node:
        """The connection's shared node, its retained identity and gift
        registry, shared by every connection of one node so the gifter half of
        a handoff can reach a sibling connection's session keys. An application
        reads it to publish node-giftables (:meth:`Node.publish_giftable`),
        share one identity across dials, or set the redeem posture."""
        return self._node

    def set_exporter_locator(self, raw_locator: bytes) -> None:
        """Record the dialable exporter location a gifter origination signs into
        gives whose exporter is this connection, in place of the exporter's own
        signed session record (ADR-0009). ``raw_locator`` is the verbatim
        location bytes from :func:`encode_peer_locator` (read off the registered
        exporter URI). The record lives in the core node, where the origination
        recipe reads it. Binding-internal: a rendezvous that learned a member's
        iroh URI sets it so a give can name an exporter reachable only by a dial
        hint under the relay-less ``Direct`` posture."""
        self._node._node.set_exporter_location(self._conn_id, raw_locator)

    def spawn(self, behavior: Behavior) -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback. The
        position comes from the session's one export allocator, so it can never
        alias a bootstrap or resolver export."""
        position = self._ac.peer.next_export()
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def publish(self, name: str, behavior: Behavior) -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        position = self._ac.peer.register_bootstrap_cap(name.encode())
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def caretaker(self, target: Ref) -> Caretaker:
        """Wrap ``target`` (local or far) in a revocable caretaker (ADR-0064).
        Returns a :class:`Caretaker` whose ``proxy`` is an ordinary capability
        to hand a partner; every call through it forwards to ``target`` until
        :meth:`Caretaker.revoke`, after which each breaks with ``Revoked``.
        ``target`` may be a capability imported over the wire — the proxy
        forwards transparently — so this hands out a revocable view of authority
        you do not own locally. The proxy is a plain spawned actor, so it answers
        a local call exactly as a partner's does."""
        live = [True]

        def proxy_behavior(verb: str, args: list):
            if not live[0]:
                raise ValueError("Revoked")
            return Forward(target, verb, args)

        return Caretaker(self.spawn(proxy_behavior), live)

    def attenuate(self, target: Ref, verbs: list[str]) -> Ref:
        """Wrap ``target`` (local or far) in an attenuator (ADR-0064): a proxy
        that forwards only the calls whose verb is in ``verbs`` and breaks every
        other with ``Attenuated``. Returns the proxy capability to hand a
        partner. ``target`` may be a wire-imported capability, so this narrows
        authority you hold. The proxy is a plain spawned actor."""
        allowed = set(verbs)

        def proxy_behavior(verb: str, args: list):
            if verb not in allowed:
                raise ValueError("Attenuated")
            return Forward(target, verb, args)

        return self.spawn(proxy_behavior)

    def _settle(self, vow) -> "asyncio.Future":
        """Register a listener on ``vow`` now and return a future it settles. The
        listener must be registered before any pump (``drive``/``flush``): a local
        ``drive`` fires synchronously, and a far reply can land on the serve loop
        the instant ``flush`` yields. Either would settle before a later
        ``await`` could subscribe."""
        future = asyncio.get_running_loop().create_future()

        def fulfilled(value: object) -> None:
            if not future.done():
                future.set_result(value)

        def broken(message: str) -> None:
            if not future.done():
                future.set_exception(VowBroken(message))

        self._vat.on(vow, on_fulfilled=fulfilled, on_broken=broken)
        return future

    async def fetch(self, name: str) -> Ref:
        """Fetch a partner's published capability by ``name``. Starts the inbound
        loop itself, so a ``fetch`` straight after ``connect`` works without a
        separate :meth:`serve` call (which stays the way to keep serving).
        Raises :class:`VowBroken` when the partner breaks the fetch, and
        :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        self.serve()  # idempotent; the resolution arrives on the inbound loop
        # The canonical fetch lives in the library: one call registers the
        # bootstrap import, allocates the answer, and queues the deliver.
        answer = self._ac.peer.send_bootstrap_fetch(name.encode())
        future = self._settle(Vow(answer=answer, vat=self._vat))
        await self._ac.flush()
        result = await future
        # Record the foreign home in the node: a fetched far capability lives on
        # *this* connection. Used here it is an ordinary import; returned to another
        # connection (a gift to pass on), the recorded home is what lets the gifter
        # half recognize it as foreign and originate a three-party handoff rather
        # than mis-encode a cross-connection reference (ADR-0009).
        if isinstance(result, Far):
            self._node.record_foreign_home(result, self._conn_id)
            return self._track_import(Ref(far=result))
        if isinstance(result, Near):
            return Ref(near=result)
        # Only a near/far reference is a live capability this surface can hand
        # out; a sturdy, promise, or broken reference would leak a
        # half-supported kind, so the fetch fails instead.
        raise FetchFailed(name)

    def with_gc(self) -> "Connection":
        """Opt this connection into distributed GC (ADR-0063), off by default.
        Once on, a far capability returned by :meth:`fetch` releases its import
        to the partner -- a single ``op:gc-exports`` delta -- when the runtime
        reclaims the last :class:`Ref` to it, so the partner can release the
        matching export. CPython's refcounting makes that release prompt on the
        last ``del``. Capabilities lifted elsewhere (a ``send`` reply, a delivered
        argument, an ``enliven`` result the dedup cache owns) are outside this
        seam. Returns ``self`` for chaining."""
        self._gc = True
        return self

    def _track_import(self, ref: Ref) -> Ref:
        """Register a fetched far import for GC when GC is on (ADR-0063). The
        bootstrap import (position 0) is refused in a ``gc-exports`` and never
        tracked; the finalizer captures only the integer position, never the
        ``Ref``, so it does not pin the very handle whose death it waits on."""
        if self._gc and ref.far is not None and ref.far.id != 0 and ref.far.id < REDEEMED_TOKEN_BASE:
            weakref.finalize(ref, self._on_import_dropped, ref.far.id)
        return ref

    def _on_import_dropped(self, position: int) -> None:
        # Runs when the last `Ref` is collected, possibly off the loop thread:
        # park the position and hop to the loop to drain it.
        self._gc_pending.append(position)
        try:
            self._loop.call_soon_threadsafe(self._schedule_gc_drain)
        except RuntimeError:
            # The loop is closed; teardown reclaims the partner's export.
            pass

    def _schedule_gc_drain(self) -> None:
        if self._gc_drain_task is None or self._gc_drain_task.done():
            self._gc_drain_task = asyncio.ensure_future(self._drain_gc())

    async def _drain_gc(self) -> None:
        """Drain the parked GC releases: one ``op:gc-exports`` delta per reclaimed
        import, flushed through the outbound pump. Best-effort -- a refused
        release strands a partner export reclaimed at teardown, never a fault."""
        while self._gc_pending and not self._closing:
            positions = self._gc_pending
            self._gc_pending = []
            for position in positions:
                try:
                    self._ac.peer.send_gc_export([position], [1])
                except Exception:
                    pass
            try:
                await self._ac.flush()
            except Exception:
                pass

    async def enliven(self, sturdyref: str) -> Ref:
        """Enliven a sturdyref against this connection (ADR-0012): bring the
        durable ``(peer, swissnum)`` to life as a live :class:`Ref`. Parses
        ``sturdyref`` for its swissnum, then fetches it through the dedup cache
        -- a repeat enliven of the same swissnum on this session short-circuits
        with no wire traffic. The connection must already be open to the
        sturdyref's peer; the sans-io core tracks no remote locator and never
        dials. Raises :class:`VowBroken` when the partner breaks the enliven,
        and :class:`FetchFailed` when it fulfills with something that is not a
        capability."""
        swiss = parse_locator(sturdyref, sturdyref=True).swissnum.encode()
        self.serve()  # the resolution arrives on the inbound loop
        peer = self._ac.peer
        start = peer.prepare_enliven(swiss)
        if start.status == _ENLIVEN_CACHED:
            # Cache hit: reconstruct the far reference, no wire traffic. Record
            # its foreign home so a later give addressed by it routes (ADR-0009).
            cached = Far(id=start.import_position, promise=start.kind == _REF_SUB_PROMISE)
            self._node.record_foreign_home(cached, self._conn_id)
            return Ref(far=cached)
        # FRESH or IN_FLIGHT: drive the (possibly shared) answer to settlement.
        future = self._settle(Vow(answer=start.answer, vat=self._vat))
        await self._ac.flush()
        try:
            result = await future
        except BaseException:
            peer.record_enlivenment(swiss, _ENLIVEN_OUTCOME_BROKEN, 0, 0)
            raise
        if not isinstance(result, Far):
            peer.record_enlivenment(swiss, _ENLIVEN_OUTCOME_BROKEN, 0, 0)
            raise FetchFailed(sturdyref)
        # Cache the fulfilled far reference so a repeat enliven short-circuits.
        peer.record_enlivenment(
            swiss,
            _ENLIVEN_OUTCOME_FULFILLED,
            result.id,
            _REF_SUB_PROMISE if result.promise else _REF_SUB_OBJECT,
        )
        # An enlivened capability lives on *this* connection, like a fetched
        # one: record its home so the gifter half can recognize it as foreign
        # when it is returned to another connection (ADR-0009).
        self._node.record_foreign_home(result, self._conn_id)
        return Ref(far=result)

    def _is_foreign(self, far: Far) -> bool:
        """Whether ``far`` names a capability that lives on a *different*
        connection: a redeemed-handoff token (the node routes it to its exporter)
        or a far the node recorded as fetched on another connection of this node.
        The gifter half handles such a capability when it is *returned*
        (ADR-0009); passing one as an argument is the symmetric case still to
        land, so a send fails closed rather than mis-encode it for this partner.
        The node owns the verdict (ADR-0066)."""
        return self._node.arg_is_foreign(self._conn_id, far)

    def _assert_no_foreign_ref(self, value: "Value") -> None:
        """Refuse a capability that lives on another connection in send-argument
        position, recursing into the container shapes a reference can hide in."""
        if isinstance(value, Ref):
            if value.far is not None and self._is_foreign(value.far):
                raise PancakeError(
                    _ERR_INVALID_ARGUMENT,
                    "passing a capability that lives on another connection as a send argument is not yet supported; "
                    "introduce it as a return value instead (three-party handoff in argument position is the next lift)",
                )
        elif isinstance(value, Tagged):
            for item in value.value:
                self._assert_no_foreign_ref(item)
        elif isinstance(value, list):
            for item in value:
                self._assert_no_foreign_ref(item)

    def send(self, target: "Ref | RemotePromise", verb: str, args: Optional[list[Value]] = None) -> RemotePromise:
        """Eventual-send ``verb(args)`` to ``target`` and return a
        :class:`RemotePromise` for the reply. ``await`` it for the value (a
        :class:`Ref` if the partner returned a capability; raises
        :class:`VowBroken` on a break), exactly as before.

        ``target`` is a capability :class:`Ref` *or* a :class:`RemotePromise`
        from an earlier send: passing the latter pipelines (ADR-0007) -- the call
        is addressed at the answer that send will resolve, so a dependent chain
        costs one round trip instead of one per link. ``args`` may contain
        :class:`Ref`s.

        The deliver is queued now; its bytes leave the wire when the returned
        handle -- or any send pipelined behind it -- is first awaited, so a
        pipelined batch travels together."""
        # A capability redeemed from a handoff is a token the node routes to the
        # exporter connection it lives on; send there with the real exporter-side
        # reference so the bytes go straight to the exporter, transparently to the
        # application (Goblins' three-party handoff).
        if isinstance(target, Ref) and target.far is not None:
            routed = self._node.route(self._conn_id, target.far)
            if routed is not None:
                exporter, reference = routed
                return exporter.send(Ref(far=reference), verb, args)
        for a in (args or []):
            self._assert_no_foreign_ref(a)
        wire_args = [self._lower(a) for a in (args or [])]
        is_local = isinstance(target, Ref) and target.local_id is not None
        if not is_local:
            self.serve()  # far reply arrives on the inbound loop
        if isinstance(target, RemotePromise):
            if target.answer is None:
                raise PancakeError(_ERR_UNSUPPORTED_VALUE, "cannot pipeline against a local-send promise; await it for a Ref")
            vow = self._vat.send_to_answer(target.answer, verb, wire_args)
        else:
            vow = self._vat.send(target._vat(), verb, wire_args)

        answer = None if vow.is_local else vow.answer

        async def begin() -> Value:
            future = self._settle(vow)  # subscribe before any pump
            if is_local:
                self._vat.drive()
                # A local actor may tail-forward to a far target (a caretaker over
                # a wire-imported capability, ADR-0064); its answer then settles on
                # the partner's reply, so pump the wire to await it.
                if not future.done():
                    self.serve()
                    await self._ac.flush()
            else:
                await self._ac.flush()
            value = await future
            # A redeemed-handoff resolution already lifts as an ordinary token (the
            # node routes it to its exporter); every resolution lifts the same way.
            return self._lift(value)

        # Only a far answer is projectable; a local-send handle has none.
        project = None
        if answer is not None:
            def project(op: str, key):
                return self._project_answer(answer, op, key)

        return RemotePromise(answer, begin, project)

    def _project_answer(self, source_answer: int, op: str, key) -> RemotePromise:
        """Pipeline a projection (``op:index`` / ``op:untag``,
        ADR-0050/ADR-0052) at ``source_answer``. Like :meth:`send`, the op is
        queued now and the flush is deferred to the returned handle's first
        await, so a chain of projections leaves the wire together. The result is
        itself projectable."""
        self.serve()  # the projected resolution arrives on the inbound loop
        peer = self._ac.peer
        receiver = Promise(source_answer)
        answer = peer.next_answer()
        if op == "index":
            peer.send_index(receiver, key, answer)
        else:
            peer.send_untag(receiver, key, answer)
        vow = Vow(answer=answer, vat=self._vat)

        async def begin() -> Value:
            future = self._settle(vow)
            await self._ac.flush()
            return self._lift(await future)

        def project(op2: str, key2):
            return self._project_answer(answer, op2, key2)

        return RemotePromise(answer, begin, project)

    async def tell(self, target: Ref, verb: str, args: Optional[list[Value]] = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        # Route a redeemed-handoff token to its exporter connection, as send.
        if target.far is not None:
            routed = self._node.route(self._conn_id, target.far)
            if routed is not None:
                exporter, reference = routed
                await exporter.tell(Ref(far=reference), verb, args)
                return
        for a in (args or []):
            self._assert_no_foreign_ref(a)
        wire_args = [self._lower(a) for a in (args or [])]
        if target.local_id is not None:
            self._vat.send(target._vat(), verb, wire_args)
            self._vat.drive()
            return
        payload = [Symbol(verb), *wire_args] if verb else wire_args
        self._ac.peer.send_deliver(target._wire(), payload, answer=None)
        await self._ac.flush()

    def serve(self) -> "asyncio.Task":
        """Run the inbound event loop as a background task: dispatch each arriving
        call to its actor and settle the promises of awaiting ``send``s. The task
        completes when the connection closes; started once."""
        if self._serve_task is None:
            self._serve_task = asyncio.create_task(self._serve_loop())
        return self._serve_task

    async def _serve_loop(self) -> None:
        # Either a clean disconnect or a transport fault ends the loop; the wire
        # is gone in both cases, so break any ``send`` still awaiting a reply
        # rather than leaving its future pending forever.
        try:
            async for event in self._ac:
                if isinstance(event, Resolve):
                    # A pending withdraw's resolution belongs to the core's
                    # serve step, and only a node-dialed exporter connection
                    # can carry one — an ordinary connection never pays this
                    # call.
                    if self._node_dialed and self._node.claim_resolve(self._conn_id, event):
                        self._node._kick_actions()
                        continue
                    # A give arriving as a resolution is the serve step's to
                    # redeem, never the vat's: feed it and execute the actions
                    # (dial, withdraw, settle) off this loop, so the redeem's
                    # own I/O does not stall this connection's reads.
                    if isinstance(event.resolution, Handoff):
                        self._node.accept_give(self._conn_id, event.answer, event.resolution)
                        self._node._kick_actions()
                        continue
                self._vat.serve(event)
        except (asyncio.CancelledError, OSError):
            if not self._closing:
                raise
        finally:
            self._vat.break_far_vows("connection closed")
            # When the wire ended on its own (no `close` in progress), release
            # the transport from here: `_close_transport` awaits this very
            # task, so calling it inside the loop would deadlock on itself.
            if not self._closing:
                self._closing = True
                await self._release_transport()

    async def close(self) -> None:
        """Close the connection and every exporter connection its node dialed
        for handoffs. A running :meth:`serve` completes cleanly."""
        self._closing = True
        await self._node.close_exporters()
        await self._close_transport()

    async def _close_transport(self) -> None:
        """Close just this connection's transport, without touching the node's
        other connections, how the node reclaims an exporter connection it
        owns, and the shared teardown :meth:`close` runs last.

        Tear down in order so a release never races the inbound loop: unblock the
        loop's parked transport read, let the loop drain to its end, then free the
        transport and peer. A transport whose read parks on a worker thread (iroh)
        is closed so the read returns a clean EOF and the loop ends on its own;
        one whose read is cancellable (TCP) has its loop task cancelled."""
        self._closing = True
        unblocked = self._ac.shutdown()
        if self._serve_task is not None:
            if not unblocked:
                self._serve_task.cancel()
            try:
                await self._serve_task
            except (asyncio.CancelledError, OSError):
                pass
        await self._release_transport()

    async def _release_transport(self) -> None:
        """Release the transport once nothing pumps it: unregister from the
        node, close the writer, and have the node free the peer and drop the
        connection's routes (ADR-0066); `aclose` no-ops the peer release, the
        node owns it. ``remove_conn`` fails the connection's stranded withdraws
        closed in the core, and the node's ``remove_conn`` kicks the action
        drain so those settlements reach their recipients. Runs once: both
        :meth:`_close_transport` and the serve loop's own teardown land here."""
        if self._released:
            return
        self._released = True
        self._node.unregister(self)
        await self._ac.aclose()
        self._node.remove_conn(self._conn_id)

    async def __aenter__(self) -> "Connection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    def _wrap(self, behavior: Behavior):
        def wrapped(verb: str, raw_args: list):
            result = behavior(verb, [self._lift(a) for a in raw_args])
            # A `Forward` (a caretaker/attenuator) tail-forwards rather than
            # returning a value; lower its args to the wire and let the vat
            # resolve the answer from the forwarded send (ADR-0064).
            if isinstance(result, Forward):
                return Forward(result.target, result.verb, [self._lower(a) for a in result.args])
            # A returned far capability that lives on another connection is lowered
            # to its wire reference like any other; the resolve interceptor reads
            # the node's recorded foreign home to originate a three-party handoff
            # rather than mis-encode the cross-connection reference (ADR-0009).
            return None if result is None else self._lower(result)
        return wrapped

    def _intercept_resolve(self, answer: int, value) -> bool:
        # The vat is about to resolve a deliver's answer. A far capability whose
        # recorded home is another connection is the serve step's to originate
        # as a three-party gift (ADR-0067) — the node claims it, asks for gift
        # entropy, deposits, signs the give, and orders the flushes; this side
        # only kicks the executor. Anything else falls through to the ordinary
        # resolve.
        if not isinstance(value, Far):
            return False
        claimed = self._node._node.intercept_fulfilled_ref(self._conn_id, answer, value.id)
        if claimed:
            self._node._kick_actions()
        return claimed

    async def _flush_outbound(self) -> None:
        """Flush this connection's queued outbound frames. Binding-internal: the
        serve step's flush actions land here."""
        await self._ac.flush()

    @staticmethod
    def _lower(value):
        if isinstance(value, Ref):
            return value._wire()
        if isinstance(value, Set):  # before list, Set subclasses list
            return Set(Connection._lower(v) for v in value)
        if isinstance(value, Tagged):
            return Tagged(value.tag, [Connection._lower(v) for v in value.value])
        if isinstance(value, list):
            return [Connection._lower(v) for v in value]
        return value

    @staticmethod
    def _lift(value):
        if isinstance(value, Far):
            return Ref(far=value)
        if isinstance(value, Near):
            return Ref(near=value)
        if isinstance(value, Set):  # before list, Set subclasses list
            return Set(Connection._lift(v) for v in value)
        if isinstance(value, Tagged):
            return Tagged(value.tag, [Connection._lift(v) for v in value.value])
        if isinstance(value, list):
            return [Connection._lift(v) for v in value]
        return value


class Server:
    """A listening server, one object an app holds, mirroring the Deno/Rust/Racket
    servers. Async-iterable (``async for conn in server``), and ``.port`` surfaces
    the bound port so binding an ephemeral port (``port=0``) and telling a partner
    where to connect works the same as the other bindings."""

    def __init__(self, server: asyncio.AbstractServer, queue: "asyncio.Queue", node: Node):
        self._server = server
        self._queue = queue
        self._node = node

    @property
    def port(self) -> int:
        """The kernel-chosen bound port (read it back after binding ``port=0``)."""
        return self._server.sockets[0].getsockname()[1]

    @property
    def node(self) -> Node:
        """The server's shared node: one retained identity and gift registry
        across every accepted connection. Pass it to :meth:`Connection.connect`
        so a fetched capability and the recipient connection share one node,
        the gifter side of a three-party handoff. Publish a node-giftable on it
        with :meth:`Node.publish_giftable`."""
        return self._node

    def close(self) -> None:
        self._server.close()

    def __aiter__(self) -> "Server":
        return self

    async def __anext__(self) -> "Connection":
        # A partner that fails its handshake — a rude probe that connects and
        # hangs up — is that connection's failure, never the listener's: skip
        # it and keep accepting, so one port scan cannot take a long-lived
        # server down. (``Connection._accept`` already closed the transport.)
        while True:
            reader, writer = await self._queue.get()
            try:
                return await Connection._accept(reader, writer, self._node)
            except (PancakeError, OSError):
                # PancakeError: the handshake failed (EOF mid-handshake).
                # OSError: the probe reset the socket under the teardown.
                continue


async def listen(host: str, port: int = 0) -> Server:
    """Bind a listening :class:`Server`. ``async for conn in await listen(host, 0)``
    accepts each partner; ``server.port`` reads the bound ephemeral port. Each
    yielded :class:`Connection` is one accepted partner, publish capabilities on
    it and call :meth:`Connection.serve`."""
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), host, port,
    )
    return Server(server, queue, Node())


# ── OCapN locator URIs ───────────────────────────────────────────────────────
#
# The `ocapn://<designator>.<transport>[?hints]` grammar is core OCapN
# vocabulary, defined once in libpancake_ocapn's `pancake_uri_*` / `pancake_locator_*`
# surface, so no binding hand-rolls a percent codec. `parse_locator` copies every
# borrowed view into Python strings before releasing the handle; `format_peer_uri`
# renders through the same grammar.


class Locator(NamedTuple):
    """A parsed OCapN locator: the fields a ``pancake_uri_parse_*`` yields.
    ``swissnum`` is empty for a peer URI, the swiss bytes for a sturdyref.
    ``host``/``port`` carry the designator's ``host:port`` split when the core
    grammar (``pancake_locator_host_port``) accepts it, ``None`` otherwise; a
    socket dialer consumes the split instead of re-deriving it."""

    transport: str
    designator: str
    swissnum: str
    hints: "dict[str, str]"
    host: "Optional[str]" = None
    port: "Optional[int]" = None


def _read_view(ptr: ctypes.c_void_p, length: ctypes.c_size_t) -> str:
    # Decode a borrowed (pointer, length) view a locator accessor filled. A zero
    # length (or NULL pointer) is the empty string.
    n = length.value
    if n == 0 or not ptr.value:
        return ""
    return ctypes.string_at(ptr.value, n).decode("utf-8")


def parse_locator(uri: str, *, sturdyref: bool = False) -> Locator:
    """Parse an ``ocapn://`` URI into its structured locator fields through the
    core grammar. ``sturdyref`` selects the ``/s/<swiss>`` form; the default reads
    a peer URI. Raises :class:`PancakeError` for a malformed URI."""
    raw = uri.encode("utf-8")
    out = ctypes.c_void_p()
    parse = _lib.pancake_uri_parse_sturdyref if sturdyref else _lib.pancake_uri_parse_peer
    _check(parse(raw, len(raw), ctypes.byref(out)))
    try:
        def field(accessor) -> str:
            p = ctypes.c_void_p()
            n = ctypes.c_size_t()
            _check(accessor(out, ctypes.byref(p), ctypes.byref(n)))
            return _read_view(p, n)

        count = ctypes.c_size_t()
        _check(_lib.pancake_locator_hint_count(out, ctypes.byref(count)))
        hints: "dict[str, str]" = {}
        for i in range(count.value):
            kp = ctypes.c_void_p()
            kn = ctypes.c_size_t()
            vp = ctypes.c_void_p()
            vn = ctypes.c_size_t()
            _check(_lib.pancake_locator_hint_at(out, i, ctypes.byref(kp), ctypes.byref(kn), ctypes.byref(vp), ctypes.byref(vn)))
            hints[_read_view(kp, kn)] = _read_view(vp, vn)
        # The host:port split is the core grammar's verdict, computed while the
        # handle is alive: OK carries the split, INVALID_ARGUMENT means the
        # designator is not host:port (an iroh node id, say), which is a fact,
        # not a fault.
        hp = ctypes.c_void_p()
        hn = ctypes.c_size_t()
        hport = ctypes.c_uint16()
        rc = _lib.pancake_locator_host_port(out, ctypes.byref(hp), ctypes.byref(hn), ctypes.byref(hport))
        host: "Optional[str]" = None
        port: "Optional[int]" = None
        if rc == _OK:
            host = _read_view(hp, hn)
            port = hport.value
        elif rc != _ERR_INVALID_ARGUMENT:
            _check(rc)
        return Locator(
            field(_lib.pancake_locator_transport),
            field(_lib.pancake_locator_designator),
            field(_lib.pancake_locator_swissnum),
            hints,
            host,
            port,
        )
    finally:
        _lib.pancake_locator_release(out)


def format_peer_uri(transport: str, designator: str, hints: "Optional[dict[str, str]]" = None) -> str:
    """Format a peer locator as an ``ocapn://<designator>.<transport>[?hints]``
    URI through the core grammar."""
    items = list((hints or {}).items())
    t = transport.encode("utf-8")
    d = designator.encode("utf-8")
    keys = [k.encode("utf-8") for k, _ in items]
    vals = [v.encode("utf-8") for _, v in items]
    n = len(items)
    if n:
        key_arr = (ctypes.c_char_p * n)(*keys)
        val_arr = (ctypes.c_char_p * n)(*vals)
        key_lens = (ctypes.c_size_t * n)(*[len(k) for k in keys])
        val_lens = (ctypes.c_size_t * n)(*[len(v) for v in vals])
        key_ptr = ctypes.cast(key_arr, ctypes.c_void_p)
        val_ptr = ctypes.cast(val_arr, ctypes.c_void_p)
        key_len_ptr = ctypes.cast(key_lens, ctypes.c_void_p)
        val_len_ptr = ctypes.cast(val_lens, ctypes.c_void_p)
    else:
        key_ptr = val_ptr = key_len_ptr = val_len_ptr = None

    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        out_len = ctypes.c_size_t()
        rc = _lib.pancake_uri_format_peer(
            t, len(t), d, len(d),
            key_ptr, key_len_ptr, val_ptr, val_len_ptr, n,
            buf, cap, ctypes.byref(out_len),
        )
        need = out_len.value
        if rc == _OK:
            return buf.raw[:need].decode("utf-8")
        if rc == _ERR_INVALID_ARGUMENT and need > cap:
            cap = need
            continue
        _check(rc)


def tcp_locator(host: str, port: int) -> str:
    """Build a ``tcp`` locator from a literal host and port:
    ``ocapn://host:port.tcp``, rendered through the core grammar. The convenience
    for the common case, a caller holding a host and port passes
    ``connect(tcp_locator(host, port))`` instead of hand-formatting the URI.
    ``host:port`` is not a dial of its own; it is a locator like any other."""
    return format_peer_uri("tcp", f"{host}:{port}")


async def connect(uri: str, reachability: "Optional[int]" = None, node: "Optional[Node]" = None) -> Connection:
    """Dial a partner from its ``ocapn://`` locator, the one dialer, dispatching
    on the locator's transport: ``iroh`` dials the endpoint id with its
    ``direct-addresses`` hints, ``tcp`` dials the ``host:port`` designator. There
    is no other dial: a literal address is a ``tcp`` locator, built with
    :func:`tcp_locator`. Parse once, the core grammar picks the netlayer.

    A ``tcp`` locator needs only this core module. An ``iroh`` locator reaches
    into the companion :mod:`pancake.iroh` (the optional encrypted-QUIC artifact),
    imported lazily here so the core never hard-depends on it; ``reachability`` is
    a :class:`pancake.iroh.Reachability` (its ``int`` value also works) and sets
    the iroh dialer's posture. It is required only for an ``iroh`` locator; a
    ``tcp`` locator ignores it, so a plain TCP dial needs nothing but the locator.
    An iroh locator with no posture fails closed rather than guessing one."""
    loc = parse_locator(uri)
    # Refuse a bad argument before any I/O: a shared node rides only a tcp dial.
    if node is not None and loc.transport != "tcp":
        raise PancakeError(_ERR_INVALID_ARGUMENT, "connect: a shared node is supported only for tcp locators today")
    if loc.transport == "iroh":
        if reachability is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"connect: an iroh locator requires a reachability posture: {uri}")
        from . import iroh as _iroh_transport
        return await _iroh_transport.connect_iroh(loc.designator, loc.hints.get("direct-addresses", ""), reachability)
    if loc.transport == "tcp":
        if loc.host is None or loc.port is None:
            raise PancakeError(_ERR_INVALID_ARGUMENT, f"tcp locator designator is not host:port: {loc.designator}")
        return await Connection.connect(loc.host, loc.port, node)
    raise PancakeError(_ERR_INVALID_ARGUMENT, f'connect: unsupported transport "{loc.transport}"')
