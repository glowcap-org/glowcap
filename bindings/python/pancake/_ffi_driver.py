"""Internal: the raw ``ctypes`` mirror of ``libpancake_driver``, the byte-fed
host archive (ADR-0072).

Nothing here is public. The archive is a companion of ``libpancake_ocapn``: it
exports only the ``pancake_host_*`` family and shares the frame, argument,
reference, and last-abort layouts declared in :mod:`pancake._ffi_ocapn` by
*layout*, so this loader opens ONLY ``libpancake_driver`` and declares no core
symbol, exactly as :mod:`pancake._ffi_tcp` does. The host surface over it lives
in :mod:`pancake._host` and :mod:`pancake._session`.

Callback discipline: the ONE native callback in the whole binding — the shared
behavior trampoline (:mod:`pancake._trampoline`) — fires synchronously on the
thread executing the enclosing ``pancake_host_*`` call, with ctypes
re-acquiring the GIL for it. Settlements carry no callback at all: they ride
the action queue as SETTLE/FAIL and the drain routes them by vow id
(:mod:`pancake._host`). ``fetch``/``enliven``/``send`` and the ``vow_*`` verbs
each mint a host vow whose id lands in the trailing out-param; the outcome
arrives as that vow's SETTLE/FAIL action. The ``free`` parameter of
publish/spawn is always NULL from this binding: the Python side owns its
behavior entries in the trampoline registry, so there is nothing for the
library to free.
"""

from __future__ import annotations

import ctypes

from ._ffi_ocapn import (
    _Argument,
    _bind,
    _LastAbort,
    _Lib,
    _ManagedFrame,
    _Reference,
)
from ._layouts_gen import (
    PANCAKE_DIAL_PLAN_ADDRESSES_LEN_OFF,
    PANCAKE_DIAL_PLAN_ADDRESSES_OFF,
    PANCAKE_DIAL_PLAN_HOST_LEN_OFF,
    PANCAKE_DIAL_PLAN_HOST_OFF,
    PANCAKE_DIAL_PLAN_PORT_OFF,
    PANCAKE_DIAL_PLAN_REACH_KIND_OFF,
    PANCAKE_DIAL_PLAN_REACH_VALUE_OFF,
    PANCAKE_DIAL_PLAN_SHAPE_OFF,
    PANCAKE_DIAL_PLAN_SIZE,
    PANCAKE_HOST_ACTION_DESIGNATOR_LEN_OFF,
    PANCAKE_HOST_ACTION_DESIGNATOR_OFF,
    PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_LEN_OFF,
    PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_OFF,
    PANCAKE_HOST_ACTION_KIND_OFF,
    PANCAKE_HOST_ACTION_LOCATOR_LEN_OFF,
    PANCAKE_HOST_ACTION_LOCATOR_OFF,
    PANCAKE_HOST_ACTION_MESSAGE_LEN_OFF,
    PANCAKE_HOST_ACTION_MESSAGE_OFF,
    PANCAKE_HOST_ACTION_SESSION_OFF,
    PANCAKE_HOST_ACTION_SIZE,
    PANCAKE_HOST_ACTION_TICKET_OFF,
    PANCAKE_HOST_ACTION_TRANSPORT_LEN_OFF,
    PANCAKE_HOST_ACTION_TRANSPORT_OFF,
    PANCAKE_HOST_ACTION_VALUE_OFF,
    PANCAKE_HOST_PUMP_HOOKS_SIZE,
)
from ._lib_resolve import _lib_path



class _HostAction(ctypes.Structure):
    # PancakeHostAction (pancake_driver.h) — hand-mirrored field-for-field
    # (Python has no layout generator), pinned by `_pin_layout()` below
    # against the header's documented layout. `kind`
    # selects the live fields; every popped byte view and `value`'s
    # sub-structure are host-owned and valid until the NEXT
    # pancake_host_next_action call.
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("ticket", ctypes.c_uint64),
        ("conn", ctypes.c_void_p),
        ("locator", ctypes.c_void_p),
        ("locator_len", ctypes.c_size_t),
        ("transport", ctypes.c_void_p),
        ("transport_len", ctypes.c_size_t),
        ("designator", ctypes.c_void_p),
        ("designator_len", ctypes.c_size_t),
        ("direct_addresses_hint", ctypes.c_void_p),
        ("direct_addresses_hint_len", ctypes.c_size_t),
        ("value", _Argument),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
    ]


class _DialPlan(ctypes.Structure):
    # PancakeDialPlan (pancake_driver.h) — the resolved dial pancake_host_plan_dial
    # hands back: `shape` selects the live fields (HOST_PORT fills host/port, IROH
    # fills addresses/reach). host/addresses borrow the caller's input buffers.
    _fields_ = [
        ("shape", ctypes.c_uint32),
        ("host", ctypes.c_void_p),
        ("host_len", ctypes.c_size_t),
        ("port", ctypes.c_uint16),
        ("addresses", ctypes.c_void_p),
        ("addresses_len", ctypes.c_size_t),
        ("reach_kind", ctypes.c_uint32),
        ("reach_value", ctypes.c_uint32),
    ]


def _pin_layout() -> None:
    # The layout gate, the Rust mirror's `const` assert block made Pythonic
    # (bindings/rust/src/sys/driver.rs): the hand-mirrored struct is pinned at
    # import time against the sizes and offsets `_layouts_gen` reflects off
    # the real Zig C ABI types — so the gate catches a mirror that drifts
    # from its documented layout, not a C-side change that updates neither;
    # the dogfoods defend that behaviorally. A plain `raise` rather than
    # `assert`, so `python -O` cannot strip the gate.
    # The shared _Reference/_Argument sizes are pinned where they are
    # declared (_ffi_ocapn._pin_layout); this pin owns only _HostAction,
    # this module's own declaration.
    got_size = ctypes.sizeof(_HostAction)
    if got_size != PANCAKE_HOST_ACTION_SIZE:
        raise ImportError(
            f"pancake FFI layout drift: sizeof(_HostAction) == {got_size}, "
            f"expected {PANCAKE_HOST_ACTION_SIZE}; re-mirror the struct"
        )
    expected_offsets = (
        ("kind", PANCAKE_HOST_ACTION_KIND_OFF),
        ("ticket", PANCAKE_HOST_ACTION_TICKET_OFF),
        ("conn", PANCAKE_HOST_ACTION_SESSION_OFF),
        ("locator", PANCAKE_HOST_ACTION_LOCATOR_OFF),
        ("locator_len", PANCAKE_HOST_ACTION_LOCATOR_LEN_OFF),
        ("transport", PANCAKE_HOST_ACTION_TRANSPORT_OFF),
        ("transport_len", PANCAKE_HOST_ACTION_TRANSPORT_LEN_OFF),
        ("designator", PANCAKE_HOST_ACTION_DESIGNATOR_OFF),
        ("designator_len", PANCAKE_HOST_ACTION_DESIGNATOR_LEN_OFF),
        ("direct_addresses_hint", PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_OFF),
        ("direct_addresses_hint_len", PANCAKE_HOST_ACTION_DIRECT_ADDRESSES_HINT_LEN_OFF),
        ("value", PANCAKE_HOST_ACTION_VALUE_OFF),
        ("message", PANCAKE_HOST_ACTION_MESSAGE_OFF),
        ("message_len", PANCAKE_HOST_ACTION_MESSAGE_LEN_OFF),
    )
    for name, want in expected_offsets:
        got = getattr(_HostAction, name).offset
        if got != want:
            raise ImportError(
                f"pancake FFI layout drift: _HostAction.{name} at offset {got}, "
                f"expected {want}; re-mirror the struct"
            )
    plan_size = ctypes.sizeof(_DialPlan)
    if plan_size != PANCAKE_DIAL_PLAN_SIZE:
        raise ImportError(
            f"pancake FFI layout drift: sizeof(_DialPlan) == {plan_size}, "
            f"expected {PANCAKE_DIAL_PLAN_SIZE}; re-mirror the struct"
        )
    for name, want in (
        ("shape", PANCAKE_DIAL_PLAN_SHAPE_OFF),
        ("host", PANCAKE_DIAL_PLAN_HOST_OFF),
        ("host_len", PANCAKE_DIAL_PLAN_HOST_LEN_OFF),
        ("port", PANCAKE_DIAL_PLAN_PORT_OFF),
        ("addresses", PANCAKE_DIAL_PLAN_ADDRESSES_OFF),
        ("addresses_len", PANCAKE_DIAL_PLAN_ADDRESSES_LEN_OFF),
        ("reach_kind", PANCAKE_DIAL_PLAN_REACH_KIND_OFF),
        ("reach_value", PANCAKE_DIAL_PLAN_REACH_VALUE_OFF),
    ):
        got = getattr(_DialPlan, name).offset
        if got != want:
            raise ImportError(
                f"pancake FFI layout drift: _DialPlan.{name} at offset {got}, "
                f"expected {want}; re-mirror the struct"
            )


_pin_layout()


# The C callback type (pancake_driver.h's PancakeHostBehavior):
#   int32_t (*)(void *ctx, PancakeHostTurn *turn, const uint8_t *verb,
#               size_t verb_len, const PancakeArgument *args, size_t args_len,
#               PancakeArgument *out_reply);
# The one shared instance lives in :mod:`pancake._trampoline`.
_HostBehavior = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.POINTER(_Argument),
    ctypes.c_size_t,
    ctypes.POINTER(_Argument),
)

# PancakeHostPumpArmFn / PancakeHostPumpHooks — sync arms for
# pancake_host_pump_drain; bindings park decoded actions and await after.
_HostPumpArmFn = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.POINTER(_HostAction),
    ctypes.POINTER(ctypes.c_uint32),
)


class _HostPumpHooks(ctypes.Structure):
    _fields_ = [
        ("ctx", ctypes.c_void_p),
        ("flush", _HostPumpArmFn),
        ("close", _HostPumpArmFn),
        ("need_gift_id", _HostPumpArmFn),
        ("complete", _HostPumpArmFn),
        ("dial", _HostPumpArmFn),
    ]


_hooks_size = ctypes.sizeof(_HostPumpHooks)
if _hooks_size != PANCAKE_HOST_PUMP_HOOKS_SIZE:
    raise ImportError(
        f"pancake FFI layout drift: sizeof(_HostPumpHooks) == {_hooks_size}, "
        f"expected {PANCAKE_HOST_PUMP_HOOKS_SIZE}; re-mirror the struct"
    )


def _load():
    P = ctypes.c_void_p
    size = ctypes.c_size_t
    u32 = ctypes.c_uint32
    u64 = ctypes.c_uint64
    i32 = ctypes.c_int32
    u64_p = ctypes.POINTER(u64)
    size_p = ctypes.POINTER(size)
    arg_p = ctypes.POINTER(_Argument)
    ref_p = ctypes.POINTER(_Reference)
    sigs = {
        # Lifecycle.
        "pancake_host_new": ([P, size, size, u32, u32, u32, ctypes.POINTER(P)], i32),
        "pancake_host_new_in": ([P, P, size, size, u32, u32, u32, ctypes.POINTER(P)], i32),
        "pancake_host_release": ([P], None),
        "pancake_host_designator_from_seed": ([P, size, P, size], i32),
        "pancake_host_set_self_designator": ([P, P, size], i32),
        "pancake_host_set_session_limits": ([P, size, size], i32),
        "pancake_host_session_open_dialed_locator": ([P, P, size, P, size, ctypes.POINTER(P)], i32),
        # Resolve a dial to a _DialPlan (grammar + hint + iroh posture); free function.
        "pancake_host_plan_dial": ([P, size, P, size, P, size, u32, u32, ctypes.POINTER(_DialPlan)], i32),
        "pancake_host_session_open_accepted": ([P, P, size, P, size, P, size, ctypes.POINTER(P)], i32),
        "pancake_host_session_release": ([P], None),
        "pancake_host_session_session_open": ([P], i32),
        # The byte pump and action queue.
        "pancake_host_session_feed_bytes": ([P, P, size, size_p], i32),
        "pancake_host_session_take_outbound": ([P, ctypes.POINTER(_ManagedFrame)], i32),
        "pancake_host_next_action": ([P, ctypes.POINTER(_HostAction)], i32),
        "pancake_host_pump_drain": ([P, ctypes.POINTER(_HostPumpHooks), ctypes.POINTER(u32)], i32),
        "pancake_host_dialed": ([P, u64, P], i32),
        "pancake_host_dial_failed": ([P, u64, P, size], i32),
        "pancake_host_provide_gift_id": ([P, u64, P, size], i32),
        # Publish and spawn (behavior = the shared trampoline, ctx = the Python
        # registry id packed as a pointer-sized integer, free = NULL).
        "pancake_host_session_publish": ([P, P, size, _HostBehavior, P, P, u64_p], i32),
        "pancake_host_session_spawn": ([P, _HostBehavior, P, P, u64_p], i32),
        "pancake_host_publish": ([P, P, size, _HostBehavior, P, P], i32),
        # Fetch and enliven — each mints a host vow (out param).
        "pancake_host_session_fetch": ([P, P, size, u64_p], i32),
        "pancake_host_session_enliven": ([P, P, size, u64_p], i32),
        # Send, tell, vows, projections.
        "pancake_host_session_send": ([P, ref_p, P, size, arg_p, size, u64_p], i32),
        "pancake_host_session_tell": ([P, ref_p, P, size, arg_p, size], i32),
        "pancake_host_vow_send": ([P, u64, P, size, arg_p, size, u64_p], i32),
        "pancake_host_vow_index": ([P, u64, u64, u64_p], i32),
        "pancake_host_vow_untag": ([P, u64, P, size, u64_p], i32),
        # Turn verbs (legal only inside a behavior callback). `turn_forward`'s
        # out-reply is the raw pointer the trampoline was handed.
        "pancake_host_turn_forward": ([P, ref_p, P, size, arg_p, size, arg_p], i32),
        "pancake_host_turn_spawn": ([P, _HostBehavior, P, P, u64_p], i32),
        "pancake_host_turn_break": ([P, P, size], i32),
        # GC, teardown, diagnostics.
        "pancake_host_gc_release": ([P, u64, u64], i32),
        "pancake_host_session_break_far_vows": ([P, P, size], i32),
        "pancake_host_session_set_exporter_location": ([P, P, size], i32),
        "pancake_host_session_last_abort": ([P, ctypes.POINTER(_LastAbort)], i32),
        "pancake_host_last_error": ([ctypes.POINTER(ctypes.c_uint8), size], size),
    }
    lib = ctypes.CDLL(str(_lib_path("pancake_driver")))
    facade = _Lib(lib)
    _bind(facade, lib, sigs)
    return facade


_host = _load()
