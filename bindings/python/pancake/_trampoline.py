"""Internal: the behavior trampoline, the ONE native callback in the binding.

Every hosted object — a :meth:`Session.spawn` / :meth:`Session.publish`
actor, a caretaker or attenuator proxy, a host-wide giftable — registers here
and shares a single process-lifetime ``PancakeHostBehavior`` whose ctx is the
entry's registry id packed as a pointer-sized integer (``free`` = NULL: the
registry owns the Python side, so there is nothing for the library to free).
Settlements never cross the C boundary as callbacks; they ride the action
queue (SETTLE/FAIL, :mod:`pancake._host`).

Reply discipline: the vat copies ``out_reply``'s payload the instant the
trampoline returns, so the marshalled reply's buffers are retained in the
module's one keep slot across the return (overwritten by the next reply — the
previous one has long been copied). A raised exception must NEVER cross the
``CFUNCTYPE`` boundary (ctypes would print it and return garbage), so every
raise — an attenuator's ``Attenuated``, a revoked caretaker's ``Revoked``, an
unknown-method error — crosses as ``pancake_host_turn_break`` carrying the
exception's own words; a bare non-OK return would flatten them into a generic
reason. A :class:`Forward` return maps onto ``pancake_host_turn_forward`` (the
caretaker/attenuator primitive): a target hosted by the same session
composes in process, a far target defers the answer onto the forwarded send's
vow.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from typing import Callable, Optional

from . import _constants as _abi
from ._codec import _arg_from_c, _arg_to_c, _args_to_c, _ref_to_c
from ._errors import _check_host, _host_last_error, PancakeException, VowBroken
from ._ffi_driver import _host, _HostBehavior
from ._ffi_ocapn import _Argument, _byte_buf
from ._promise import RemotePromise, _send_far
from ._value import Forward, Near, Ref, _lift_value, _lower_value

_OK = _abi.OK

@dataclass
class _BehaviorEntry:
    """One hosted object: its behavior, and — for an actor bound to a
    connection — how to resolve a near export position on that connection to
    another hosted entry, so a :class:`Forward` chain (a caretaker over an
    attenuator) composes in process. A host-wide giftable carries neither: its
    forwards always go through the host."""

    run: "Callable"
    # The connection this entry serves (identity only, for turn-ownership
    # checks), or None for a host-wide giftable.
    session: Optional[object]
    # Resolve a near export position hosted by this entry's own connection to
    # its entry, or None when this side does not host it / for a giftable.
    resolve_local: "Optional[Callable[[int], Optional[_BehaviorEntry]]]"


# The registry: ctx id -> entry. Entries live as long as the host may deliver
# to them (free = NULL means no teardown callback): a connection-bound entry is
# unregistered when its connection closes (`Session.close_transport` drops
# its hosted ids), a host-wide giftable lives for its host's lifetime, the same
# posture as the other bindings' keep tables.
_registry: "dict[int, _BehaviorEntry]" = {}
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
    """Drop a hosted object's registry entry once the host can never deliver to
    it again — a closing connection sweeps its own hosted ids so the registry
    does not pin dead behaviors. Host-wide giftables (``conn is None``) are
    never unregistered here; they die with their host. Idempotent."""
    _registry.pop(ctx_id, None)  # tolerant: a close may sweep an id twice


def _entry_for(ctx_id: Optional[int]) -> Optional[_BehaviorEntry]:
    """The entry behind a ctx id, for in-process :class:`Forward` composition."""
    return _registry.get(ctx_id) if ctx_id is not None else None


def _chase_local_forwards(entry: _BehaviorEntry, result):
    """Chase a behavior's result through the locally hosted :class:`Forward`
    prefix: while it forwards to a near target the current entry's own
    connection hosts, run that behavior in the same turn (a caretaker over an
    attenuator composes exactly as it does over the wire). Returns the
    terminal — a plain value, or the first :class:`Forward` whose target is
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
        target = result.target
        inner = None
        if target.near is not None and entry.resolve_local is not None:
            inner = entry.resolve_local(target.near.id)
        if inner is None:
            return result
        entry = inner
        result = inner.run(result.verb, result.args)
    return result


def _run_hosted(entry: _BehaviorEntry, verb: str, args: list, turn=None):
    """Run a hosted behavior and chase the local Forward prefix. When ``turn``
    is set, latch ``_current_turn`` for the duration (the wire trampoline path);
    local send/tell omit the latch."""
    if turn is None:
        return _chase_local_forwards(entry, entry.run(verb, args))
    global _current_turn
    prev = _current_turn
    _current_turn = (turn, entry.session)
    try:
        return _chase_local_forwards(entry, entry.run(verb, args))
    finally:
        _current_turn = prev


def _send_local(session, ctx: int, verb: str, args: list) -> RemotePromise:
    # The local arm of `send`: run the hosted behavior on first observation
    # and settle from its result. A `Forward` to another object this side
    # hosts composes in process; a `Forward` to a far target defers onto
    # session.send's wire reply (ADR-0064); a raise settles broken with the
    # behavior's own words.
    async def begin():
        try:
            entry = _entry_for(ctx)
            if entry is None:
                raise VowBroken("no such hosted object")
            result = _run_hosted(entry, verb, args)
            if isinstance(result, Forward):
                return await session.send(result.target, result.verb, result.args)
            return result
        except PancakeException:
            raise
        except Exception as error:  # noqa: BLE001 — a raise breaks the answer
            raise VowBroken(str(error) or type(error).__name__)

    return RemotePromise(None, begin, None)


async def _tell_local(session, ctx: int, verb: str, args: list) -> None:
    # The local arm of `tell`: discard the result; a surviving Forward
    # continues as a far tell. Raises break nothing.
    try:
        entry = _entry_for(ctx)
        result = None
        if entry is not None:
            result = _run_hosted(entry, verb, args)
        if isinstance(result, Forward):
            await session.tell(result.target, result.verb, result.args)
    except Exception:  # noqa: BLE001 — no answer to break
        pass


# The turn context while a hosted object's trampoline runs: the opaque
# PancakeHostTurn* and the connection the turn arrived on (None for a
# giftable), or None outside any turn. `Session.spawn` reads it to pick the
# turn-time spawn over the top-level one (which the host refuses inside a
# callback); the action drain reads it to defer to the enclosing verb's
# unwind. A plain module variable is enough: behaviors are synchronous, so no
# task switch can happen between the set and the read.
_current_turn: "Optional[tuple[int, Optional[object]]]" = None


def _current_turn_for(session: object) -> Optional[int]:
    """The current turn pointer when it belongs to connection ``conn``."""
    if _current_turn is not None and _current_turn[1] is session:
        return _current_turn[0]
    return None


def _inside_turn() -> bool:
    """Whether ANY hosted turn is running — the drain defers while one is (the
    host refuses the driving verbs inside a callback; everything enqueued pumps
    when the enclosing call unwinds)."""
    return _current_turn is not None


# The most recent reply's marshalled argument and its pinned buffers, retained
# across the trampoline's return so the host's immediate copy reads live
# memory. One slot suffices: the host copies before any other Python code can
# run, so by the time this is overwritten the previous reply is long copied.
_last_reply_keep: "Optional[tuple]" = None


def _turn_break(turn: int, message: str) -> int:
    # Break this turn's answer with the actor's own diagnostic and return the
    # code the trampoline hands back (OK: the break already settled the answer).
    data = message.encode()
    buf, ptr = _byte_buf(data)
    rc = _host.pancake_host_turn_break(turn, ptr, len(data))
    return _OK if rc == _OK else rc


def _settle_reply(turn: int, result, out_reply) -> int:
    # Resolve a behavior's already-chased result into the turn's answer: a
    # plain value (None is the void ack) marshals into the reply slot; a
    # surviving `Forward` defers through the host's turn-forward.
    global _last_reply_keep
    if isinstance(result, Forward):
        # The host forwards: the real answer rides the forwarded send's vow and
        # out_reply gets a void placeholder. Buffers stay pinned by `keep`
        # until the synchronous call returns.
        keep: list = []
        ref = _ref_to_c(result.target._wire())
        verb_bytes = result.verb.encode()
        vbuf, vptr = _byte_buf(verb_bytes)
        arr, count = _args_to_c([_lower_value(a) for a in result.args], keep)
        rc = _host.pancake_host_turn_forward(
            turn, ctypes.byref(ref), vptr, len(verb_bytes), arr, count, out_reply,
        )
        if rc != _OK:
            return _turn_break(turn, _host_last_error() or "forward refused")
        return _OK
    # A plain value (None marshals as the void ack). The keep slot pins the
    # marshalled struct and every child buffer it points at across the return.
    keep = []
    c_arg = _arg_to_c(_lower_value(result), keep)
    ctypes.memmove(out_reply, ctypes.byref(c_arg), ctypes.sizeof(_Argument))
    _last_reply_keep = (c_arg, keep)
    return _OK


def _trampoline_body(ctx, turn, verb_ptr, verb_len, args_ptr, args_len, out_reply) -> int:
    # The shared trampoline body: decode the deliver, run the entry under the
    # turn context, and settle the reply. Nothing may raise across the C frame,
    # KeyboardInterrupt and CancelledError included.
    entry = _registry.get(ctx or 0)
    if entry is None:
        return _turn_break(turn, "no such hosted object")
    try:
        verb = ctypes.string_at(verb_ptr, verb_len).decode(errors="replace") if verb_len else ""
        args = [_lift_value(_arg_from_c(args_ptr[i])) for i in range(args_len)]
        return _settle_reply(turn, _run_hosted(entry, verb, args, turn=turn), out_reply)
    except BaseException as error:  # noqa: BLE001 — nothing crosses the C frame
        return _turn_break(turn, str(error) or type(error).__name__)


# The one native callback, module-lifetime by construction: a per-spawn
# CFUNCTYPE the GC collected would be a dangling C pointer, and the host may
# deliver for as long as the process hosts objects.
_TRAMPOLINE = _HostBehavior(_trampoline_body)


def _turn_spawn(turn: int, ctx_id: int) -> int:
    """Spawn a hosted object at a fresh export position from INSIDE a turn —
    the turn-time form the host allows where the top-level spawn is refused.
    Returns the export position."""
    out = ctypes.c_uint64()
    _check_host(_host.pancake_host_turn_spawn(
        turn, _TRAMPOLINE, ctypes.c_void_p(ctx_id), None, ctypes.byref(out)
    ))
    return out.value


def _caretaker_proxy(spawn, target: Ref) -> "Caretaker":
    # ADR-0064 caretaker: spawn a proxy that forwards to `target` until
    # revoke(), then breaks every call Revoked.
    live = [True]

    def proxy_behavior(verb: str, args: list):
        if not live[0]:
            raise ValueError("Revoked")
        return Forward(target, verb, args)

    return Caretaker(spawn(proxy_behavior), live)


def _attenuate_proxy(spawn, target: Ref, verbs: list) -> Ref:
    # ADR-0064 attenuator: spawn a proxy that forwards only allow-listed
    # verbs and breaks every other call Attenuated.
    allowed = set(verbs)

    def proxy_behavior(verb: str, args: list):
        if verb not in allowed:
            raise ValueError("Attenuated")
        return Forward(target, verb, args)

    return spawn(proxy_behavior)


async def _tell_far(session, target: Ref, verb: str, args: list) -> None:
    # Far tell mint: encode args, enqueue conn_tell, kick the drain. Local
    # targets stay behind _dispatch_tell / _tell_local.
    verb_bytes = verb.encode()
    vbuf, vptr = _byte_buf(verb_bytes)
    keepalive: list = []
    arr, count = _args_to_c([_lower_value(a) for a in args], keepalive)
    ref = _ref_to_c(target._wire())
    _check_host(_host.pancake_host_session_tell(
        session.raw, ctypes.byref(ref), vptr, len(verb_bytes), arr, count,
    ))
    await session.host.kick_actions()


def _dispatch_send(session, target, verb: str, args: list) -> RemotePromise:
    # Near-hosted vs far send dispatch: a self-hosted near runs _send_local,
    # everything else mints through _send_far. Session keeps guard/drain + the
    # CapTP verb; this owns the routing if.
    if isinstance(target, Ref) and target.near is not None:
        ctx = session.hosted.get(target.near.id)
        if ctx is not None:
            return _send_local(session, ctx, verb, args)
    return _send_far(session, target, verb, args)


async def _dispatch_tell(session, target: Ref, verb: str, args: list) -> None:
    # Near-hosted vs far tell dispatch: a self-hosted near runs _tell_local,
    # everything else mints through _tell_far.
    if target.near is not None:
        ctx = session.hosted.get(target.near.id)
        if ctx is not None:
            await _tell_local(session, ctx, verb, args)
            return
    await _tell_far(session, target, verb, args)


def _register_actor(session, behavior) -> int:
    # Register `behavior` in the trampoline registry as an actor of this
    # connection, so a Forward whose target this side hosts composes in
    # process and a turn it runs can spawn turn-time.
    return _register_behavior(_BehaviorEntry(
        run=behavior,
        session=session,
        resolve_local=lambda position: _entry_for(session.hosted.get(position)),
    ))


def _spawn_hosted(session, behavior) -> Ref:
    # Register + mint a top-level or turn-time spawn; records the export so
    # local Forward composition finds it.
    session.guard_open()
    ctx = _register_actor(session, behavior)
    turn = _current_turn_for(session)
    if turn is not None:
        position = _turn_spawn(turn, ctx)
    else:
        out = ctypes.c_uint64()
        _check_host(_host.pancake_host_session_spawn(
            session.raw, _TRAMPOLINE, ctypes.c_void_p(ctx), None, ctypes.byref(out),
        ))
        position = out.value
    session.hosted[position] = ctx
    return Ref(Near(position))


def _publish_hosted(session, name: str, behavior) -> Ref:
    # Register + publish by swiss name; records the export in hosted.
    session.guard_open()
    ctx = _register_actor(session, behavior)
    swiss = name.encode()
    buf, ptr = _byte_buf(swiss)
    out = ctypes.c_uint64()
    _check_host(_host.pancake_host_session_publish(
        session.raw, ptr, len(swiss),
        _TRAMPOLINE, ctypes.c_void_p(ctx), None, ctypes.byref(out),
    ))
    position = out.value
    session.hosted[position] = ctx
    return Ref(Near(position))


class Caretaker:
    """A revocable caretaker over a capability (ADR-0064), returned by
    :meth:`Session.caretaker`. Hand :attr:`proxy` to a partner; call
    :meth:`revoke` to sever it, after which every call through the proxy breaks
    with ``Revoked``."""

    def __init__(self, proxy: Ref, live: list):
        self.proxy = proxy
        self._live = live

    def revoke(self) -> None:
        """Sever the proxy: subsequent calls through it break with ``Revoked``.
        Idempotent."""
        self._live[0] = False
