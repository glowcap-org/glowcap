"""Internal: the :class:`RemotePromise` a Session send returns: immediate
progress, lazy result observation, promise pipelining, and ``index``/``untag``/``get``
projection (ADR-0003 / ADR-0004). Also the shared fetch/enliven
mint→await→classify path (``_await_minted`` / ``_fetch_like``), the far-send
mint→``_promise_for`` path (``_send_far``), and RemotePromise construction.
Session owns CapTP verb wrappers. Trampoline owns Host-reference send·tell
dispatch and local arms. This module owns the handle type, remote-send /
post-mint choreography, and the projection FFI.
"""

from __future__ import annotations

import asyncio
import ctypes
from dataclasses import dataclass
from typing import Optional, Union

from . import _constants as _abi
from ._abi_value import _args_to_c, _ref_to_c
from ._errors import FetchFailed, GlowcapError, _check_host, _retain_cleanup_failure
from ._ffi_host import _host
from ._ffi_ocapn import _Reference, _byte_buf
from ._gc import release_ref
from ._value import Ref, _ref_from_id

_ERR_UNSUPPORTED_VALUE = _abi.ERR_UNSUPPORTED_VALUE
_ERR_INVALID_ARGUMENT = _abi.ERR_INVALID_ARGUMENT


async def _await_minted(session, vow: int, *, track_gc: bool):
    # The shared fetch/enliven wait: register the vow, keep the inbound
    # loop running (the completion's bytes arrive on it), kick the drain so
    # the deliver leaves now, and await the drain-routed outcome.
    try:
        session.host.vow_minted(vow, track_gc=track_gc and session.gc_enabled)
        session.serve()
        settled = session.host.await_vow(vow)
        await session.host.kick_actions()
        result = await settled
        session.gc.park_vow(vow)
        return result
    except BaseException as failure:
        try:
            session.gc.park_vow(vow)
        except BaseException as cleanup:
            _retain_cleanup_failure(failure, cleanup)
        raise


def _classify_live_ref(result, label: str) -> Ref:
    """Classify a settled mint as an opaque Host capability -- the shared
    verdict under ``_fetch_like`` and the host-level select-or-dial enliven."""
    if not isinstance(result, Ref):
        raise FetchFailed(label)
    return result


async def _fetch_like(session, swiss: bytes, label: str, mint, track: bool) -> Ref:
    # The one mint/await/classify body under `fetch` and `enliven`: mint
    # the host vow with `mint`, await its drain-routed completion, and
    # classify: only an opaque Host reference is a live capability this
    # surface can hand out. `track` enrolls the fulfilled value in
    # distributed GC. Fetch and fresh/cached enliven results each project
    # an application retain, independently of the session dedup cache.
    session.guard_open()
    session.gc.drain_gc()
    buf, ptr = _byte_buf(swiss)
    out = ctypes.c_uint64()
    _check_host(mint(session.raw, ptr, len(swiss), ctypes.byref(out)))
    result = await _await_minted(session, out.value, track_gc=track)
    if not isinstance(result, Ref):
        raise FetchFailed(label)
    return result


def _promise_for(session, vow: int, *, pipelineable: bool = True) -> RemotePromise:
    # Adopt a freshly minted Host vow into one public wrapper. Every fallible
    # setup step either acquires its owner or parks FFI release.
    async def begin():
        session.serve()  # the settle's bytes arrive on the inbound loop
        settled = session.host.await_vow(vow)
        await session.host.kick_actions()
        return await settled

    def project(op: str, key) -> RemotePromise:
        out = ctypes.c_uint64()
        if op == "index":
            _check_host(
                _host.glowcap_host_vow_index(
                    session.host.raw,
                    vow,
                    int(key),
                    ctypes.byref(out),
                )
            )
        else:
            field = str(key).encode()
            fbuf, fptr = _byte_buf(field)
            fn = (
                _host.glowcap_host_vow_get
                if op == "get"
                else _host.glowcap_host_vow_untag
            )
            _check_host(
                fn(
                    session.host.raw,
                    vow,
                    fptr,
                    len(field),
                    ctypes.byref(out),
                )
            )
        projected = out.value
        return _promise_for(session, projected)

    try:
        session.host.vow_minted(vow, track_gc=session.gc_enabled)
        promise = (
            RemotePromise.far(vow, session.host, begin, project)
            if pipelineable
            else RemotePromise.observer(vow, begin)
        )
        session.serve()
        session.host.schedule_kick()
        # Last fallible adoption step: after this succeeds, returning the
        # wrapper transfers the FFI vow to its finalizer.
        session.gc.track_vow(promise, vow)
        return promise
    except BaseException as failure:
        try:
            session.gc.park_vow(vow)
        except BaseException as cleanup:
            _retain_cleanup_failure(failure, cleanup)
        raise


class PromiseState:
    """Sum state for :class:`RemotePromise`: ``Far`` (host vow), ``Local``, or
    ``Failed`` (the send never left). Discriminant is the arm type: not a
    nullable vow field."""

    @dataclass(frozen=True, slots=True)
    class Far:
        vow: int
        host_owner: object
        tag: str = "far"

    @dataclass(frozen=True, slots=True)
    class Local:
        tag: str = "local"

    @dataclass(frozen=True, slots=True)
    class Observer:
        vow: int
        tag: str = "observer"

    @dataclass(frozen=True, slots=True)
    class Failed:
        """A send that could not be issued at all: a closed session, an
        argument that would not lower. It is a state rather than a raised
        exception because ``send`` must return its handle synchronously, so
        pipelining can project at the answer before it settles (ADR-0004).
        Raising instead put a synchronous failure channel on an awaitable, and
        a comprehension building sends raised before ``gather`` was ever
        entered, so ``return_exceptions`` could not help."""

        error: BaseException
        tag: str = "failed"

    Kind = Union[
        "PromiseState.Far",
        "PromiseState.Local",
        "PromiseState.Observer",
        "PromiseState.Failed",
    ]

    @staticmethod
    def far(vow: int, host_owner: object) -> "PromiseState.Far":
        return PromiseState.Far(vow, host_owner)

    @staticmethod
    def local() -> "PromiseState.Local":
        return PromiseState.Local()

    @staticmethod
    def observer(vow: int) -> "PromiseState.Observer":
        return PromiseState.Observer(vow)

    @staticmethod
    def failed(error: BaseException) -> "PromiseState.Failed":
        return PromiseState.Failed(error)


class RemotePromise(asyncio.Future):
    """The handle :meth:`Session.send` returns: the eventual result of one
    eventual-send, and -- the point of promise pipelining (ADR-0003) -- a target
    you can ``send`` to before it resolves.

    It is a real :class:`asyncio.Future`, so ``await session.send(...)``,
    ``asyncio.gather(...)``, and ``isinstance(_, asyncio.Future)`` all work
    natively. Pass it *unawaited* as the ``target`` of a later ``send`` to
    address the object the answer will resolve to: the dependent call rides a
    ``desc:answer`` deliver and the partner queues it until the answer settles,
    so a ``create -> use`` chain costs one round trip::

        task = session.send(root, "create", ["x"])       # not awaited
        session.send(task, "assign", ["alice"])          # pipelined at the answer
        status = await session.send(task, "status", [])  # settles the chain

    The send schedules Host progress when this is created, so an unobserved
    eventual-send still leaves the process. Synchronous chains batch in the
    event-loop turn before that scheduled drain runs. Because the
    settle is drain-routed and no exception is materialized until the handle is
    observed, an unobserved anchor whose far answer *breaks* stays silent. Like
    any ``asyncio.Future``, construct it within a running event loop (``send``
    is always called from one). State is a sum (``far`` | ``observer`` |
    ``local`` | ``failed``), not a nullable vow flag. An ``observer`` is an
    await-only ``op:listen`` result with no remote answer position. A pipeline
    target belongs to the Host that minted it. Another Host refuses it before
    interpreting the Host-local vow number.

    The projection verbs :meth:`index` / :meth:`untag` / :meth:`get`
    (ADR-0004) pipeline an element, untag, or Struct-field access *at
    the answer*, before it resolves: each returns a new :class:`RemotePromise`
    for the projected value.
    """

    def __init__(self, kind: PromiseState.Kind, begin, project=None) -> None:
        # The future is created empty; the owning factory schedules Host
        # progress after the wrapper and its finalizer are installed.
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
    def far(cls, vow: int, host_owner: object, begin, project) -> "RemotePromise":
        return cls(PromiseState.far(vow, host_owner), begin, project)

    @classmethod
    def local(cls, begin) -> "RemotePromise":
        return cls(PromiseState.local(), begin, None)

    @classmethod
    def observer(cls, vow: int, begin) -> "RemotePromise":
        return cls(PromiseState.observer(vow), begin, None)

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
        """FFI Host vow when present (convenience, not the discriminant)."""
        if isinstance(self._kind, (PromiseState.Far, PromiseState.Observer)):
            return self._kind.vow
        return None

    def far_vow(self, host_owner: object) -> int:
        """The host vow for pipelining, or a typed refusal when this is local."""
        # A failed handle keeps its own reason rather than reporting the
        # generic local-send refusal, so a caller sees why the send never left.
        if isinstance(self._kind, PromiseState.Failed):
            raise self._kind.error
        if not isinstance(self._kind, PromiseState.Far):
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "this promise is await-only and has no remote pipeline target",
            )
        if self._kind.host_owner is not host_owner:
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "this promise belongs to another Host",
            )
        return self._kind.vow

    def _project_op(self, op: str, key) -> "RemotePromise":
        # A pipeline behind a send that never left is itself a send that never
        # left. Carrying the same reason forward means the whole chain fails
        # where it is awaited rather than raising at the link that was written.
        if isinstance(self._kind, PromiseState.Failed):
            return RemotePromise.failed(self._kind.error)
        if not isinstance(self._kind, PromiseState.Far) or self._project is None:
            raise GlowcapError(
                _ERR_INVALID_ARGUMENT,
                "this promise is await-only and cannot be projected",
            )
        return self._project(op, key)

    def index(self, i: int) -> "RemotePromise":
        """Pipeline an ``op:index`` for ``i`` at this answer (ADR-0004): a new
        :class:`RemotePromise` for the List element of whatever this resolves
        to."""
        return self._project_op("index", int(i))

    def untag(self, tag: str) -> "RemotePromise":
        """Pipeline an ``op:untag`` for ``tag`` at this answer (ADR-0004): a new
        :class:`RemotePromise` for the payload of whatever this resolves to,
        which must be a Tagged record whose tag equals ``tag``."""
        return self._project_op("untag", tag)

    def get(self, field: str) -> "RemotePromise":
        """Pipeline an ``op:get`` for ``field`` at this answer (ADR-0004): a new
        :class:`RemotePromise` for the Struct field of whatever this resolves
        to."""
        return self._project_op("get", field)

    def _ensure_started(self) -> None:
        # First observation installs the reply wait exactly once and chains its
        # outcome onto this future. Observation is an
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
        # callback: so registering interest is what starts the send.
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


def _listen_far(session, target) -> RemotePromise:
    """``Session.listen``'s wire half: mint the listen vow over a held far
    promise (CapTP ``op:listen``) and hand back the settle handle. The vow is
    plain -- a listen may settle to any value, not only a capability."""
    ref = _ref_to_c(target._live())
    out = ctypes.c_uint64()
    _check_host(
        _host.glowcap_host_session_listen(
            session.raw,
            ctypes.byref(ref),
            ctypes.byref(out),
        )
    )
    vow = out.value
    return _promise_for(session, vow, pipelineable=False)


def _lower_promise(session, promise: "RemotePromise", minted: list[Ref]) -> Ref:
    """What a far promise passes as (ADR-0068): the capability its Host mints
    for the vow, in whatever state the vow is in while this handle lives, one
    application retain pushed on ``minted`` for the caller to give back.
    ``glowcap_host_vow_capability`` says what the partner receives."""
    vow = promise.far_vow(session.host)
    out = _Reference()
    _check_host(_host.glowcap_host_vow_capability(session.host.raw, vow, ctypes.byref(out)))
    ref = _ref_from_id(out.id)
    minted.append(ref)
    return ref


class _FarArguments:
    """Far send or tell arguments encoded for the FFI, with each promise among
    them lowered to the capability its Host mints (ADR-0068). The Host's queue holds its own retain once the call is
    admitted, so leaving the block gives every minted retain back right after
    the FFI call, admitted or refused. A promise another Host returned, an
    await-only one, and a plain Future are refused before any frame moves."""

    def __init__(self, session, args: list):
        self._session = session
        self._args = args
        self._keepalive: list = []
        self._minted: list[Ref] = []

    def __enter__(self):
        try:
            return _args_to_c(self._args, self._keepalive, self._lower)
        except BaseException as failure:
            try:
                self._release()
            except BaseException as cleanup:
                _retain_cleanup_failure(failure, cleanup)
            raise

    def __exit__(self, _kind, failure, _trace) -> None:
        try:
            self._release()
        except BaseException as cleanup:
            if failure is not None:
                _retain_cleanup_failure(failure, cleanup)
                return
            # The call was admitted and its effect stands, so a retain the
            # Host could not take back is the Host's to report, not the
            # send's.
            self._session.host._record_callerless_failure("promise argument release", cleanup)

    def _lower(self, promise: asyncio.Future) -> Ref:
        if not isinstance(promise, RemotePromise):
            raise GlowcapError(
                _ERR_UNSUPPORTED_VALUE,
                "only the promise a send returned is passable as a capability",
            )
        return _lower_promise(self._session, promise, self._minted)

    def _release(self) -> None:
        failure: Optional[BaseException] = None
        while self._minted:
            try:
                release_ref(self._session.host.raw, self._minted.pop())
            except BaseException as cleanup:
                failure = cleanup if failure is None else _retain_cleanup_failure(failure, cleanup)
        if failure is not None:
            raise failure


def _send_far(session, target, verb: str, args: list) -> RemotePromise:
    # Far-send mint→RemotePromise: encode args, mint the host vow
    # (glowcap_host_session_send / glowcap_host_vow_send), register it, and
    # hand back _promise_for.
    # Local-hosted targets stay in Session (trampoline _send_local).
    verb_bytes = verb.encode()
    vbuf, vptr = _byte_buf(verb_bytes)
    out = ctypes.c_uint64()
    with _FarArguments(session, args) as (arr, count):
        if isinstance(target, RemotePromise):
            # Promise pipelining: eventual-send to the unresolved answer. A
            # local send's promise has no wire answer to pipeline against.
            source_vow = target.far_vow(session.host)
            _check_host(
                _host.glowcap_host_vow_send(
                    session.host.raw,
                    source_vow,
                    vptr,
                    len(verb_bytes),
                    arr,
                    count,
                    ctypes.byref(out),
                )
            )
        else:
            ref = _ref_to_c(target._live())
            _check_host(
                _host.glowcap_host_session_send(
                    session.raw,
                    ctypes.byref(ref),
                    vptr,
                    len(verb_bytes),
                    arr,
                    count,
                    ctypes.byref(out),
                )
            )
    vow = out.value
    return _promise_for(session, vow)
