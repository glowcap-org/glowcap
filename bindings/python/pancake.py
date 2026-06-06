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
from dataclasses import dataclass, field
from typing import Optional, Union

_LIB = pathlib.Path(__file__).resolve().parents[2] / "zig-out" / "lib" / "libpancake.so"

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
        _lib.pancake_peer_poll_event_deliver(self._raw, ctypes.byref(d))
        event = Deliver(
            target=_ref_from_c(d.target),
            args=[_arg_from_c(d.args[i]) for i in range(d.args_len)],
            answer=d.answer if d.has_answer else None,
        )
        _lib.pancake_deliver_free(ctypes.byref(d))
        return event

    def _poll_resolve(self) -> Resolve:
        r = _Resolve()
        _lib.pancake_peer_poll_event_resolve(self._raw, ctypes.byref(r))
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

    async def send_deliver(self, target: Reference, args: list, answer: Optional[int] = None) -> None:
        """Queue a call to ``target`` and flush it to the wire. ``answer``
        requests a reply."""
        self._peer.send_deliver(target, args, answer)
        await self._pump_outbound()

    async def send_resolve(self, answer: int, resolution: Resolution) -> None:
        """Queue a reply settling ``answer`` and flush it to the wire."""
        self._peer.send_resolve(answer, resolution)
        await self._pump_outbound()

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
