"""Internal: the raw ``ctypes`` mirror of the ``glowcap_host_*`` byte-fed
host family (ADR-0022), loaded from ``libglowcap_host``.

Nothing here is public. The driver is a separate archive and exports only
``glowcap_driver_*``. It adopts a Host created through this family. The Host
surface lives in :mod:`glowcap._host` and :mod:`glowcap._session`.

Callback discipline: the ONE FFI callback in the whole binding, the shared
behavior trampoline (:mod:`glowcap._trampoline`), fires synchronously on the
thread executing the enclosing ``glowcap_host_*`` call, with ctypes
re-acquiring the GIL for it. Settlements carry no callback at all: they ride
the action queue as SETTLE/FAIL and the drain routes them by vow id
(:mod:`glowcap._host`). ``fetch``/``enliven``/``send`` and the ``vow_*`` verbs
each mint a host vow whose id lands in the trailing out-param. The outcome
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
from ._constants_gen import HOST_ARCHIVE_FINGERPRINT, TRACE_DIGEST_BYTES
from ._archive_contract import require_archive_fingerprint
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


pin_struct(_CloseOptions, "GLOWCAP_CLOSE_OPTIONS")


class _SessionLimitOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("max_frame_bytes", ctypes.c_size_t),
        ("queue_cap", ctypes.c_size_t),
        ("outbound_high_water_bytes", ctypes.c_size_t),
        ("max_retained_sent_answer_bytes", ctypes.c_size_t),
        ("max_sessions", ctypes.c_size_t),
    ]


pin_struct(_SessionLimitOptions, "GLOWCAP_SESSION_LIMIT_OPTIONS")


class _HostAction(ctypes.Structure):
    # GlowcapHostAction (glowcap_host.h): hand-mirrored field-for-field,
    # pinned by `pin_struct` below against the generated layout facts. `kind`
    # selects the live fields; every popped byte view and `value`'s
    # sub-structure are host-owned and valid until the NEXT
    # glowcap_host_next_action call.
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("ticket", ctypes.c_uint64),
        ("route_index", ctypes.c_size_t),
        ("session", ctypes.c_void_p),
        ("value", _Argument),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
        ("result", ctypes.c_int32),
    ]


class _PartnerIdentity(ctypes.Structure):
    # GlowcapPartnerIdentity (glowcap_host.h): the verified partner identity
    # glowcap_host_session_partner_identity borrows out. Every view is
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
        # the DURABLE_PROVENANCE_* constants (ADR-0028).
        ("provenance", ctypes.c_uint32),
    ]


# The layout gate for the mirrors this module declares. _TraceEvent and
# _HostPumpHooks are declared further down (they need callback types stated
# first) and are pinned at their own declarations, so no mirror here sits
# outside the gate.
pin_struct(_HostAction, "GLOWCAP_HOST_ACTION")
pin_struct(_PartnerIdentity, "GLOWCAP_PARTNER_IDENTITY")


# The C callback type (glowcap_host.h's GlowcapHostBehavior):
#   int32_t (*)(void *ctx, GlowcapHostTurn *turn, const uint8_t *verb,
#               size_t verb_len, const GlowcapArgument *args, size_t args_len,
#               GlowcapArgument *out_reply);
# The one shared instance lives in :mod:`glowcap._trampoline`.
# GlowcapTraceEvent: one live-trace fact (glowcap_host_set_trace). Field
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


pin_struct(_TraceEvent, "GLOWCAP_TRACE_EVENT")


# GlowcapTraceCallback: void (*)(void *ctx, const GlowcapTraceEvent *event).
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

# GlowcapHostPumpArmFn / GlowcapHostPumpHooks: sync arms for
# glowcap_host_pump_drain; bindings park decoded actions and await after.
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


pin_struct(_HostPumpHooks, "GLOWCAP_HOST_PUMP_HOOKS")


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
        _SessionLimitOptions,
    )
    lib = ctypes.CDLL(str(_lib_path("glowcap_host")))
    require_archive_fingerprint(
        lambda: lib.glowcap_host_archive_fingerprint,
        "host",
        HOST_ARCHIVE_FINGERPRINT,
    )
    facade = _Lib(lib)
    _bind(facade, lib, sigs)
    return facade


_host = _load()


def _selector_buf(verb: str | None):
    """Borrow a selector; None is direct invocation, including with no args."""
    if verb is None:
        return None, None, 0
    from ._ffi_ocapn import _byte_buf

    data = verb.encode()
    owner, ptr = _byte_buf(data)
    return owner, ptr, len(data)
