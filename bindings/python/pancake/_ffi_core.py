"""Internal: the raw ``ctypes`` mirror of ``libpancake_ocapn``, the core
archive.

Nothing here is public. The ergonomic surface in :mod:`pancake` reaches the
symbols through ``_lib`` and the ctypes ``Structure`` types this module
defines; a consumer never imports this module. Keeping the ctypes layer in one
internal module per archive is what lets the public package read as just the
peer/value/event API it offers.

This module loads exactly one archive, ``libpancake_ocapn`` (ADR-0059): the
core ``pancake_*`` family — context, peer, frame, value/event, the locator
grammar, the ABI version, and ``pancake_last_error``. The transport archives
are symbol-disjoint companions, each loaded by its own internal module
(:mod:`pancake._ffi_tcp`, :mod:`pancake._ffi_inproc`,
:mod:`pancake._ffi_iroh`). They reuse the ``Structure`` types defined here by
*layout* — the same way the C headers share ``pancake_ocapn.h`` — so importing
:mod:`pancake` never loads a transport archive, and importing one transport
never loads another.
"""

from __future__ import annotations

import ctypes
import os
import pathlib
import sys


# The dynamic library's name is platform-specific: `.dylib` on macOS, `.dll` on
# Windows, `.so` elsewhere. `zig build` emits the right one into zig-out/lib.
def _lib_file(stem: str) -> str:
    return (
        f"lib{stem}.dylib" if sys.platform == "darwin"
        else f"{stem}.dll" if sys.platform == "win32"
        else f"lib{stem}.so"
    )


# The directory to load archives from, or None to use a bare name (OS search).
# The cascade every pancake binding shares: an explicit ``PANCAKE_LIB_DIR``
# override (configure) wins, else the repo's ``zig-out/lib`` build output when
# running in-tree (the dev fallback). The cached-download "ship" leg drops in
# between these two later without a rewrite.
def _lib_dir() -> pathlib.Path | None:
    override = os.environ.get("PANCAKE_LIB_DIR")
    if override:
        return pathlib.Path(override)
    dev = pathlib.Path(__file__).resolve().parents[3] / "zig-out" / "lib"
    return dev if dev.is_dir() else None


# Resolve an archive: an explicit path under the resolved directory, or — when no
# directory is known (an installed lib) — the bare library name, which ctypes
# hands to the OS dynamic-linker search (find). Each archive is loaded by its own
# internal module through this one helper, so they resolve consistently.
def _lib_path(stem: str) -> str:
    name = _lib_file(stem)
    directory = _lib_dir()
    return str(directory / name) if directory is not None else name


# ── Raw ctypes layer (private) ───────────────────────────────────────────────


class _Reference(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("sub_kind", ctypes.c_uint32), ("id", ctypes.c_uint64)]


class _Argument(ctypes.Structure):
    pass


_Argument._fields_ = [
    ("kind", ctypes.c_uint32),
    ("boolean", ctypes.c_uint32),
    ("integer", ctypes.c_int64),
    ("float64", ctypes.c_double),
    ("bytes", ctypes.c_void_p),
    ("bytes_len", ctypes.c_size_t),
    ("reference", _Reference),
    ("items", ctypes.POINTER(_Argument)),
    ("items_len", ctypes.c_size_t),
]


class _Frame(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_void_p), ("len", ctypes.c_size_t), ("shape", ctypes.c_uint32)]


class _ManagedFrame(ctypes.Structure):
    _fields_ = [
        ("bytes", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
        ("shape", ctypes.c_uint32),
        ("release", ctypes.c_void_p),
        ("private_data", ctypes.c_void_p),
    ]


class _Event(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_uint32), ("frame", _ManagedFrame)]


# The release callback a managed frame carries: void (*)(PancakeManagedFrame*).
_ManagedFrameRelease = ctypes.CFUNCTYPE(None, ctypes.POINTER(_ManagedFrame))

# Host allocator callbacks:
#   void *(*alloc)(void *user_data, size_t size, size_t alignment);
#   void  (*free )(void *user_data, void *ptr, size_t size, size_t alignment);
_AllocFn = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)
_FreeFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t)


class _Allocator(ctypes.Structure):
    _fields_ = [("alloc", _AllocFn), ("free", _FreeFn), ("user_data", ctypes.c_void_p)]


class _Deliver(ctypes.Structure):
    _fields_ = [
        ("target", _Reference),
        ("args", ctypes.POINTER(_Argument)),
        ("args_len", ctypes.c_size_t),
        ("has_answer", ctypes.c_uint32),
        ("answer", ctypes.c_uint64),
        ("owner", ctypes.c_void_p),
    ]


class _HandoffGive(ctypes.Structure):
    # PancakeHandoffGive: set on a _HANDOFF resolution. Carried by value inside
    # PancakeResolve, so its size is part of that struct's layout even when the
    # binding never reads a handoff, omitting it makes _Resolve too small and
    # pancake_peer_poll_event_resolve overflows the buffer.
    _fields_ = [
        ("give", ctypes.c_void_p),
        ("give_len", ctypes.c_size_t),
        ("exporter_locator", ctypes.c_void_p),
        ("exporter_locator_len", ctypes.c_size_t),
        ("recipient_key", ctypes.c_void_p),
        ("recipient_key_len", ctypes.c_size_t),
    ]


class _Resolve(ctypes.Structure):
    _fields_ = [
        ("answer", ctypes.c_uint64),
        ("resolution_kind", ctypes.c_uint32),
        ("fulfill", _Argument),
        ("break_message", ctypes.c_void_p),
        ("break_message_len", ctypes.c_size_t),
        ("handoff", _HandoffGive),
        ("owner", ctypes.c_void_p),
    ]


class _EnlivenStart(ctypes.Structure):
    _fields_ = [
        ("status", ctypes.c_uint32),
        ("kind", ctypes.c_uint32),
        ("answer", ctypes.c_uint64),
        ("import_position", ctypes.c_uint64),
    ]


class _LastAbort(ctypes.Structure):
    _fields_ = [
        ("domain", ctypes.c_uint32),
        ("has_kind", ctypes.c_uint32),
        ("kind_name", ctypes.c_void_p),
        ("kind_name_len", ctypes.c_size_t),
        ("message", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
        ("error_name", ctypes.c_void_p),
        ("error_name_len", ctypes.c_size_t),
    ]


class _Lib:
    """A bound handle to one archive: the package reads ``_lib.pancake_*``
    without holding a raw ``CDLL``. Keeps the loaded ``CDLL`` alive so it is
    never collected while a bound function is still callable."""

    def __init__(self, *handles):
        self._handles = handles


def _bind(facade, lib, sigs):
    """Attach each signature in ``sigs`` to ``facade`` as a bound ctypes
    function read off ``lib``. Shared by every archive's loader."""
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype
        setattr(facade, name, fn)


def _load():
    P = ctypes.c_void_p
    size_p = ctypes.POINTER(ctypes.c_size_t)
    ocapn_sigs = {
        "pancake_abi_version": (
            [ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)],
            None,
        ),
        "pancake_last_error": ([ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t], ctypes.c_size_t),
        "pancake_clear_last_error": ([], None),
        "pancake_context_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_new_with_allocator": ([ctypes.POINTER(_Allocator), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_context_release": ([P], None),
        "pancake_peer_new": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_negotiated": ([ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_negotiated_in": ([P, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_raw_open": ([ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_new_raw_open_in": ([P, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_peer_start_session": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_peer_session_is_open": ([P], ctypes.c_int32),
        "pancake_peer_release": ([P], None),
        "pancake_peer_feed_borrowed": ([P, ctypes.POINTER(_Frame)], ctypes.c_int32),
        "pancake_peer_feed_owned": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_peer_step": ([P], ctypes.c_int32),
        "pancake_peer_step_to_idle": ([P], ctypes.c_int32),
        "pancake_peer_recv_stream": ([P, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], ctypes.c_int32),
        "pancake_peer_take_outbound": ([P, ctypes.POINTER(_ManagedFrame)], ctypes.c_int32),
        "pancake_managed_frame_release": ([ctypes.POINTER(_ManagedFrame)], None),
        "pancake_peer_poll_event": ([P, ctypes.POINTER(_Event)], ctypes.c_int32),
        "pancake_event_release": ([ctypes.POINTER(_Event)], None),
        "pancake_peer_last_abort": ([P, ctypes.POINTER(_LastAbort)], ctypes.c_int32),
        "pancake_peer_register_export": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_next_export": ([P, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_next_answer": ([P, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_register_import": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_peek_event": ([P], ctypes.c_int32),
        "pancake_peer_send_deliver": (
            [P, ctypes.POINTER(_Reference), ctypes.POINTER(_Argument), ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint64],
            ctypes.c_int32,
        ),
        "pancake_peer_send_resolve": (
            [P, ctypes.c_uint64, ctypes.c_uint32, ctypes.POINTER(_Argument), ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_peer_poll_event_deliver": ([P, ctypes.POINTER(_Deliver)], ctypes.c_int32),
        "pancake_peer_poll_event_resolve": ([P, ctypes.POINTER(_Resolve)], ctypes.c_int32),
        "pancake_deliver_release": ([ctypes.POINTER(_Deliver)], None),
        "pancake_resolve_release": ([ctypes.POINTER(_Resolve)], None),
        "pancake_peer_register_bootstrap_cap": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_send_bootstrap_fetch": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_peer_prepare_enliven": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(_EnlivenStart)], ctypes.c_int32),
        "pancake_peer_record_enlivenment": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint32], ctypes.c_int32),
        # Recipient half of a three-party handoff: sign a desc:handoff-receive over
        # the verbatim give bytes (keyed by the 32-byte seed) and queue a
        # withdraw-gift deliver to the exporter's bootstrap under `answer`.
        "pancake_peer_send_withdraw_gift": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64],
            ctypes.c_int32,
        ),
        # Gifter (introducer) half of a three-party handoff (ADR-0009): the
        # accessors surface the partner's session key and verbatim locator bytes,
        # `send_deposit_gift` plants the gift with the exporter, `build_handoff_give`
        # signs the give the recipient redeems, and `send_resolve_handoff_give`
        # answers the recipient with it. The shared gift registry lets one node's
        # deposit (on the gifter session) and withdraw (on the recipient session)
        # resolve against one table.
        "pancake_peer_partner_session_key": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_peer_partner_locator_raw": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_peer_send_deposit_gift": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(_Reference)],
            ctypes.c_int32,
        ),
        "pancake_peer_send_resolve_handoff_give": (
            [P, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_build_handoff_give": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_handoff_give_bytes_release": ([ctypes.c_void_p, ctypes.c_size_t], None),
        "pancake_encode_peer_locator": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_peer_locator_bytes_release": ([ctypes.c_void_p, ctypes.c_size_t], None),
        "pancake_gift_registry_new": ([ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int32),
        "pancake_gift_registry_free": ([ctypes.c_void_p], None),
        "pancake_peer_set_gift_registry": ([P, ctypes.c_void_p], ctypes.c_int32),
        # Cross-connection handoff router (PancakeNode, ADR-0066): the sans-io node
        # owns the per-connection peers, the shared gift registry, the retained
        # identity, and the redeemed-token / foreign-home routing tables. A binding
        # registers each connection's node-owned peer, pumps it, and routes by
        # conn_id — every route value an integer, so the router is pure data.
        "pancake_node_new": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_node_new_in": ([P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_node_free": ([P], None),
        "pancake_node_register_conn": ([P, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_node_remove_conn": ([P, ctypes.c_uint64], ctypes.c_int32),
        "pancake_node_send_withdraw": ([P, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64], ctypes.c_int32),
        "pancake_node_originate_give": (
            [P, ctypes.c_uint64, ctypes.c_uint64, ctypes.POINTER(_Reference), ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t],
            ctypes.c_int32,
        ),
        "pancake_node_enroll_redeemed": ([P, ctypes.c_uint64, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int32),
        "pancake_node_route": (
            [P, ctypes.c_uint64, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint32)],
            ctypes.c_int32,
        ),
        "pancake_node_record_foreign_home": ([P, ctypes.c_uint64, ctypes.c_uint64], ctypes.c_int32),
        "pancake_node_foreign_home": ([P, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint32)], ctypes.c_int32),
        "pancake_node_arg_is_foreign": ([P, ctypes.c_uint64, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint32)], ctypes.c_int32),
        "pancake_peer_codec": ([P, ctypes.POINTER(ctypes.c_uint32)], ctypes.c_int32),
        "pancake_peer_send_gc_export": ([P, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t], ctypes.c_int32),
        "pancake_peer_send_gc_answer": ([P, ctypes.c_uint64], ctypes.c_int32),
        # Pipelined projections (ADR-0050/ADR-0052): export a fresh promise at
        # `answer` that resolves to a field / element / untag-payload of whatever
        # `receiver` resolves to. `field` and `tag` are borrowed.
        "pancake_peer_send_get": ([P, ctypes.POINTER(_Reference), ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_send_index": ([P, ctypes.POINTER(_Reference), ctypes.c_int64, ctypes.c_uint64], ctypes.c_int32),
        "pancake_peer_send_untag": ([P, ctypes.POINTER(_Reference), ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint64], ctypes.c_int32),
        # OCapN locator URIs — core libpancake_ocapn vocabulary, so a TCP-only consumer
        # reaches them without the iroh companion library. One grammar, no hand-rolled
        # percent codec. Verbs mint an opaque PancakeLocator; nouns read it.
        "pancake_uri_parse_peer": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_parse_sturdyref": ([ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(P)], ctypes.c_int32),
        "pancake_uri_format_peer": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_int32,
        ),
        "pancake_uri_format_sturdyref": (
            [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
             ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_int32,
        ),
        "pancake_locator_transport": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_designator": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_swissnum": ([P, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32),
        "pancake_locator_hint": (
            [P, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p], ctypes.c_int32,
        ),
        "pancake_locator_hint_count": ([P, size_p], ctypes.c_int32),
        "pancake_locator_hint_at": (
            [P, ctypes.c_size_t, ctypes.POINTER(ctypes.c_void_p), size_p, ctypes.POINTER(ctypes.c_void_p), size_p],
            ctypes.c_int32,
        ),
        "pancake_locator_release": ([P], None),
    }
    ocapn = ctypes.CDLL(str(_lib_path("pancake_ocapn")))
    facade = _Lib(ocapn)
    _bind(facade, ocapn, ocapn_sigs)
    return facade


_lib = _load()
