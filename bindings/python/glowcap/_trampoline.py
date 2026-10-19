"""Internal: the behavior trampoline, the ONE FFI callback in the binding.

Every hosted object: a :meth:`Session.spawn` / :meth:`Session.publish`
actor, a caretaker or attenuator proxy, or a Host publication registers here
and shares a single process-lifetime ``GlowcapHostBehavior`` whose ctx is the
entry's registry id packed as a pointer-sized integer (``free`` = NULL: the
registry owns the Python side, so there is nothing for the library to free).
Settlements never cross the C boundary as callbacks. They ride the action
queue (SETTLE/FAIL, :mod:`glowcap._host`).

Reply discipline: the vat copies ``out_reply``'s payload the instant the
trampoline returns, so the marshalled reply's buffers are retained in the
module's one keep slot across the return (overwritten by the next reply: the
previous one has long been copied). A raised exception must NEVER cross the
``CFUNCTYPE`` boundary (ctypes would print it and return garbage), so every
raise, an attenuator's ``Attenuated``, a revoked caretaker's ``Revoked``, an
unknown-method error, crosses as ``glowcap_host_turn_break`` carrying the
exception's own words. A bare non-OK return would flatten them into a generic
reason. A :class:`Forward` return maps onto ``glowcap_host_turn_forward`` (the
caretaker/attenuator primitive): a target hosted by the same Host composes in
process, and a far target defers the answer onto the forwarded send's vow.
"""

from __future__ import annotations

import ctypes
import inspect
from dataclasses import dataclass
import threading
import weakref
from typing import Callable, Optional

from . import _constants as _abi
from ._abi_value import _arg_from_c, _arg_to_c, _args_to_c, _ref_to_c
from ._errors import _check_host, _host_last_error, GlowcapError, VowBroken
from ._ffi_host import _host, _HostBehavior
from ._ffi_ocapn import _Argument, _byte_buf, _Reference
from ._promise import RemotePromise, _send_far
from ._value import Forward, Ref, _ref_from_id

_OK = _abi.OK


@dataclass
class _BehaviorEntry:
    """One hosted object's behavior and its Host-local reference resolver.

    The resolver lets a :class:`Forward` chain, such as a caretaker over an
    attenuator, compose in process. A Host publication has no resolver until a session
    projects it and records that Host identity in the shared hosted index.
    """

    run: "Callable"
    # Resolve a local Host capability id to its entry, or None when the entry
    # has not joined the Host's local-composition index.
    resolve_local: "Optional[Callable[[int], Optional[_BehaviorEntry]]]"


# Process-global callback lookup is weak: the owning Host strongly retains each
# entry, so a behavior that closes over that Host forms a collectable Host-local
# cycle rather than a process-global root. The C callback has free = NULL;
# Host.close removes the weak row deterministically after FFI teardown.
_registry: "weakref.WeakValueDictionary[int, _BehaviorEntry]" = (
    weakref.WeakValueDictionary()
)
_next_id = 1


def _register_behavior(entry: _BehaviorEntry) -> int:
    """Register a hosted object's behavior, returning the ctx id to pass as the
    trampoline's ctx pointer."""
    global _next_id
    ctx_id = _next_id
    _next_id += 1
    _registry[ctx_id] = entry
    return ctx_id


def _unregister_behavior(ctx_id: int) -> None:
    """Drop a hosted object's registry entry after its Host is released."""
    _registry.pop(ctx_id, None)


def _entry_for(ctx_id: Optional[int]) -> Optional[_BehaviorEntry]:
    """The entry behind a ctx id, for in-process :class:`Forward` composition."""
    return _registry.get(ctx_id) if ctx_id is not None else None


def _chase_local_forwards(entry: _BehaviorEntry, result):
    """Chase a behavior's result through the locally hosted :class:`Forward`
    prefix: while it forwards to a near target the current entry's own
    Host owns, run that behavior in the same turn (a caretaker over an
    attenuator composes exactly as it does over the wire). Returns the
    terminal: a plain value, or the first :class:`Forward` whose target is
    not hosted here (far, promise, or an unknown near id), which each caller
    defers its own way: the trampoline through the host's turn-forward,
    ``send`` onto the forwarded send's wire reply, ``tell`` as a far tell."""
    # The wire path defers each hop onto a fresh turn, so a forward cycle
    # there loops asynchronously; the local chase runs hops synchronously and
    # must bound them, or a caretaker forwarding to itself spins this loop
    # forever. Legitimate proxy chains are a handful deep.
    hops = 0
    while isinstance(result, Forward):
        hops += 1
        if hops > _abi.MAX_LOCAL_FORWARD_HOPS:
            raise RuntimeError(_abi.FORWARD_CYCLE_MESSAGE)
        target = result.target._live()
        inner = None
        if entry.resolve_local is not None:
            inner = entry.resolve_local(target.id)
        if inner is None:
            return result
        entry = inner
        result = inner.run(result.verb, result.args)
    return result


def _run_hosted(entry: _BehaviorEntry, verb: str, args: list, turn=None):
    """Run a hosted behavior and chase the local Forward prefix. When ``turn``
    is set, latch ``_current_turn`` for the duration (the wire trampoline path).
    Local send/tell omit the latch."""
    if turn is None:
        return _chase_local_forwards(entry, entry.run(verb, args))
    prev = getattr(_turn_state, "current_turn", None)
    arriving = getattr(_turn_state, "active_deliver_owner", None)
    _turn_state.current_turn = (turn, _deliver_host(arriving))
    try:
        return _chase_local_forwards(entry, entry.run(verb, args))
    finally:
        _turn_state.current_turn = prev


def _send_local(session, ctx: int, verb: str, args: list) -> RemotePromise:
    # The local arm of `send`: run the hosted behavior on first observation
    # and settle from its result. A `Forward` to another object this side
    # hosts composes in process; a `Forward` to a far target defers onto
    # session.send's wire reply (ADR-0016); a raise settles broken with the
    # behavior's own words.
    async def begin():
        try:
            entry = _entry_for(ctx)
            if entry is None:
                raise VowBroken("no such hosted object")
            result = _run_hosted(entry, verb, args)
            if isinstance(result, Forward):
                return await session.send(result.target, result.verb, result.args)
            if inspect.isawaitable(result):
                # A local send to an async behavior awaits it; the
                # resolver machinery is only for wire-served turns.
                return await result
            return result
        except GlowcapError:
            raise
        except Exception as error:  # noqa: BLE001 - a raise breaks the answer
            raise VowBroken(str(error) or type(error).__name__)

    return RemotePromise.local(begin)


async def _tell_local(session, ctx: int, verb: str, args: list) -> None:
    # The local arm of `tell`: discard the result; a surviving Forward
    # continues as a far tell. Behavior failures have no answer to break and
    # therefore enter the Host's central callerless-failure seam.
    try:
        entry = _entry_for(ctx)
        result = None
        if entry is not None:
            result = _run_hosted(entry, verb, args)
        if inspect.isawaitable(result):
            # Await so an async behavior's raise lands here instead of
            # surfacing as a never-awaited coroutine warning.
            await result
    except Exception as error:  # noqa: BLE001 - no answer exists to break
        session.host._record_callerless_failure("tell.behavior", error)
        return
    if isinstance(result, Forward):
        # The caller of tell remains the recipient for forwarding/I/O failure.
        await session.tell(result.target, result.verb, result.args)


# The turn context while a hosted object's trampoline runs: the opaque
# GlowcapHostTurn* and the Host that owns the turn, or None outside any turn.
# `Session.spawn` reads it to pick the
# turn-time spawn over the top-level one (which the host refuses inside a
# callback); the action drain reads it to defer to the enclosing verb's
# unwind. Behaviors are synchronous, so no task switch can happen between the
# set and read; thread-local state keeps distinct Hosts driven on separate
# threads independent.
_turn_state = threading.local()


def _enter_deliver(owner: object) -> Optional[object]:
    """Bracket synchronous FFI progress that may run an actor."""
    prior = getattr(_turn_state, "active_deliver_owner", None)
    _turn_state.active_deliver_owner = owner
    return prior


def _enter_host_deliver(host: object) -> Optional[object]:
    return _enter_deliver(host)


def _exit_deliver(prior: Optional[object]) -> None:
    _turn_state.active_deliver_owner = prior


def _deliver_host(owner: object | None):
    """Resolve either delivery carrier to its Host without allocating."""
    if owner is None:
        return None
    return getattr(owner, "host", owner)


def _turn_arriving_session(turn: int) -> tuple[object, object]:
    """Resolve the core-owned turn to its Session wrapper or owning Host.

    The turn is authoritative for ingress. An internal redeemed session may
    have no public wrapper, in which case Host identity still supports turn
    verbs and async settlement while per-session policy remains absent.
    """
    carrier = getattr(_turn_state, "active_deliver_owner", None)
    owner = _deliver_host(carrier)
    if owner is None:
        raise RuntimeError("hosted callback ran outside FFI Host progress")
    out = ctypes.c_void_p()
    _check_host(_host.glowcap_host_turn_session(turn, ctypes.byref(out)))
    arriving = owner.get_session(out.value) or owner
    return carrier, arriving


def _current_turn_for(session: object) -> Optional[int]:
    """The current turn pointer when it belongs to ``session``'s Host."""
    current_turn = getattr(_turn_state, "current_turn", None)
    if current_turn is not None and current_turn[1] is getattr(session, "host", None):
        return current_turn[0]
    return None


def _inside_turn() -> bool:
    """Whether ANY hosted turn is running: the drain defers while one is (the
    host refuses the driving verbs inside a callback. Everything enqueued pumps
    when the enclosing call unwinds)."""
    return getattr(_turn_state, "current_turn", None) is not None


# The most recent reply's marshalled argument and its pinned buffers, retained
# across the trampoline's return so the host's immediate copy reads live
# memory. One slot suffices: the host copies before any other Python code can
# run, so by the time this is overwritten the previous reply is long copied.
_reply_state = threading.local()


def _turn_break(turn: int, message: str) -> int:
    # Break this turn's answer with the actor's own diagnostic and return the
    # code the trampoline hands back (OK: the break already settled the answer).
    data = message.encode()
    buf, ptr = _byte_buf(data)
    rc = _host.glowcap_host_turn_break(turn, ptr, len(data))
    return _OK if rc == _OK else rc


def _settle_reply(turn: int, result, out_reply) -> int:
    # Resolve a behavior's already-chased result into the turn's answer: a
    # plain value (None is the void ack) marshals into the reply slot; a
    # surviving `Forward` defers through the host's turn-forward; an
    # awaitable (an async behavior) defers onto a resolver vow the enclosing
    # feed's Host settles when the awaitable completes.
    if inspect.isawaitable(result):
        arriving = getattr(_turn_state, "active_deliver_owner", None)
        owner = _deliver_host(arriving)
        if owner is None:
            return _turn_break(turn, "async behavior outside FFI Host progress")
        if not owner._defer_turn_to_awaitable(turn, result):
            return _turn_break(turn, _host_last_error() or "deferral refused")
        # The behavior's own reply is a void placeholder; the real answer
        # rides the resolver vow.
        void_keep: list = []
        void_arg = _arg_to_c(None, void_keep)
        ctypes.memmove(out_reply, ctypes.byref(void_arg), ctypes.sizeof(_Argument))
        _reply_state.last_reply_keep = (void_arg, void_keep)
        return _OK
    if isinstance(result, Forward):
        # The host forwards: the real answer rides the forwarded send's vow and
        # out_reply gets a void placeholder. Buffers stay pinned by `keep`
        # until the synchronous call returns.
        keep: list = []
        ref = _ref_to_c(result.target)
        verb_bytes = result.verb.encode()
        vbuf, vptr = _byte_buf(verb_bytes)
        arr, count = _args_to_c(result.args, keep)
        rc = _host.glowcap_host_turn_forward(
            turn,
            ctypes.byref(ref),
            vptr,
            len(verb_bytes),
            arr,
            count,
            out_reply,
        )
        if rc != _OK:
            return _turn_break(turn, _host_last_error() or "forward refused")
        return _OK
    # A plain value (None marshals as the void ack). The keep slot pins the
    # marshalled struct and every child buffer it points at across the return.
    keep = []
    c_arg = _arg_to_c(result, keep)
    ctypes.memmove(out_reply, ctypes.byref(c_arg), ctypes.sizeof(_Argument))
    _reply_state.last_reply_keep = (c_arg, keep)
    return _OK


def _trampoline_body(
    ctx, turn, verb_ptr, verb_len, args_ptr, args_len, out_reply
) -> int:
    # The shared trampoline body: decode the deliver, run the entry under the
    # turn context, and settle the reply. Nothing may raise across the C frame,
    # KeyboardInterrupt and CancelledError included.
    entry = _registry.get(ctx or 0)
    if entry is None:
        return _turn_break(turn, "no such hosted object")
    carrier = None
    restore_deliver = False
    try:
        carrier, arriving = _turn_arriving_session(turn)
        _turn_state.active_deliver_owner = arriving
        restore_deliver = True
        verb = (
            ctypes.string_at(verb_ptr, verb_len).decode(errors="replace")
            if verb_len
            else ""
        )
        args = [_arg_from_c(args_ptr[i]) for i in range(args_len)]
        if getattr(arriving, "gc_enabled", False):
            getattr(arriving, "gc").track_arguments(args)
        return _settle_reply(turn, _run_hosted(entry, verb, args, turn=turn), out_reply)
    except BaseException as error:  # noqa: BLE001 - nothing crosses the C frame
        return _turn_break(turn, str(error) or type(error).__name__)
    finally:
        if restore_deliver:
            _turn_state.active_deliver_owner = carrier


# The one FFI callback, module-lifetime by construction: a per-spawn
# CFUNCTYPE the GC collected would be a dangling C pointer, and the host may
# deliver for as long as the process hosts objects.
_TRAMPOLINE = _HostBehavior(_trampoline_body)


def _turn_spawn(turn: int, ctx_id: int) -> int:
    """Spawn a hosted object from INSIDE a turn: the turn-time form the host
    allows where the top-level spawn is refused. Returns its opaque Host id."""
    out = _Reference()
    _check_host(
        _host.glowcap_host_turn_spawn(
            turn, _TRAMPOLINE, ctypes.c_void_p(ctx_id), None, ctypes.byref(out)
        )
    )
    return out.id


def _caretaker_proxy(spawn, target: Ref) -> "Caretaker":
    # ADR-0016 caretaker: spawn a proxy that forwards to `target` until
    # revoke(), then breaks every call Revoked.
    live = [True]

    def proxy_behavior(verb: str, args: list):
        if not live[0]:
            raise ValueError("Revoked")
        return Forward(target, verb, args)

    return Caretaker(spawn(proxy_behavior), live)


def _attenuate_proxy(spawn, target: Ref, verbs: list) -> Ref:
    # ADR-0016 attenuator: spawn a proxy that forwards only allow-listed
    # verbs and breaks every other call Attenuated.
    allowed = set(verbs)

    def proxy_behavior(verb: str, args: list):
        if verb not in allowed:
            raise ValueError("Attenuated")
        return Forward(target, verb, args)

    return spawn(proxy_behavior)


async def _tell_far(session, target: Ref | RemotePromise, verb: str, args: list) -> None:
    # Far tell mint: encode args, call glowcap_host_session_tell, kick the drain. Local
    # targets stay behind _dispatch_tell / _tell_local.
    verb_bytes = verb.encode()
    vbuf, vptr = _byte_buf(verb_bytes)
    keepalive: list = []
    arr, count = _args_to_c(args, keepalive)
    if isinstance(target, RemotePromise):
        source_vow = target.far_vow(session.host)
        _check_host(
            _host.glowcap_host_vow_tell(
                session.host.raw,
                source_vow,
                vptr,
                len(verb_bytes),
                arr,
                count,
            )
        )
    else:
        ref = _ref_to_c(target)
        _check_host(
            _host.glowcap_host_session_tell(
                session.raw,
                ctypes.byref(ref),
                vptr,
                len(verb_bytes),
                arr,
                count,
            )
        )
    await session.host.kick_actions()


def _dispatch_send(session, target, verb: str, args) -> RemotePromise:
    # Near-hosted vs far send dispatch: a self-hosted near runs _send_local,
    # everything else mints through _send_far. Session keeps guard/drain + the
    # CapTP verb; this owns the routing if.
    if isinstance(target, Ref):
        ctx = session.hosted.get(target._live().id)
        if ctx is not None:
            return _send_local(session, ctx, verb, list(args))
    return _send_far(session, target, verb, args)


async def _dispatch_tell(session, target: Ref | RemotePromise, verb: str, args) -> None:
    # Near-hosted vs far tell dispatch: a self-hosted near runs _tell_local,
    # everything else mints through _tell_far.
    if isinstance(target, Ref):
        ctx = session.hosted.get(target._live().id)
        if ctx is not None:
            await _tell_local(session, ctx, verb, list(args))
            return
    await _tell_far(session, target, verb, args)


def _register_actor(session, behavior) -> int:
    # Register `behavior` in the Host-owned trampoline index so local Forward
    # chains compose in process and an arriving Port can run it in a turn.
    hosted = session.hosted
    return session.host._register_behavior(
        _BehaviorEntry(
            run=behavior,
            resolve_local=lambda ref_id: _entry_for(hosted.get(ref_id)),
        )
    )


def _spawn_hosted(session, behavior) -> Ref:
    # Register + mint a top-level or turn-time spawn; records the Host id so
    # local Forward composition finds it.
    turn = _current_turn_for(session)
    if turn is None:
        session.guard_open()
    ctx = _register_actor(session, behavior)
    try:
        if turn is not None:
            ref_id = _turn_spawn(turn, ctx)
        else:
            out = _Reference()
            _check_host(
                _host.glowcap_host_session_spawn(
                    session.raw,
                    _TRAMPOLINE,
                    ctypes.c_void_p(ctx),
                    None,
                    ctypes.byref(out),
                )
            )
            ref_id = out.id
    except BaseException:
        # free = NULL: the C tier never owns the row, so a refused mint must
        # drop it here or the registry pins the behavior forever.
        session.host._unregister_behavior(ctx)
        raise
    session.hosted[ref_id] = ctx
    return _ref_from_id(ref_id)


def _publish_hosted(session, name: str, behavior) -> Ref:
    # Register + publish by swiss name; records the Host id in hosted.
    session.guard_open()
    ctx = _register_actor(session, behavior)
    swiss = name.encode()
    buf, ptr = _byte_buf(swiss)
    out = _Reference()
    try:
        _check_host(
            _host.glowcap_host_session_publish(
                session.raw,
                ptr,
                len(swiss),
                _TRAMPOLINE,
                ctypes.c_void_p(ctx),
                None,
                ctypes.byref(out),
            )
        )
    except BaseException:
        # free = NULL: the C tier never owns the row, so a refused publish
        # must drop it here or the registry pins the behavior forever.
        session.host._unregister_behavior(ctx)
        raise
    ref_id = out.id
    session.hosted[ref_id] = ctx
    return _ref_from_id(ref_id)


class Caretaker:
    """A revocable caretaker over a capability (ADR-0016), returned by
    :meth:`Session.caretaker`. Hand :attr:`proxy` to a partner. Call
    :meth:`revoke` to sever it, after which every call through the proxy breaks
    with ``Revoked``."""

    def __init__(self, proxy: Ref, live: list):
        self.proxy = proxy
        self._live = live

    def revoke(self) -> None:
        """Sever the proxy: subsequent calls through it break with ``Revoked``.
        Idempotent."""
        self._live[0] = False
