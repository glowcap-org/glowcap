"""Internal: the raw ``ctypes`` mirror of the ``glowcap_driver_*`` loop
family (ADR-0112).

Nothing here is public. ``libglowcap_driver`` exports only this family and
adopts a Host from the separate ``libglowcap_host`` archive. Its stepping
loop owns transports, sockets, and pumping, so the binding's
transport role collapses to parking on one readiness descriptor, stepping,
and draining one event queue. The asyncio wrapper over this tier lives in
:mod:`glowcap._loop`.

Transport archives fill the small ``_TransportProvider`` package header. The
driver copies its private implementation tables, so Python never mirrors or
interprets an execution-model vtable.
"""

from __future__ import annotations

import ctypes

from ._ffi_host import _CloseOptions, _HostAction
from ._ffi_ocapn import _bind, _Lib, _LocatorView, _Reference
from ._archive_contract import require_archive_fingerprint
from ._constants_gen import DRIVER_ARCHIVE_FINGERPRINT
from ._lib_resolve import _lib_path
from ._pin import pin_struct
from ._sigs_gen import loop_sigs


class _DriverOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("wire_buffer_bytes", ctypes.c_size_t),
        ("max_pending_opens", ctypes.c_size_t),
        ("handshake_ms", ctypes.c_uint32),
        ("listener_setup_ms", ctypes.c_uint32),
        ("settle_ms", ctypes.c_uint32),
    ]


pin_struct(_DriverOptions, "GLOWCAP_DRIVER_OPTIONS")


class _DriverFailure(ctypes.Structure):
    """Caller-owned deterministic provider/install and loop-release outcome."""

    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("primary_result", ctypes.c_int32),
        ("secondary_result", ctypes.c_int32),
        ("secondary_count", ctypes.c_uint32),
        ("carrier_phase", ctypes.c_uint32),
        ("carrier_detail_flags", ctypes.c_uint32),
        ("carrier_verification_flags", ctypes.c_uint32),
        ("carrier_peer_alert", ctypes.c_uint32),
        ("carrier_engine_code", ctypes.c_int32),
        ("primary_name", ctypes.c_void_p),
        ("primary_name_len", ctypes.c_size_t),
        ("secondary_name", ctypes.c_void_p),
        ("secondary_name_len", ctypes.c_size_t),
    ]


pin_struct(_DriverFailure, "GLOWCAP_DRIVER_FAILURE")


class _DriverEvent(ctypes.Structure):
    # GlowcapDriverEvent (glowcap_driver.h) — one drained loop event. `kind`
    # selects the live fields; failure names and the views inside `action` are
    # loop-owned and valid until the NEXT glowcap_driver_next_event call.
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("primary_result", ctypes.c_int32),
        ("secondary_result", ctypes.c_int32),
        ("secondary_count", ctypes.c_uint32),
        ("carrier_phase", ctypes.c_uint32),
        ("carrier_detail_flags", ctypes.c_uint32),
        ("carrier_verification_flags", ctypes.c_uint32),
        ("carrier_peer_alert", ctypes.c_uint32),
        ("carrier_engine_code", ctypes.c_int32),
        ("operation_id", ctypes.c_uint64),
        ("listener_id", ctypes.c_uint64),
        ("session", ctypes.c_void_p),
        ("action", _HostAction),
        ("primary_name", ctypes.c_void_p),
        ("primary_name_len", ctypes.c_size_t),
        ("secondary_name", ctypes.c_void_p),
        ("secondary_name_len", ctypes.c_size_t),
    ]


pin_struct(_DriverEvent, "GLOWCAP_DRIVER_EVENT")


class _TransportProvider(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_size_t),
        ("entries", ctypes.c_void_p),
        ("entry_count", ctypes.c_size_t),
        ("lease_ctx", ctypes.c_void_p),
        ("same_configuration", ctypes.c_void_p),
        ("retain", ctypes.c_void_p),
        ("release", ctypes.c_void_p),
    ]


pin_struct(_TransportProvider, "GLOWCAP_TRANSPORT_PROVIDER")


class _TransportOperationOptions(ctypes.Structure):
    _fields_ = [
        ("data", ctypes.c_void_p),
        ("size", ctypes.c_size_t),
    ]


pin_struct(_TransportOperationOptions, "GLOWCAP_TRANSPORT_OPERATION_OPTIONS")


def _load():
    sigs = loop_sigs(
        _DriverOptions,
        _DriverFailure,
        _CloseOptions,
        _DriverEvent,
        _LocatorView,
        _Reference,
        _TransportOperationOptions,
        _TransportProvider,
    )
    lib = ctypes.CDLL(str(_lib_path("glowcap_driver")))
    require_archive_fingerprint(
        lambda: lib.glowcap_driver_archive_fingerprint,
        "driver",
        DRIVER_ARCHIVE_FINGERPRINT,
    )
    facade = _Lib(lib)
    _bind(facade, lib, sigs)
    return facade


_driver = _load()
