"""Internal: the raw ``ctypes`` mirror of the ``pancake_host_*`` byte-fed
host family (ADR-0072), loaded from ``libpancake_host``.

Nothing here is public. The driver is a separate archive and exports only
``pancake_driver_*``; it adopts a Host created through this family. The Host
surface lives in :mod:`pancake._host` and :mod:`pancake._session`.

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
    _LocatorHintView,
    _LocatorView,
    _Lib,
    _ManagedFrame,
    _Reference,
)
from ._pin import pin_struct

# The trace record's digest is a fixed-width array, so its width is the
# reflected constant rather than a number retyped here.
from ._constants_gen import TRACE_DIGEST_BYTES
from ._lib_resolve import _lib_path

# The signature table is generated from the archive's annotated symbol
# inventory (``zig build gen-binding-python-ffi``); this module hands it the
# ``Structure`` and callback types declared here and in ``_ffi_ocapn``.
from ._sigs_gen import driver_sigs


class _CloseOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("pending", ctypes.c_uint32),
        ("grace_mode", ctypes.c_uint32),
        ("grace_ms", ctypes.c_uint32),
    ]


pin_struct(_CloseOptions, "PANCAKE_CLOSE_OPTIONS")


class _HostAction(ctypes.Structure):
    # PancakeHostAction (pancake_host.h) — hand-mirrored field-for-field
    # (Python has no layout generator), pinned by `_pin_layout()` below
    # against the header's documented layout. `kind`
    # selects the live fields; every popped byte view and `value`'s
    # sub-structure are host-owned and valid until the NEXT
    # pancake_host_next_action call.
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("ticket", ctypes.c_uint64),
        ("session", ctypes.c_void_p),
        ("value", _Argument),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
        ("result", ctypes.c_int32),
    ]


class _PartnerIdentity(ctypes.Structure):
    # PancakePartnerIdentity (pancake_host.h) — the verified partner identity
    # pancake_host_session_partner_identity borrows out. Every view is
    # session-owned and stays valid until the session is released; designator
    # and locator_record are NULL with a zero length when the partner's
    # location carried none.
    _fields_ = [
        ("session_key", ctypes.c_void_p),
        ("session_key_len", ctypes.c_size_t),
        ("designator", ctypes.c_void_p),
        ("designator_len", ctypes.c_size_t),
        ("locator_record", ctypes.c_void_p),
        ("locator_record_len", ctypes.c_size_t),
        # How the durable identity in `designator` was authenticated, one of
        # the DURABLE_PROVENANCE_* constants (ADR-0097).
        ("provenance", ctypes.c_uint32),
    ]


# The layout gate for the mirrors this module declares. _TraceEvent and
# _HostPumpHooks are declared further down (they need callback types stated
# first) and are pinned at their own declarations, so no mirror here sits
# outside the gate.
pin_struct(_HostAction, "PANCAKE_HOST_ACTION")
pin_struct(_PartnerIdentity, "PANCAKE_PARTNER_IDENTITY")


# The C callback type (pancake_host.h's PancakeHostBehavior):
#   int32_t (*)(void *ctx, PancakeHostTurn *turn, const uint8_t *verb,
#               size_t verb_len, const PancakeArgument *args, size_t args_len,
#               PancakeArgument *out_reply);
# The one shared instance lives in :mod:`pancake._trampoline`.
# PancakeTraceEvent — one live-trace fact (pancake_host_set_trace). Field
# order and widths mirror the generated header; the layout facts in
# ``_layouts_gen`` pin them.
class _TraceEvent(ctypes.Structure):
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("session", ctypes.c_uint64),
        ("outbound", ctypes.c_uint8),
        ("provenance", ctypes.c_uint32),
        ("codec", ctypes.c_uint32),
        ("captp_version", ctypes.c_uint32),
        ("designator", ctypes.POINTER(ctypes.c_uint8)),
        ("designator_len", ctypes.c_size_t),
        ("transport", ctypes.POINTER(ctypes.c_uint8)),
        ("transport_len", ctypes.c_size_t),
        ("session_id", ctypes.POINTER(ctypes.c_uint8)),
        ("session_id_len", ctypes.c_size_t),
        ("verb", ctypes.POINTER(ctypes.c_uint8)),
        ("verb_len", ctypes.c_size_t),
        ("frame", ctypes.POINTER(ctypes.c_uint8)),
        ("frame_len", ctypes.c_size_t),
        ("frame_total_len", ctypes.c_size_t),
        ("dropped", ctypes.c_uint64),
        ("digest", ctypes.c_uint8 * TRACE_DIGEST_BYTES),
    ]


pin_struct(_TraceEvent, "PANCAKE_TRACE_EVENT")


# PancakeTraceCallback — void (*)(void *ctx, const PancakeTraceEvent *event).
_TraceCallback = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(_TraceEvent))


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


pin_struct(_HostPumpHooks, "PANCAKE_HOST_PUMP_HOOKS")


def _load():
    sigs = driver_sigs(
        _Argument,
        _Reference,
        _ManagedFrame,
        _LastAbort,
        _HostPumpHooks,
        _LocatorHintView,
        _LocatorView,
        _HostBehavior,
        _PartnerIdentity,
        _TraceCallback,
        _CloseOptions,
    )
    lib = ctypes.CDLL(str(_lib_path("pancake_host")))
    facade = _Lib(lib)
    _bind(facade, lib, sigs)
    return facade


_host = _load()
