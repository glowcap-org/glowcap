"""Idiomatic Python API for ``libpancake`` — an OCapN/CapTP peer you drive.

The raw ``ctypes`` FFI is private to this module. What you use is a :class:`Peer`
(a context manager that releases itself), native Python values as arguments
(``int``/``float``/``bool``/``bytes``/``str``/``list``, plus :class:`Symbol` and
references), and typed :class:`Event` objects out of :meth:`Peer.poll`.

    with Peer() as peer:
        peer.register_import(5)
        peer.send_deliver(Far(5), [42, b"hi"], answer=9)
        peer.step()
        frame = peer.take_outbound()
"""

from __future__ import annotations

import asyncio
import ctypes
import pathlib
import secrets
import sys
from dataclasses import dataclass, field
from typing import Optional, Union

# The dynamic library's name is platform-specific: `.dylib` on macOS, `.dll` on
# Windows, `.so` elsewhere. `zig build` emits the right one into zig-out/lib.
_LIB_FILE = (
    "libpancake.dylib" if sys.platform == "darwin"
    else "pancake.dll" if sys.platform == "win32"
    else "libpancake.so"
)
_LIB = pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "lib" / _LIB_FILE

_OK = 0
_WOULD_BLOCK = -7
_FRAME_SHAPE_BYTE = 0
_EVENT_DELIVER = 1
_EVENT_RESOLVE = 2

_REF_NEAR, _REF_FAR, _REF_PROMISE, _REF_STURDY, _REF_BROKEN = 0, 1, 2, 3, 4
_REF_OBJECT, _REF_PROMISE_KIND = 0, 1

_ARG_INTEGER, _ARG_FLOAT64, _ARG_BOOLEAN, _ARG_BYTES = 0, 1, 2, 3
_ARG_STRING, _ARG_SYMBOL, _ARG_VOID, _ARG_REFERENCE, _ARG_LIST = 4, 5, 6, 7, 8
_ARG_SET, _ARG_TAGGED, _ARG_KEYWORD = 9, 10, 11

_RESOLUTION_FULFILL, _RESOLUTION_BREAK = 0, 1


# ── Raw ctypes layer (private) ───────────────────────────────────────────────


class _Reference(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("sub_kind", ctypes.c_uint32), ("id", ctypes.c_uint64)]


class _Argument(ctypes.Structure):
    pass


_Argument._fields_ = [
    ("kind", ctypes.c_uint32),
    ("boolean", ctypes.c_uint32),
    ("integer", ctypes.c_int64),
    ("float64", ctypes.c_double),
    ("bytes", ctypes.c_void_p),
    ("bytes_len", ctypes.c_size_t),
    ("reference", _Reference),
    ("items", ctypes.POINTER(_Argument)),
    ("items_len", ctypes.c_size_t),
]


class _Frame(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_void_p), ("len", ctypes.c_size_t), ("shape", ctypes.c_uint32)]


class _ManagedFrame(ctypes.Structure):
    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
        ("shape", ctypes.c_uint32),
        ("release", ctypes.c_void_p),
        ("private_data", ctypes.c_void_p),
    ]


class _Event(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("frame", _ManagedFrame)]


# The release callback a managed frame carries: void (*)(PancakeManagedFrame*).
_ManagedFrameRelease = ctypes.CFUNCTYPE(None, ctypes.POINTER(_ManagedFrame))

# Host allocator callbacks:
#   void *(*alloc)(void *user_data, size_t size, size_t alignment);
#   void  (*free )(void *user_data, void *ptr, size_t size, size_t alignment);
_AllocFn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)
_FreeFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)


class _Allocator(ctypes.Structure):
    _fields_ = [("alloc", _AllocFn), ("free", _FreeFn), ("user_data", ctypes.c_void_p)]


class _Deliver(ctypes.Structure):
    _fields_ = [
        ("target", _Reference),
        ("args", ctypes.POINTER(_Argument)),
        ("args_len", ctypes.c_size_t),
        ("has_answer", ctypes.c_uint32),
        ("answer", ctypes.c_uint64),
        ("owner", ctypes.c_void_p),
    ]


class _Resolve(ctypes.Structure):
    _fields_ = [
        ("answer", ctypes.c_uint64),
        ("resolution_kind", ctypes.c_uint32),
        ("fulfill", _Argument),
        ("break_message", ctypes.c_void_p),
        ("break_message_len", ctypes.c_size_t),
        ("owner", ctypes.c_void_p),
    ]


def _load():
    lib = ctypes.CDLL(str(_LIB))
    P = ctypes.c_void_p
    sigs = {
        "pancake_abi_version": (
            [ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)],
            None,
        ),
        "pancake_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_clear_last_error": ([], None),
        "pancake_context_new_default": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_new_with_allocator": ([ctypes.POINTER(_Allocator), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_release": ([P], None),
        "pancake_peer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_negotiating": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_start_session_keyed": (
            [P, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p],
            ctypes.c_int32,
        ),
        "pancake_peer_session_is_open": ([P], ctypes.c_int32),
        "pancake_peer_release": ([P], None),
        "pancake_peer_feed_borrowed": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_peer_feed_owned": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_peer_step": ([P], ctypes.c_int32),
        "pancake_peer_recv_stream": ([P, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "pancake_peer_take_outbound": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_managed_frame_release": ([ctypes.POINTER(_ManagedFrame)], None),
        "pancake_peer_poll_event": ([P, ctypes.POINTER(_Event)], ctypes.c_int32),
        "pancake_event_release": ([ctypes.POINTER(_Event)], None),
        "pancake_peer_register_export": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_register_import": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_peek_event": ([P], ctypes.c_int32),
        "pancake_peer_send_deliver": (
            [P, ctypes.POINTER(_Reference), ctypes.POINTER(_Argument), ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint64],
            ctypes.c_int32,
        ),
        "pancake_peer_send_resolve": (
            [P, ctypes.c_uint64, ctypes.c_uint32, ctypes.POINTER(_Argument), ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_peer_poll_event_deliver": ([P, ctypes.POINTER(_Deliver)], ctypes.c_int32),
        "pancake_peer_poll_event_resolve": ([P, ctypes.POINTER(_Resolve)], ctypes.c_int32),
        "pancake_deliver_free": ([ctypes.POINTER(_Deliver)], None),
        "pancake_resolve_free": ([ctypes.POINTER(_Resolve)], None),
        "pancake_peer_register_bootstrap_cap": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_tcp_netlayer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_tcp_netlayer_release": ([P], None),
        "pancake_endpoint_tcp_testing_connect": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)],
            ctypes.c_int32,
        ),
        "pancake_endpoint_tcp_testing_listen": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint16, ctypes.POINTER(P)], ctypes.c_int32,
        ),
        "pancake_endpoint_tcp_listener_port": ([P, ctypes.POINTER(ctypes.c_uint16)], ctypes.c_int32),
        "pancake_endpoint_tcp_testing_accept": ([P, ctypes.c_uint32, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_endpoint_tcp_read_frame": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_endpoint_tcp_write_frame": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_endpoint_tcp_conn_close": ([P], None),
        "pancake_endpoint_tcp_listener_close": ([P], None),
    }
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
    return lib


_lib = _load()


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
    buf = (ctypes.c_uint8 * length)()
    _lib.pancake_last_error(buf, length)
    return bytes(buf[:length]).decode(errors="replace")


def clear_last_error() -> None:
    """Clear the calling thread's last error message."""
    _lib.pancake_clear_last_error()


class PancakeError(Exception):
    """A failed C ABI call, carrying the negative ``PANCAKE_ERR_*`` code.

    When a per-thread error message is available it is captured at raise time
    (the message is thread-local and may be overwritten by a later call) and
    shown by ``str(err)``.
    """

    def __init__(self, code: int, message: Optional[str] = None):
        if message:
            super().__init__(f"pancake error {code}: {message}")
        else:
            super().__init__(f"pancake error {code}")
        self.code = code
        self.message = message


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


@dataclass(frozen=True)
class Fulfill:
    value: Argument


@dataclass(frozen=True)
class Break:
    message: str


Resolution = Union[Fulfill, Break]


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
        sub = _REF_PROMISE_KIND if ref.promise else _REF_OBJECT
        return _Reference(_REF_NEAR, sub, ref.id)
    if isinstance(ref, Far):
        sub = _REF_PROMISE_KIND if ref.promise else _REF_OBJECT
        return _Reference(_REF_FAR, sub, ref.id)
    if isinstance(ref, Promise):
        return _Reference(_REF_PROMISE, 0, ref.answer)
    raise PancakeError(-13)  # sturdy/broken not carried on send


def _arg_to_c(value: Argument, keepalive: list) -> _Argument:
    a = _Argument()
    if isinstance(value, bool):  # before int — bool is an int subclass
        a.kind, a.boolean = _ARG_BOOLEAN, 1 if value else 0
    elif isinstance(value, int):
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
        raise PancakeError(-13)
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
    promise = r.sub_kind == _REF_PROMISE_KIND
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
    if a.kind == _ARG_STRING:
        return _bytes_from_c(a).decode()
    if a.kind == _ARG_SYMBOL:
        return Symbol(_bytes_from_c(a).decode())
    if a.kind == _ARG_REFERENCE:
        return _ref_from_c(a.reference)
    if a.kind == _ARG_LIST:
        return [_arg_from_c(a.items[i]) for i in range(a.items_len)]
    if a.kind == _ARG_SET:
        return Set(_arg_from_c(a.items[i]) for i in range(a.items_len))
    if a.kind == _ARG_TAGGED:
        return Tagged(_bytes_from_c(a).decode(), [_arg_from_c(a.items[i]) for i in range(a.items_len)])
    if a.kind == _ARG_KEYWORD:
        return Keyword(_bytes_from_c(a).decode())
    if a.kind == _ARG_VOID:
        return None
    raise PancakeError(-3)  # PANCAKE_ERR_INVALID_ARGUMENT: unrecognized arg kind


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
        _check(_lib.pancake_context_new_default(ctypes.byref(out)))
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


class Peer:
    """An OCapN/CapTP peer. Use as a context manager, or call :meth:`release`."""

    def __init__(self):
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new(ctypes.byref(ptr)))
        self._raw = ptr

    @classmethod
    def new_in(cls, context: "Context") -> "Peer":
        """Create a peer whose allocations route through ``context``. The context
        must outlive the peer."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_in(context._raw, ctypes.byref(ptr)))
        self._raw = ptr
        return self

    @classmethod
    def new_negotiating(cls) -> "Peer":
        """A negotiating peer, awaiting the keyed ``op:start-session`` handshake —
        the peer to drive when the partner requires it (a real Goblins vat). Pair
        it with :meth:`start_session_keyed`, then pump until :meth:`session_is_open`."""
        self = cls.__new__(cls)
        ptr = ctypes.c_void_p()
        _check(_lib.pancake_peer_new_negotiating(ctypes.byref(ptr)))
        self._raw = ptr
        return self

    def __enter__(self) -> "Peer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _lib.pancake_peer_release(self._raw)
            self._raw = None

    def __del__(self):
        self.release()

    def register_export(self, export_id: int) -> None:
        _check(_lib.pancake_peer_register_export(self._raw, export_id))

    def register_import(self, import_id: int) -> None:
        _check(_lib.pancake_peer_register_import(self._raw, import_id))

    def start_session_keyed(
        self,
        seed: bytes,
        *,
        transport: str = "tcp",
        designator: str,
        hints_empty_false: bool = True,
        version: str = "v1.0",
    ) -> None:
        """Sign and queue a keyed ``op:start-session`` from this negotiating peer.
        The 32-byte ``seed`` is the session key; ``transport``/``designator`` form
        the locator the partner verifies, so they must be what it expects — for a
        Goblins partner, ``"tcp"`` with ``hints_empty_false`` true (an empty hints
        map encoded as ``#f``). ``version`` is ``"v1.0"`` or ``"pre-spec"``. Flush
        it, then pump until :meth:`session_is_open`."""
        if len(seed) != 32:
            raise ValueError("a session seed must be 32 bytes")
        transport_b = transport.encode()
        designator_b = designator.encode()
        _check(_lib.pancake_peer_start_session_keyed(
            self._raw,
            1 if version == "pre-spec" else 0,
            transport_b, len(transport_b),
            designator_b, len(designator_b),
            1 if hints_empty_false else 0,
            seed,
        ))

    def session_is_open(self) -> bool:
        """Whether the keyed handshake has completed and the session is open for
        traffic. Pump the connection and poll this before sending application
        messages."""
        rc = _lib.pancake_peer_session_is_open(self._raw)
        if rc < 0:
            raise PancakeError(rc)
        return rc == 1

    def feed(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check(_lib.pancake_peer_feed_borrowed(self._raw, ctypes.byref(f)))

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
            err = PancakeError(rc, last_error())
            state.pop("buf", None)
            _owned_frame_callbacks.pop(id(release_cb), None)
            raise err

    def step(self) -> None:
        _check(_lib.pancake_peer_step(self._raw))

    def recv_stream(self, data: bytes) -> Optional[int]:
        """Frame and dispatch one whole frame out of a streamed read buffer.

        Returns the number of bytes consumed when a whole frame was framed and
        dispatched, ``None`` when ``data`` holds only a partial frame (read more
        and retry with the larger buffer), and raises :class:`PancakeError` on a
        fatal framing or dispatch error (malformed, frame too large, …).
        """
        n = len(data)
        buf = (ctypes.c_uint8 * n).from_buffer_copy(data) if n else (ctypes.c_uint8 * 0)()
        ptr = ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8))
        consumed = ctypes.c_size_t(0)
        rc = _lib.pancake_peer_recv_stream(self._raw, ptr, n, ctypes.byref(consumed))
        if rc == _OK:
            return consumed.value
        if rc == _WOULD_BLOCK:
            return None
        # Capture the thread-local message now, before any later call clobbers it.
        raise PancakeError(rc, last_error())

    def register_bootstrap_cap(self, swissnum: bytes) -> int:
        buf = ctypes.create_string_buffer(swissnum, len(swissnum))
        out = ctypes.c_uint64()
        _check(_lib.pancake_peer_register_bootstrap_cap(self._raw, ctypes.cast(buf, ctypes.c_void_p), len(swissnum), ctypes.byref(out)))
        return out.value

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
        if _lib.pancake_peer_take_outbound(self._raw, ctypes.byref(frame)) != _OK:
            return None
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def poll(self) -> Optional[Event]:
        kind = _lib.pancake_peer_peek_event(self._raw)
        if kind == _EVENT_DELIVER:
            return self._poll_deliver()
        if kind == _EVENT_RESOLVE:
            return self._poll_resolve()
        if kind == _WOULD_BLOCK:
            return None
        return self._poll_other()

    def _poll_deliver(self) -> Deliver:
        d = _Deliver()
        _check(_lib.pancake_peer_poll_event_deliver(self._raw, ctypes.byref(d)))
        event = Deliver(
            target=_ref_from_c(d.target),
            args=[_arg_from_c(d.args[i]) for i in range(d.args_len)],
            answer=d.answer if d.has_answer else None,
        )
        _lib.pancake_deliver_free(ctypes.byref(d))
        return event

    def _poll_resolve(self) -> Resolve:
        r = _Resolve()
        _check(_lib.pancake_peer_poll_event_resolve(self._raw, ctypes.byref(r)))
        if r.resolution_kind == _RESOLUTION_FULFILL:
            resolution: Resolution = Fulfill(_arg_from_c(r.fulfill))
        else:
            msg = ctypes.string_at(r.break_message, r.break_message_len).decode() if r.break_message else ""
            resolution = Break(msg)
        event = Resolve(answer=r.answer, resolution=resolution)
        _lib.pancake_resolve_free(ctypes.byref(r))
        return event

    def _poll_other(self) -> Other:
        e = _Event()
        _lib.pancake_peer_poll_event(self._raw, ctypes.byref(e))
        frame = ctypes.string_at(e.frame.bytes, e.frame.len) if e.frame.bytes else b""
        kind = e.kind
        _lib.pancake_event_release(ctypes.byref(e))
        return Other(kind=kind, frame=frame)


# ── Actors ───────────────────────────────────────────────────────────────────
#
# This is pancake's Goblins-shaped actor model in Python, the seam where the
# actor layer meets the OCapN peer. It mirrors the Zig ``actors.vat`` and the
# Racket binding's actor section in idiomatic Python: callables for behaviors,
# exceptions for broken resolutions, dataclasses for the unified reference and
# promise.
#
# An actor is a callable ``behavior(verb, args) -> value``. It returns a reply
# value, or raises to break the resolution. A :class:`Ref` names an object the
# vat can eventual-send to, wherever it lives: a local actor in this vat, or a
# far object the bound peer holds as an import. :meth:`Vat.call` is the
# synchronous near-call and is local-only; :meth:`Vat.send` is the
# location-transparent eventual-send and routes by where the ref lives.


@dataclass(frozen=True)
class Ref:
    """A reference the vat can eventual-send to, wherever the object lives.

    A *local* ref names an actor in this vat; :meth:`Vat.call` and
    :meth:`Vat.send` run its turns here. A *far* ref wraps a :class:`Far`
    import the bound peer holds; :meth:`Vat.send` routes to it as an
    ``op:deliver`` and :meth:`Vat.call` (near) is illegal.
    """

    local_id: Optional[int] = None
    far: Optional[Far] = None
    # The wire reference this marshals to when handed to a partner as a capability
    # argument. A locally-spawned actor carries a `Near` (our export); set by the
    # :class:`Connection` layer. The vat itself never reads this.
    near: Optional[Near] = None

    @classmethod
    def local(cls, actor_id: int) -> "Ref":
        """A reference to a local actor by its vat id."""
        return cls(local_id=actor_id)

    @classmethod
    def to(cls, far: Far) -> "Ref":
        """A reference to a partner-hosted object the peer holds as an import."""
        return cls(far=far)

    @property
    def is_local(self) -> bool:
        return self.local_id is not None

    def _wire(self) -> Reference:
        """The wire reference to marshal this capability to in a `send` argument:
        a local actor's `Near` export, else the `Far` import it names."""
        if self.near is not None:
            return self.near
        if self.far is not None:
            return self.far
        raise PancakeError(-13, "this ref has no wire reference to marshal")


class VowBroken(Exception):
    """Raised when an awaited vow settles broken; the message is the break reason."""


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
    # Excluded from equality/repr — two vows are the same by position, not vat.
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


@dataclass
class _Listener:
    """A one-shot promise listener: at most one of ``on_fulfilled`` /
    ``on_broken`` fires when the vow settles."""

    on_fulfilled: Optional[object] = None
    on_broken: Optional[object] = None


class Vat:
    """A turn loop over a heap of actors, local and remote alike.

    A vat owns local actors (callables ``behavior(verb, args) -> value``), a
    queue of pending local eventual-sends, listeners for local and far vows, and
    — when bound to a peer — an export map so inbound deliveries run published
    actors. You drive it; it owns no I/O and no scheduler thread.

    A pure-local vat (``Vat()``) sends and drives over local actors only. A vat
    bound to a peer (``Vat(peer)``) also routes far sends out as ``op:deliver``
    and serves inbound peer events through :meth:`serve`.
    """

    # Far sends allocate their own outbound answer positions (the C ABI has no
    # answer allocator). Start high so they never collide with answers a test or
    # an application picks by hand for inbound deliveries.
    _FAR_ANSWER_BASE = 1000

    def __init__(self, peer: Optional[Peer] = None):
        self._peer = peer
        self._actors: dict = {}
        self._exports: dict = {}  # export id -> local actor id
        self._listeners: dict = {}  # local vow id -> _Listener
        self._far_listeners: dict = {}  # far answer -> _Listener
        self._queue: list = []  # pending local sends: (actor_id, verb, args, vow_id)
        self._next_actor = 1
        self._next_vow = 1
        self._next_answer = self._FAR_ANSWER_BASE

    @property
    def peer(self) -> Optional[Peer]:
        """The bound peer — to feed/step/take_outbound around :meth:`serve`."""
        return self._peer

    def spawn(self, behavior) -> Ref:
        """Spawn a local actor with ``behavior``, returning a local :class:`Ref`."""
        actor_id = self._next_actor
        self._next_actor += 1
        self._actors[actor_id] = behavior
        return Ref.local(actor_id)

    def call(self, ref: Ref, verb: str, args: Optional[list] = None):
        """The synchronous near-call (``$``): run ``ref``'s handler now and
        return its value. Legal only for a *local* ref — a far ref raises, since
        only :meth:`send` reaches one. Raises if no such actor exists, or
        propagates whatever the behavior itself raises."""
        if not ref.is_local:
            raise PancakeError(-13, "cannot near-call a far ref; use send")
        behavior = self._actors.get(ref.local_id)
        if behavior is None:
            raise KeyError(f"no such actor: {ref.local_id}")
        return behavior(verb, list(args or []))

    def send(self, ref: Ref, verb: str, args: Optional[list] = None) -> Vow:
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
            raise PancakeError(-13, "this vat has no peer; far sends need Vat(peer)")
        answer = self._next_answer
        self._next_answer += 1
        payload = [Symbol(verb), *rest] if verb else rest
        self._peer.send_deliver(ref.far, payload, answer=answer)
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
                resolution: Resolution = Fulfill(self.call(Ref.local(actor_id), verb, args))
            except Exception as error:  # noqa: BLE001 — a raise breaks the resolution
                resolution = Break(str(error))
            self._settle_local(vow_id, resolution)
        self._queue.clear()

    def publish(self, export_id: int, behavior) -> Ref:
        """Spawn ``behavior`` and publish it at ``export_id`` so a partner's
        deliveries to that export run the actor (dispatched by :meth:`serve`).
        Requires a bound peer. Returns the new local :class:`Ref`."""
        if self._peer is None:
            raise PancakeError(-13, "this vat has no peer; publish needs Vat(peer)")
        ref = self.spawn(behavior)
        self._peer.register_export(export_id)
        self._exports[export_id] = ref.local_id
        return ref

    def serve(self, event: Event) -> bool:
        """Dispatch one inbound peer event. A deliver to a published export runs
        its actor (a leading :class:`Symbol` is the verb) and resolves the
        answer with the reply (a break if the actor raised). A resolve for a
        pending far vow fires its listener. Returns whether the event belonged
        to this vat — ``False`` means the caller handles it."""
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
            resolution: Resolution = Fulfill(self.call(Ref.local(actor_id), verb, rest))
        except Exception as error:  # noqa: BLE001 — broken resolution carries the message
            resolution = Break(str(error))
        if event.answer is not None and self._peer is not None:
            self._peer.send_resolve(event.answer, resolution)
        return True

    def _serve_resolve(self, event: Resolve) -> bool:
        listener = self._far_listeners.pop(event.answer, None)
        if listener is None:
            return False
        self._fire(listener, event.resolution)
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


class AsyncConnection:
    """An OCapN/CapTP peer driven asynchronously over an asyncio TCP stream.

    The sync :class:`Peer` is sans-io — it never blocks and never owns a socket.
    This wraps an :class:`asyncio.StreamReader`/:class:`asyncio.StreamWriter`
    pair and *drives* the peer over it: read bytes, let the peer frame and
    dispatch them (:meth:`Peer.recv_stream`), write the peer's outbound frames
    back, and surface events.

    The peer is a single-owner state machine: one ``AsyncConnection`` owns one
    peer and must be driven from a single task. Use as an ``async with`` context
    manager, or call :meth:`aclose`.
    """

    _READ_CHUNK = 65536

    def __init__(self, peer: Peer, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter"):
        self._peer = peer
        self._reader = reader
        self._writer = writer
        self._vat: Optional[Vat] = None
        # Inbound bytes read from the wire but not yet framed into whole frames.
        self._inbox = bytearray()

    @classmethod
    async def connect(cls, host: str, port: int) -> "AsyncConnection":
        """Connect to ``host:port`` and wrap a fresh peer driven over it."""
        reader, writer = await asyncio.open_connection(host, port)
        return cls(Peer(), reader, writer)

    @classmethod
    def from_stream(cls, peer: Peer, reader: "asyncio.StreamReader", writer: "asyncio.StreamWriter") -> "AsyncConnection":
        """Wrap an already-connected stream pair and a peer you have configured
        (registered exports/imports, bootstrap caps, …)."""
        return cls(peer, reader, writer)

    @property
    def peer(self) -> Peer:
        """The owned peer — e.g. to register exports/imports before driving."""
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
        """Await the next application event, driving the socket as needed.
        Returns ``None`` on a clean end of stream."""
        while True:
            # A surfaced event takes priority.
            event = self._peer.poll()
            if event is not None:
                return event
            # Flush anything the last dispatch queued (replies, aborts).
            await self._pump_outbound()
            # Consume every whole frame already buffered; each may surface an
            # event or queue outbound, so loop back to re-check.
            consumed_any = False
            while True:
                consumed = self._peer.recv_stream(bytes(self._inbox))
                if consumed is None:
                    break  # only a partial frame buffered — read more
                del self._inbox[:consumed]
                consumed_any = True
            if consumed_any:
                continue
            # Need more bytes from the wire.
            chunk = await self._reader.read(self._READ_CHUNK)
            if chunk == b"":
                return None  # clean EOF
            self._inbox.extend(chunk)

    async def _pump_outbound(self) -> None:
        """Encode pending outbound work and write every queued frame, then flush."""
        self._peer.step()
        while (frame := self._peer.take_outbound()) is not None:
            self._writer.write(frame)
        await self._writer.drain()

    async def aclose(self) -> None:
        """Close the writer and release the owned peer."""
        if self._writer is not None:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except (OSError, asyncio.CancelledError):
                pass
            self._writer = None
        self._peer.release()

    async def __aenter__(self) -> "AsyncConnection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()


CODEC_SYRUP = 0


def _host_buf(host: str):
    data = host.encode()
    buf = ctypes.create_string_buffer(data, len(data))
    return buf, len(data)


class Conn:
    """A blocking TCP connection. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "Conn":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _lib.pancake_endpoint_tcp_conn_close(self._raw)
            self._raw = None

    def read_frame(self) -> bytes:
        """Block for one whole frame. Raises PancakeError(-8) on clean EOF."""
        frame = _ManagedFrame()
        _check(_lib.pancake_endpoint_tcp_read_frame(self._raw, ctypes.byref(frame)))
        out = ctypes.string_at(frame.bytes, frame.len)
        _lib.pancake_managed_frame_release(ctypes.byref(frame))
        return out

    def write_frame(self, frame: bytes) -> None:
        buf = ctypes.create_string_buffer(frame, len(frame))
        f = _Frame(ctypes.cast(buf, ctypes.c_void_p), len(frame), _FRAME_SHAPE_BYTE)
        _check(_lib.pancake_endpoint_tcp_write_frame(self._raw, ctypes.byref(f)))


class Listener:
    """A bound TCP listener. Closed on release / context exit."""

    def __init__(self, raw):
        self._raw = raw

    def __enter__(self) -> "Listener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        if self._raw:
            _lib.pancake_endpoint_tcp_listener_close(self._raw)
            self._raw = None

    def port(self) -> int:
        out = ctypes.c_uint16()
        _check(_lib.pancake_endpoint_tcp_listener_port(self._raw, ctypes.byref(out)))
        return out.value

    def accept(self, codec: int = CODEC_SYRUP, max_frame_bytes: int = 4096) -> Conn:
        out = ctypes.c_void_p()
        _check(_lib.pancake_endpoint_tcp_testing_accept(self._raw, codec, max_frame_bytes, ctypes.byref(out)))
        return Conn(out)


class Netlayer:
    """Owns the blocking-TCP I/O backend; outlives the endpoints made from it."""

    def __init__(self):
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_netlayer_new(ctypes.byref(out)))
        self._raw = out

    @classmethod
    def new_in(cls, context: "Context") -> "Netlayer":
        """Create a netlayer whose backend and per-connection buffers allocate
        through ``context``. The context must outlive the netlayer."""
        self = cls.__new__(cls)
        out = ctypes.c_void_p()
        _check(_lib.pancake_tcp_netlayer_new_in(context._raw, ctypes.byref(out)))
        self._raw = out
        return self

    def __enter__(self) -> "Netlayer":
        return self

    def __exit__(self, *exc) -> None:
        self.release()

    def release(self) -> None:
        if self._raw:
            _lib.pancake_tcp_netlayer_release(self._raw)
            self._raw = None

    def listen(self, host: str, port: int = 0) -> Listener:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check(_lib.pancake_endpoint_tcp_testing_listen(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, ctypes.byref(out)))
        return Listener(out)

    def connect(self, host: str, port: int, codec: int = CODEC_SYRUP, max_frame_bytes: int = 4096) -> Conn:
        buf, n = _host_buf(host)
        out = ctypes.c_void_p()
        _check(_lib.pancake_endpoint_tcp_testing_connect(self._raw, ctypes.cast(buf, ctypes.c_void_p), n, port, codec, max_frame_bytes, ctypes.byref(out)))
        return Conn(out)


# ── Connection: the application surface ──────────────────────────────────────
#
# This is what an application holds. It composes a peer, a vat, and the asyncio
# I/O driver into one object, so a consumer never stitches those three together
# by hand. The verbs — ``connect``/``listen``, ``fetch``/``publish``, ``spawn``,
# ``send``, ``serve``, ``close`` — are the whole common surface. The raw
# :class:`Peer`, :class:`Vat`, and :class:`AsyncConnection` remain for power
# users (reach ``conn.peer``), but no application needs them.

_BOOTSTRAP_POSITION = 0
_FIRST_SPAWN_POSITION = 32


def _is_wire_reference(value: object) -> bool:
    return isinstance(value, (Near, Far, Promise, Sturdy, Broken))


def _local_designator(writer: "asyncio.StreamWriter") -> str:
    """The ``host:port`` of this socket's own end — the locator a peer signs in
    its keyed start-session."""
    host, port, *_ = writer.get_extra_info("sockname")
    return f"{host}:{port}"


async def _open_keyed_session(ac: "AsyncConnection", designator: str) -> None:
    """Complete the keyed ``op:start-session`` handshake over a negotiating peer:
    sign a ``tcp`` locator naming ``designator`` with a per-connection random
    session key, flush it, and pump until the partner's start-session opens the
    session. Entropy is generated here, at the I/O boundary, never in the sans-io
    core. Signing the socket's real local address keeps the locator a true ``tcp``
    locator, which a Goblins partner accepts."""
    ac.peer.start_session_keyed(secrets.token_bytes(32), designator=designator)
    await ac.flush()
    while not ac.peer.session_is_open():
        if await ac.next_event() is None:
            raise PancakeError(-8, "connection closed during the OCapN handshake")


class Connection:
    """A live connection to one OCapN partner — the one object an app holds.

        conn = await connect("127.0.0.1", 9099)
        conn.serve()
        board = await conn.fetch("board")
        inbox = conn.spawn(lambda verb, args: None)
        await conn.send(board, "watch", [inbox])
    """

    def __init__(self, ac: AsyncConnection):
        self._ac = ac
        self._vat = ac.vat()
        self._next_spawn = _FIRST_SPAWN_POSITION
        self._serve_task: Optional[asyncio.Task] = None
        self._closing = False

    @classmethod
    async def connect(cls, host: str, port: int) -> "Connection":
        """Dial ``host:port``, complete the keyed OCapN handshake, and return a
        ready connection. The session is open before this resolves, so a
        ``fetch``/``send`` rides an established session — the same handshake a
        real Goblins peer requires."""
        reader, writer = await asyncio.open_connection(host, port)
        ac = AsyncConnection.from_stream(Peer.new_negotiating(), reader, writer)
        await _open_keyed_session(ac, _local_designator(writer))
        return cls(ac)

    @classmethod
    async def _accept(cls, reader, writer) -> "Connection":
        """Wrap an accepted stream and complete the keyed handshake from the
        responder side. Resolves once the session is open."""
        ac = AsyncConnection.from_stream(Peer.new_negotiating(), reader, writer)
        await _open_keyed_session(ac, _local_designator(writer))
        return cls(ac)

    @property
    def peer(self) -> Peer:
        """The underlying sans-io peer — the escape hatch for handoff, pipelining,
        and session control. Applications do not need it."""
        return self._ac.peer

    def spawn(self, behavior) -> Ref:
        """Spawn a local actor and return a capability to it. Pass the returned
        :class:`Ref` as a ``send`` argument to hand a partner a callback."""
        position = self._next_spawn
        self._next_spawn += 1
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def publish(self, name: str, behavior) -> Ref:
        """Publish an actor so a partner can :meth:`fetch` it by ``name``. The
        name is a swiss-number: readable for a discoverable service, a secret
        where the name itself is the authorization."""
        position = self._ac.peer.register_bootstrap_cap(name.encode())
        local = self._vat.publish(position, self._wrap(behavior))
        return Ref(local_id=local.local_id, near=Near(position))

    def _settle(self, vow) -> "asyncio.Future":
        """Register a listener on ``vow`` now and return a future it settles. The
        listener must be registered before any pump (``drive``/``flush``): a local
        ``drive`` fires synchronously, and a far reply can land on the serve loop
        the instant ``flush`` yields — either would settle before a later ``await``
        could subscribe."""
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
        """Fetch a partner's published capability by ``name``. Requires
        :meth:`serve` to be running so the resolution arrives."""
        self._ac.peer.register_import(_BOOTSTRAP_POSITION)
        vow = self._vat.send(Ref.to(Far(_BOOTSTRAP_POSITION)), "fetch", [name.encode()])
        future = self._settle(vow)
        await self._ac.flush()
        result = await future
        if not _is_wire_reference(result):
            raise PancakeError(-13, f'fetch("{name}") did not resolve to a capability')
        return Ref(far=result) if isinstance(result, Far) else Ref(near=result)

    async def send(self, target: Ref, verb: str, args: Optional[list] = None):
        """Call ``verb(args)`` on the capability ``target`` and await the reply.
        Flushes immediately. ``args`` may contain :class:`Ref`s. Raises
        :class:`VowBroken` if the partner breaks the call."""
        wire_args = [self._lower(a) for a in (args or [])]
        vow = self._vat.send(target, verb, wire_args)
        future = self._settle(vow)
        if target.local_id is not None:
            self._vat.drive()
        else:
            await self._ac.flush()
        return self._lift(await future)

    async def tell(self, target: Ref, verb: str, args: Optional[list] = None) -> None:
        """Fire-and-forget eventual-send (Goblins ``<-np``): no answer is
        allocated and no reply comes back, so a notification or broadcast costs
        one deliver rather than a deliver plus a reply. Flushes immediately."""
        wire_args = [self._lower(a) for a in (args or [])]
        if target.local_id is not None:
            self._vat.send(target, verb, wire_args)
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
                self._vat.serve(event)
        except (asyncio.CancelledError, OSError):
            if not self._closing:
                raise
        finally:
            self._vat.break_far_vows("connection closed")

    async def close(self) -> None:
        """Close the connection; a running :meth:`serve` completes cleanly."""
        self._closing = True
        await self._ac.aclose()
        if self._serve_task is not None:
            try:
                await self._serve_task
            except (asyncio.CancelledError, OSError):
                pass

    async def __aenter__(self) -> "Connection":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.close()

    def _wrap(self, behavior):
        def wrapped(verb: str, raw_args: list):
            result = behavior(verb, [self._lift(a) for a in raw_args])
            return None if result is None else self._lower(result)
        return wrapped

    @staticmethod
    def _lower(value):
        if isinstance(value, Ref):
            return value._wire()
        if isinstance(value, list):
            return [Connection._lower(v) for v in value]
        return value

    @staticmethod
    def _lift(value):
        if isinstance(value, Far):
            return Ref(far=value)
        if isinstance(value, Near):
            return Ref(near=value)
        if isinstance(value, list):
            return [Connection._lift(v) for v in value]
        return value


async def connect(host: str, port: int) -> Connection:
    """Dial ``host:port`` and return a ready connection — the module-level
    shorthand for :meth:`Connection.connect`."""
    return await Connection.connect(host, port)


async def listen(host: str, port: int):
    """Accept connections: ``async for conn in listen(host, port): ...``. Each
    yielded :class:`Connection` is one accepted partner — publish capabilities on
    it and call :meth:`Connection.serve`."""
    queue: asyncio.Queue = asyncio.Queue()
    server = await asyncio.start_server(
        lambda r, w: queue.put_nowait((r, w)), host, port,
    )
    try:
        while True:
            reader, writer = await queue.get()
            yield await Connection._accept(reader, writer)
    finally:
        server.close()
