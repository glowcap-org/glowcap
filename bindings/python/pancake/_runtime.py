"""ctypes bindings for ``libpancake_ffi_runtime`` — the protocol core.

Mirrors ``crates/ffi/pancake-ffi-runtime/include/pancake.h``: peer lifecycle,
step / queues, typed send / receive, keypair, OCapN-URI parse, syrup
frame-probe, and cross-peer coordination.

This module is purely the FFI surface (``argtypes`` / ``restype`` per
function). High-level wrappers live in :mod:`pancake.host`.
"""

from __future__ import annotations

import ctypes
from ctypes import (
    POINTER,
    c_char_p,
    c_int32,
    c_int64,
    c_size_t,
    c_uint8,
    c_uint32,
    c_uint64,
    c_void_p,
)

from . import _abi
from .values import (
    PancakeArgument,
    PancakeReference,
    PancakeResolution,
    PancakeStepOutcome,
)

_P = c_void_p  # opaque handle pointer


class RuntimeLib:
    """Holds the loaded runtime cdylib + its bound functions."""

    def __init__(self, lib: ctypes.CDLL):
        self.lib = lib
        self.last_error, self.clear_last_error = _abi.bind_last_error(lib)
        self._bind()

    def _bind(self) -> None:
        lib = self.lib

        def fn(name, argtypes, restype):
            f = getattr(lib, name)
            f.argtypes = argtypes
            f.restype = restype
            setattr(self, name, f)

        # Library metadata.
        fn("pancake_version", [], c_char_p)

        # Keypair lifecycle.
        fn("pancake_keypair_new", [], _P)
        fn("pancake_keypair_from_seed", [POINTER(c_uint8), c_size_t], _P)
        fn("pancake_keypair_free", [_P], None)
        fn("pancake_keypair_pubkey", [_P, POINTER(c_uint8)], c_int32)

        # Peer lifecycle.
        fn("pancake_peer_new", [_P, c_uint32], _P)
        fn(
            "pancake_peer_new_advanced",
            [c_char_p, c_char_p, c_uint32, c_uint32, _P],
            _P,
        )
        fn("pancake_peer_free", [_P], None)
        fn("pancake_peer_shutdown", [_P], None)
        fn("pancake_peer_get_my_peer_id", [_P, POINTER(c_uint8)], c_int32)
        fn("pancake_peer_get_partner_peer_id", [_P, POINTER(c_uint8)], c_int32)
        fn(
            "pancake_peer_register_bootstrap_cap",
            [_P, POINTER(c_uint8), c_size_t, c_uint64],
            c_int32,
        )
        fn("pancake_peer_register_export", [_P, c_uint64], c_int32)

        # Step + queues.
        fn("pancake_peer_step", [_P, POINTER(PancakeStepOutcome)], c_int32)
        # Inbound borrows a bare PancakeFrame for the call (zero-copy);
        # outbound hands back a self-describing PancakeManagedFrame
        # released via the shared pancake_managed_frame_release (abi seam).
        fn("pancake_peer_feed_inbound", [_P, POINTER(_abi.PancakeFrame)], c_int32)
        fn("pancake_peer_take_outbound", [_P, POINTER(_abi.PancakeManagedFrame)], c_int32)
        fn("pancake_managed_frame_release", [POINTER(_abi.PancakeManagedFrame)], None)
        fn("pancake_peer_peek_event_kind", [_P, POINTER(c_uint32)], c_int32)
        fn("pancake_peer_consume_event", [_P], c_int32)
        fn("pancake_peer_session_state", [_P, POINTER(c_uint32)], c_int32)
        fn("pancake_peer_has_outbound", [_P], c_int32)
        fn("pancake_peer_has_event", [_P], c_int32)

        # Typed send.
        fn(
            "pancake_peer_send_deliver",
            [_P, POINTER(PancakeReference), POINTER(PancakeArgument), c_size_t, c_uint64],
            c_int32,
        )
        fn(
            "pancake_peer_send_resolve",
            [_P, c_uint64, POINTER(PancakeResolution)],
            c_int32,
        )
        fn(
            "pancake_peer_send_abort",
            [_P, c_uint32, c_char_p, c_size_t],
            c_int32,
        )
        fn(
            "pancake_peer_send_start_session",
            [_P, c_char_p, c_char_p],
            c_int32,
        )
        fn(
            "pancake_peer_enliven_sturdyref",
            [_P, POINTER(PancakeReference)],
            c_int32,
        )

        # Typed receive.
        fn(
            "pancake_peer_poll_event_deliver",
            [
                _P,
                POINTER(PancakeReference),
                POINTER(POINTER(PancakeArgument)),
                POINTER(c_size_t),
                POINTER(c_uint64),
                POINTER(PancakeReference),
            ],
            c_int32,
        )
        fn("pancake_typed_resolve_me_desc_free", [POINTER(PancakeReference)], None)
        fn(
            "pancake_peer_poll_event_resolve",
            [_P, POINTER(c_uint64), POINTER(PancakeResolution)],
            c_int32,
        )
        fn(
            "pancake_peer_poll_event_abort",
            [_P, POINTER(c_uint32), POINTER(POINTER(c_uint8)), POINTER(c_size_t)],
            c_int32,
        )
        fn(
            "pancake_peer_poll_event_session_established",
            [_P, POINTER(c_uint8), POINTER(POINTER(c_uint8)), POINTER(c_size_t)],
            c_int32,
        )

        # Typed-receive free helpers.
        fn("pancake_typed_args_free", [POINTER(PancakeArgument), c_size_t], None)
        fn("pancake_typed_resolution_free", [POINTER(PancakeResolution)], None)
        fn("pancake_typed_abort_message_free", [POINTER(c_uint8), c_size_t], None)
        fn("pancake_typed_partner_locator_free", [POINTER(c_uint8), c_size_t], None)

        # OCapN URI parse.
        fn("pancake_ocapn_uri_parse", [c_char_p], _P)
        fn("pancake_ocapn_uri_free", [_P], None)

        # Syrup frame probe.
        fn(
            "pancake_syrup_frame_probe",
            [POINTER(c_uint8), c_size_t, POINTER(c_size_t), c_size_t],
            c_int32,
        )

        # Cross-peer.
        fn("pancake_sturdyref_dedup_new", [], _P)
        fn("pancake_sturdyref_dedup_free", [_P], None)
        fn("pancake_cross_peer_drain_relayed_resolutions", [_P], c_int32)
        fn(
            "pancake_cross_peer_absorb_pending_sturdyref_enlivens",
            [_P, _P],
            c_int32,
        )
        fn(
            "pancake_cross_peer_cache_settled_sturdyref_enlivens",
            [_P, _P],
            c_int32,
        )


def load() -> RuntimeLib:
    return RuntimeLib(_abi.load_library(_abi.ENV_RUNTIME, "pancake-ffi-runtime"))
