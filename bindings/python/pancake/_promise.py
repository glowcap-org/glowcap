"""Internal: the :class:`RemotePromise` a Session send returns — lazy
observation, promise pipelining target, and ``index``/``untag``/``get``
projection (ADR-0007 / ADR-0050 / ADR-0052). Also the shared fetch/enliven
mint→await→classify path (``_await_minted`` / ``_fetch_like``), the far-send
mint→``_promise_for`` path (``_send_far``), and RemotePromise construction.
Session owns CapTP verb wrappers; trampoline owns near/far send·tell
dispatch and local arms; this module owns the handle type, far-send /
post-mint choreography, and the projection FFI.
"""

from __future__ import annotations

import asyncio
import ctypes
from dataclasses import dataclass
from typing import Optional, Union

from . import _constants as _abi
from ._codec import _args_to_c, _ref_to_c
from ._errors import FetchFailed, PancakeError, _check_host
from ._ffi_driver import _host
from ._ffi_ocapn import _byte_buf
from ._value import Far, Near, Ref, _lift_value, _lower_value

_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE


async def _await_minted(session, vow: int):
    # The shared fetch/enliven wait: register the vow, keep the inbound
    # loop running (the completion's bytes arrive on it), kick the drain so
    # the deliver leaves now, and await the drain-routed outcome.
    session.host.vow_minted(vow, session)
    session.serve()
    settled = session.host.await_vow(vow)
    await session.host.kick_actions()
    return await settled


async def _fetch_like(session, swiss: bytes, label: str, mint, track: bool) -> Ref:
    # The one mint/await/classify body under `fetch` and `enliven`: mint
    # the host vow with `mint`, await its drain-routed completion, and
    # classify — only a near/far reference is a live capability this
    # surface can hand out; anything else would leak a half-supported
    # kind, so the call fails instead. `track` marks the Far arm for
    # distributed GC: a fetch's import is finalizer-tracked, an enliven's
    # is owned by the ADR-0012 dedup cache instead (ADR-0063).
    session.guard_open()
    session.gc.drain_gc()
    buf, ptr = _byte_buf(swiss)
    out = ctypes.c_uint64()
    _check_host(mint(session.raw, ptr, len(swiss), ctypes.byref(out)))
    result = await _await_minted(session, out.value)
    if isinstance(result, Near):
        return Ref(result)
    if not isinstance(result, Far):
        raise FetchFailed(label)
    ref = Ref(result)
    return session.gc.track_import(ref) if track else ref


def _promise_for(session, vow: int) -> RemotePromise:
    # The RemotePromise over a freshly minted host vow: observation kicks
    # the drain (the flush that puts the queued batch on the wire) and
    # awaits the drain-routed completion; projections mint sibling vows at
    # the answer.
    async def begin():
        session.serve()  # the settle's bytes arrive on the inbound loop
        settled = session.host.await_vow(vow)
        await session.host.kick_actions()
        return _lift_value(await settled)

    def project(op: str, key) -> RemotePromise:
        out = ctypes.c_uint64()
        if op == "index":
            _check_host(_host.pancake_host_vow_index(
                session.host.raw, vow, int(key), ctypes.byref(out),
            ))
        else:
            field = str(key).encode()
            fbuf, fptr = _byte_buf(field)
            fn = _host.pancake_host_vow_get if op == "get" else _host.pancake_host_vow_untag
            _check_host(fn(
                session.host.raw, vow, fptr, len(field), ctypes.byref(out),
            ))
        projected = out.value
        session.host.vow_minted(projected, session)
        return _promise_for(session, projected)

    return RemotePromise.far(vow, begin, project)


class PromiseState:
    """Sum state for :class:`RemotePromise`: ``Far`` (host vow), ``Local``, or
    ``Failed`` (the send never left). Discriminant is the arm type — not a
    nullable vow field."""

    @dataclass(frozen=True, slots=True)
    class Far:
        vow: int
        tag: str = "far"

    @dataclass(frozen=True, slots=True)
    class Local:
        tag: str = "local"

    @dataclass(frozen=True, slots=True)
    class Failed:
        """A send that could not be issued at all — a closed session, an
        argument that would not lower. It is a state rather than a raised
        exception because ``send`` must return its handle synchronously, so
        pipelining can project at the answer before it settles (ADR-0050).
        Raising instead put a synchronous failure channel on an awaitable, and
        a comprehension building sends raised before ``gather`` was ever
        entered, so ``return_exceptions`` could not help."""

        error: BaseException
        tag: str = "failed"

    Kind = Union["PromiseState.Far", "PromiseState.Local", "PromiseState.Failed"]

    @staticmethod
    def far(vow: int) -> "PromiseState.Far":
        return PromiseState.Far(vow)

    @staticmethod
    def local() -> "PromiseState.Local":
        return PromiseState.Local()

    @staticmethod
    def failed(error: BaseException) -> "PromiseState.Failed":
        return PromiseState.Failed(error)


class RemotePromise(asyncio.Future):
    """The handle :meth:`Session.send` returns: the eventual result of one
    eventual-send, and -- the point of promise pipelining (ADR-0007) -- a target
    you can ``send`` to before it resolves.

    It is a real :class:`asyncio.Future`, so ``await conn.send(...)``,
    ``asyncio.gather(...)``, and ``isinstance(_, asyncio.Future)`` all work
    natively. Pass it *unawaited* as the ``target`` of a later ``send`` to
    address the object the answer will resolve to: the dependent call rides a
    ``desc:answer`` deliver and the partner queues it until the answer settles,
    so a ``create -> use`` chain costs one round trip::

        task = conn.send(root, "create", ["x"])       # not awaited
        conn.send(task, "assign", ["alice"])          # pipelined at the answer
        status = await conn.send(task, "status", [])  # settles the chain

    The send is queued when this is created, but its bytes leave the wire only
    when this -- or any send pipelined behind it -- is first observed: awaited,
    or registered with a done callback, which is how ``asyncio.gather`` /
    ``wait`` / ``shield`` observe a future, so a gathered handle settles too.
    A pipelined batch therefore travels together. A handle that is never
    observed is a fire-and-forget send; prefer :meth:`Session.tell` for
    that. Because the
    settle is drain-routed and no exception is materialized until the handle is
    observed, an unobserved anchor whose far answer *breaks* stays silent. Like
    any ``asyncio.Future``, construct it within a running event loop (``send``
    is always called from one). State is a sum (``far`` | ``local``), not a
    nullable vow flag.

    The projection verbs :meth:`index` / :meth:`untag` / :meth:`get`
    (ADR-0050/ADR-0052) pipeline an element, untag, or Struct-field access *at
    the answer*, before it resolves: each returns a new :class:`RemotePromise`
    for the projected value.
    """

    def __init__(self, kind: PromiseState.Kind, begin, project=None) -> None:
        # The future is created empty -- no flush runs here, so construction is
        # side-effect-free and the send stays lazy.
        super().__init__()
        # Not `_state`: asyncio.Future owns that name for PENDING/FINISHED.
        self._kind = kind
        self._begin = begin
        # Issues a projection op (index/untag/get) at this vow; set only for far.
        self._project = project
        self._started = False
        # The begin task, retained: the event loop holds tasks only weakly, so
        # an unreferenced begin could be collected mid-flight.
        self._begin_task: "Optional[asyncio.Future]" = None

    @classmethod
    def far(cls, vow: int, begin, project) -> "RemotePromise":
        return cls(PromiseState.far(vow), begin, project)

    @classmethod
    def local(cls, begin) -> "RemotePromise":
        return cls(PromiseState.local(), begin, None)

    @classmethod
    def failed(cls, error: BaseException) -> "RemotePromise":
        """A handle for a send that never left: awaiting it raises ``error``,
        and projecting at it yields another failed handle carrying the same
        reason, so a pipeline built behind a dead anchor fails where it is
        awaited rather than where it was written."""

        async def _raise():
            raise error

        return cls(PromiseState.failed(error), _raise, None)

    @property
    def vow(self) -> Optional[int]:
        """Host vow when far; ``None`` when local (convenience, not the discriminant)."""
        return self._kind.vow if isinstance(self._kind, PromiseState.Far) else None

    def far_vow(self) -> int:
        """The host vow for pipelining, or a typed refusal when this is local."""
        # A failed handle keeps its own reason rather than reporting the
        # generic local-send refusal, so a caller sees why the send never left.
        if isinstance(self._kind, PromiseState.Failed):
            raise self._kind.error
        if not isinstance(self._kind, PromiseState.Far):
            raise PancakeError(
                _ERR_UNSUPPORTED_VALUE,
                "cannot pipeline against a local-send promise; await it for a Ref",
            )
        return self._kind.vow

    def _project_op(self, op: str, key) -> "RemotePromise":
        # A pipeline behind a send that never left is itself a send that never
        # left. Carrying the same reason forward means the whole chain fails
        # where it is awaited rather than raising at the link that was written.
        if isinstance(self._kind, PromiseState.Failed):
            return RemotePromise.failed(self._kind.error)
        if not isinstance(self._kind, PromiseState.Far) or self._project is None:
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

    def get(self, field: str) -> "RemotePromise":
        """Pipeline an ``op:get`` for ``field`` at this answer (ADR-0050): a new
        :class:`RemotePromise` for the Struct field of whatever this resolves
        to."""
        return self._project_op("get", field)

    def _ensure_started(self) -> None:
        # First observation schedules the send's flush + reply wait, exactly
        # once, and chains its outcome onto this future. Observation is an
        # ``await`` or a Future-protocol registration (``add_done_callback``,
        # below). An unobserved handle never starts ``begin``, so its answer
        # breaking never settles us.
        if not self._started:
            self._started = True
            task = asyncio.ensure_future(self._begin())
            self._begin_task = task
            task.add_done_callback(self._chain)

    def __await__(self):
        self._ensure_started()
        return super().__await__()

    __iter__ = __await__  # `yield from` compatibility, mirroring asyncio.Future

    def add_done_callback(self, callback, *, context=None) -> None:
        # The Future-protocol observation path: ``asyncio.gather`` / ``wait`` /
        # ``shield`` never call ``__await__`` on a child, they register a done
        # callback — so registering interest is what starts the send.
        self._ensure_started()
        if context is None:
            super().add_done_callback(callback)
        else:
            super().add_done_callback(callback, context=context)

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


def _send_far(session, target, verb: str, args: list) -> RemotePromise:
    # Far-send mint→RemotePromise: encode args, mint the host vow
    # (conn_send / vow_send), register it, and hand back _promise_for.
    # Local-hosted targets stay in Session (trampoline _send_local).
    verb_bytes = verb.encode()
    vbuf, vptr = _byte_buf(verb_bytes)
    keepalive: list = []
    arr, count = _args_to_c([_lower_value(a) for a in args], keepalive)
    out = ctypes.c_uint64()
    if isinstance(target, RemotePromise):
        # Promise pipelining: eventual-send to the unresolved answer. A
        # local send's promise has no wire answer to pipeline against.
        source_vow = target.far_vow()
        _check_host(_host.pancake_host_vow_send(
            session.host.raw, source_vow, vptr, len(verb_bytes), arr, count, ctypes.byref(out),
        ))
    else:
        ref = _ref_to_c(target._wire())
        _check_host(_host.pancake_host_session_send(
            session.raw, ctypes.byref(ref), vptr, len(verb_bytes), arr, count, ctypes.byref(out),
        ))
    vow = out.value
    session.host.vow_minted(vow, session)
    return _promise_for(session, vow)
