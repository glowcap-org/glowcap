"""Internal: the behavior trampoline, the ONE native callback in the binding.

Every hosted object — a :meth:`Connection.spawn` / :meth:`Connection.publish`
actor, a caretaker or attenuator proxy, a node-wide giftable — registers here
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
caretaker/attenuator primitive): a target hosted by the same connection
composes in process, a far target defers the answer onto the forwarded send's
vow.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from typing import Callable, Optional

from . import _constants as _abi
from ._codec import _arg_from_c, _arg_to_c, _args_to_c, _ref_to_c
from ._errors import _check_host, _host_last_error
from ._ffi_driver import _host, _HostBehavior
from ._ffi_ocapn import _Argument, _byte_buf
from ._value import Forward, _lift_value, _lower_value

_OK = _abi.OK

@dataclass
class _BehaviorEntry:
    """One hosted object: its behavior, and — for an actor bound to a
    connection — how to resolve a near export position on that connection to
    another hosted entry, so a :class:`Forward` chain (a caretaker over an
    attenuator) composes in process. A node-wide giftable carries neither: its
    forwards always go through the host."""

    run: "Callable"
    # The connection this entry serves (identity only, for turn-ownership
    # checks), or None for a node-wide giftable.
    conn: Optional[object]
    # Resolve a near export position hosted by this entry's own connection to
    # its entry, or None when this side does not host it / for a giftable.
    resolve_local: "Optional[Callable[[int], Optional[_BehaviorEntry]]]"


# The registry: ctx id -> entry. Entries live as long as the host may deliver
# to them (free = NULL means no teardown callback): a connection-bound entry is
# unregistered when its connection closes (`Connection.close_transport` drops
# its hosted ids), a node-wide giftable lives for its host's lifetime, the same
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
    does not pin dead behaviors. Node-wide giftables (``conn is None``) are
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
        if hops > _MAX_LOCAL_FORWARD_HOPS:
            raise RuntimeError("forward cycle: the local forward chain never terminates")
        target = result.target
        inner = None
        if target.near is not None and entry.resolve_local is not None:
            inner = entry.resolve_local(target.near.id)
        if inner is None:
            return result
        entry = inner
        result = inner.run(result.verb, result.args)
    return result


# Bounds one turn's synchronous local Forward chain; hop N+1 breaks the
# answer instead of spinning.
_MAX_LOCAL_FORWARD_HOPS = 256


# The turn context while a hosted object's trampoline runs: the opaque
# PancakeHostTurn* and the connection the turn arrived on (None for a
# giftable), or None outside any turn. `Connection.spawn` reads it to pick the
# turn-time spawn over the top-level one (which the host refuses inside a
# callback); the action drain reads it to defer to the enclosing verb's
# unwind. A plain module variable is enough: behaviors are synchronous, so no
# task switch can happen between the set and the read.
_current_turn: "Optional[tuple[int, Optional[object]]]" = None


def _current_turn_for(conn: object) -> Optional[int]:
    """The current turn pointer when it belongs to connection ``conn``."""
    if _current_turn is not None and _current_turn[1] is conn:
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


def _settle_reply(entry: _BehaviorEntry, turn: int, result, out_reply) -> int:
    # Resolve a behavior's result into the turn's answer: a plain value (None
    # is the void ack) marshals into the reply slot; a `Forward` composes in
    # process when this side hosts the target, else defers through the host's
    # turn-forward.
    global _last_reply_keep
    result = _chase_local_forwards(entry, result)
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
    global _current_turn
    entry = _registry.get(ctx or 0)
    if entry is None:
        return _turn_break(turn, "no such hosted object")
    try:
        verb = ctypes.string_at(verb_ptr, verb_len).decode(errors="replace") if verb_len else ""
        args = [_lift_value(_arg_from_c(args_ptr[i])) for i in range(args_len)]
        prev = _current_turn
        _current_turn = (turn, entry.conn)
        try:
            return _settle_reply(entry, turn, entry.run(verb, args), out_reply)
        finally:
            _current_turn = prev
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
