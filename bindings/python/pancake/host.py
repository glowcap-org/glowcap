"""High-level, safe wrappers over the runtime cdylib.

:class:`Runtime` loads ``libpancake_ffi_runtime`` and is the factory for
:class:`KeyPair` and :class:`Peer`. :class:`Peer` exposes the full
per-peer surface (lifecycle, step / queues, typed send / receive) with
Pythonic return values and automatic side-allocation cleanup on the
receive side.

Ownership contracts (from ``pancake.h``):

* A :class:`KeyPair` handed to :meth:`Runtime.peer_new` is **consumed** by
  the peer; do not free it afterwards (the peer frees it on drop). Mirrored
  here by :class:`KeyPair.consumed` flag.
* Outbound frames from ``take_outbound`` arrive as a self-describing
  ``PancakeManagedFrame`` — released via the single
  ``pancake_managed_frame_release``, never ``libc.free``. Inbound
  (``feed_inbound``) lends a bare ``PancakeFrame`` the runtime borrows for
  the call (zero-copy; nothing to free).
"""

from __future__ import annotations

import ctypes
from ctypes import (
    POINTER,
    addressof,
    byref,
    c_char_p,
    c_size_t,
    c_uint8,
    c_uint32,
    c_uint64,
    c_void_p,
    cast,
    string_at,
)
from dataclasses import dataclass
from typing import List, Optional, Tuple

from . import _abi, _runtime
from .constants import (
    PANCAKE_CODEC_SYRUP,
    PANCAKE_ERR_HANDSHAKE_INCOMPLETE,
    PANCAKE_OK,
    PANCAKE_REF_BROKEN,
)
from .values import (
    Argument,
    PancakeArgument,
    PancakeOcapnUri,
    PancakeReference,
    PancakeResolution,
    PancakeStepOutcome,
    Reference,
    Resolution,
    marshal_arguments,
    marshal_reference,
    marshal_resolution,
    project_argument_addr,
    project_reference,
    project_resolution,
)


class PancakeError(RuntimeError):
    """Raised when a runtime FFI call returns a non-OK code."""

    def __init__(self, op: str, rc: int, detail: Optional[str]):
        self.op = op
        self.rc = rc
        self.detail = detail
        super().__init__(f"{op}: rc={rc}; last error: {detail}")


@dataclass
class OcapnUri:
    transport: str
    designator: str
    swissnum: Optional[bytes]


class KeyPair:
    """An Ed25519 key-pair handle."""

    def __init__(self, rt: "Runtime", handle: int):
        self._rt = rt
        self.handle = handle
        self.consumed = False

    def pubkey(self) -> bytes:
        out = (c_uint8 * 32)()
        rc = self._rt.lib.pancake_keypair_pubkey(self.handle, out)
        self._rt._check(rc, "pancake_keypair_pubkey")
        return bytes(out)

    def free(self) -> None:
        """Free a key-pair that was NEVER handed to a peer constructor."""
        if self.handle and not self.consumed:
            self._rt.lib.pancake_keypair_free(self.handle)
        self.handle = 0


class Peer:
    """A pancake peer — one CapTP session."""

    def __init__(self, rt: "Runtime", handle: int):
        self._rt = rt
        self.handle = handle

    # ─── lifecycle ────────────────────────────────────────────────────────

    def free(self) -> None:
        if self.handle:
            self._rt.lib.pancake_peer_free(self.handle)
        self.handle = 0

    def shutdown(self) -> None:
        self._rt.lib.pancake_peer_shutdown(self.handle)

    def get_my_peer_id(self) -> bytes:
        out = (c_uint8 * 32)()
        rc = self._rt.lib.pancake_peer_get_my_peer_id(self.handle, out)
        self._rt._check(rc, "pancake_peer_get_my_peer_id")
        return bytes(out)

    def get_partner_peer_id(self) -> Optional[bytes]:
        """Partner peer-id, or ``None`` if the handshake hasn't completed."""
        out = (c_uint8 * 32)()
        rc = self._rt.lib.pancake_peer_get_partner_peer_id(self.handle, out)
        if rc == PANCAKE_OK:
            return bytes(out)
        if rc == PANCAKE_ERR_HANDSHAKE_INCOMPLETE:
            return None
        self._rt._check(rc, "pancake_peer_get_partner_peer_id")

    def register_bootstrap_cap(self, swissnum: bytes, export_id: int) -> None:
        buf = (c_uint8 * len(swissnum)).from_buffer_copy(bytes(swissnum))
        rc = self._rt.lib.pancake_peer_register_bootstrap_cap(
            self.handle, buf, len(swissnum), export_id
        )
        self._rt._check(rc, "pancake_peer_register_bootstrap_cap")

    def register_export(self, export_id: int) -> None:
        rc = self._rt.lib.pancake_peer_register_export(self.handle, export_id)
        self._rt._check(rc, "pancake_peer_register_export")

    # ─── step + queues ──────────────────────────────────────────────────────

    def step(self) -> Tuple[int, int]:
        """Drive one step; returns ``(step_kind, next_deadline_ms)``."""
        outcome = PancakeStepOutcome()
        rc = self._rt.lib.pancake_peer_step(self.handle, byref(outcome))
        self._rt._check(rc, "pancake_peer_step")
        return outcome.kind, outcome.next_deadline_ms

    def feed_inbound(self, body: bytes) -> None:
        buf = (c_uint8 * len(body)).from_buffer_copy(bytes(body))
        frame = _abi.PancakeFrame(cast(buf, c_void_p), len(body))
        rc = self._rt.lib.pancake_peer_feed_inbound(self.handle, byref(frame))
        self._rt._check(rc, "pancake_peer_feed_inbound")

    def take_outbound(self) -> Optional[bytes]:
        """Drain one outbound frame body (copied), or ``None`` if empty.

        The runtime hands back a self-describing ``PancakeManagedFrame``; we
        copy the body into a Python ``bytes`` and release the managed frame
        via the single ``pancake_managed_frame_release`` before returning.
        """
        frame = _abi.PancakeManagedFrame()
        rc = self._rt.lib.pancake_peer_take_outbound(self.handle, byref(frame))
        if rc == 1:
            body = string_at(frame.bytes, frame.len) if frame.len else b""
            self._rt.lib.pancake_managed_frame_release(byref(frame))
            return body
        if rc == 0:
            return None
        self._rt._check(rc, "pancake_peer_take_outbound")

    def peek_event_kind(self) -> Optional[int]:
        out = c_uint32(0)
        rc = self._rt.lib.pancake_peer_peek_event_kind(self.handle, byref(out))
        if rc == 1:
            return out.value
        if rc == 0:
            return None
        self._rt._check(rc, "pancake_peer_peek_event_kind")

    def consume_event(self) -> bool:
        rc = self._rt.lib.pancake_peer_consume_event(self.handle)
        if rc in (0, 1):
            return rc == 1
        self._rt._check(rc, "pancake_peer_consume_event")

    def session_state(self) -> int:
        out = c_uint32(0)
        rc = self._rt.lib.pancake_peer_session_state(self.handle, byref(out))
        self._rt._check(rc, "pancake_peer_session_state")
        return out.value

    def has_outbound(self) -> bool:
        return self._rt.lib.pancake_peer_has_outbound(self.handle) == 1

    def has_event(self) -> bool:
        return self._rt.lib.pancake_peer_has_event(self.handle) == 1

    # ─── typed send ─────────────────────────────────────────────────────────

    def send_start_session(self, transport: str, designator: str) -> None:
        rc = self._rt.lib.pancake_peer_send_start_session(
            self.handle, transport.encode("utf-8"), designator.encode("utf-8")
        )
        self._rt._check(rc, "pancake_peer_send_start_session")

    def send_deliver(
        self, target: Reference, args: List[Argument], answer_id: int = 0
    ) -> None:
        keepalive: list = []
        targ = marshal_reference(target, keepalive)
        arr, n = marshal_arguments(args, keepalive)
        arr_ptr = cast(arr, POINTER(PancakeArgument)) if arr is not None else None
        rc = self._rt.lib.pancake_peer_send_deliver(
            self.handle, byref(targ), arr_ptr, n, answer_id
        )
        self._rt._check(rc, "pancake_peer_send_deliver")

    def send_resolve(self, answer_id: int, resolution: Resolution) -> None:
        keepalive: list = []
        res = marshal_resolution(resolution, keepalive)
        rc = self._rt.lib.pancake_peer_send_resolve(self.handle, answer_id, byref(res))
        self._rt._check(rc, "pancake_peer_send_resolve")

    def send_abort(self, reason_kind: int, message: str = "") -> None:
        data = (message or "").encode("utf-8")
        rc = self._rt.lib.pancake_peer_send_abort(
            self.handle, reason_kind, data, len(data)
        )
        self._rt._check(rc, "pancake_peer_send_abort")

    def enliven_sturdyref(self, sturdyref: Reference) -> None:
        keepalive: list = []
        ref = marshal_reference(sturdyref, keepalive)
        rc = self._rt.lib.pancake_peer_enliven_sturdyref(self.handle, byref(ref))
        self._rt._check(rc, "pancake_peer_enliven_sturdyref")

    # ─── typed receive ──────────────────────────────────────────────────────

    def poll_event_deliver(self):
        """Drain a ``DeliverReceived`` event.

        Returns ``None`` (no Deliver pending) or
        ``(target, args, answer_id_or_None, resolve_me_desc_or_None)``.
        """
        out_target = PancakeReference()
        out_args = POINTER(PancakeArgument)()
        out_count = c_size_t(0)
        out_answer = c_uint64(0)
        out_rmd = PancakeReference()
        rc = self._rt.lib.pancake_peer_poll_event_deliver(
            self.handle,
            byref(out_target),
            byref(out_args),
            byref(out_count),
            byref(out_answer),
            byref(out_rmd),
        )
        if rc == 0:
            return None
        if rc != 1:
            self._rt._check(rc, "pancake_peer_poll_event_deliver")
        target = project_reference(out_target)
        count = out_count.value
        args: List[Argument] = []
        if count and out_args:
            base = cast(out_args, c_void_p).value
            item_size = ctypes.sizeof(PancakeArgument)
            args = [project_argument_addr(base + i * item_size) for i in range(count)]
        # resolve-me-desc: BROKEN sentinel means absent.
        rmd_kind = out_rmd.kind
        resolve_me_desc: Optional[Reference] = None
        if rmd_kind != PANCAKE_REF_BROKEN:
            resolve_me_desc = project_reference(out_rmd)
        self._rt.lib.pancake_typed_resolve_me_desc_free(byref(out_rmd))
        if count and out_args:
            self._rt.lib.pancake_typed_args_free(out_args, count)
        answer = out_answer.value
        return target, args, (answer if answer != 0 else None), resolve_me_desc

    def poll_event_resolve(self):
        """Drain a ``ResolveReceived`` event → ``(answer_id, Resolution)`` or ``None``."""
        out_answer = c_uint64(0)
        out_res = PancakeResolution()
        rc = self._rt.lib.pancake_peer_poll_event_resolve(
            self.handle, byref(out_answer), byref(out_res)
        )
        if rc == 0:
            return None
        if rc != 1:
            self._rt._check(rc, "pancake_peer_poll_event_resolve")
        res = project_resolution(out_res)
        self._rt.lib.pancake_typed_resolution_free(byref(out_res))
        return out_answer.value, res

    def poll_event_abort(self):
        """Drain a ``SessionAborted`` / ``AbortReceived`` event.

        Returns ``(reason_kind, message)`` or ``None``.
        """
        out_kind = c_uint32(0)
        out_msg = POINTER(c_uint8)()
        out_len = c_size_t(0)
        rc = self._rt.lib.pancake_peer_poll_event_abort(
            self.handle, byref(out_kind), byref(out_msg), byref(out_len)
        )
        if rc == 0:
            return None
        if rc != 1:
            self._rt._check(rc, "pancake_peer_poll_event_abort")
        length = out_len.value
        msg = b""
        if length and out_msg:
            msg = string_at(cast(out_msg, c_void_p).value, length)
            self._rt.lib.pancake_typed_abort_message_free(out_msg, length)
        return out_kind.value, msg.decode("utf-8", "replace")

    def poll_event_session_established(self):
        """Drain a ``SessionEstablished`` event.

        Returns ``(partner_pubkey_32, partner_locator_str)`` or ``None``.
        """
        pubkey = (c_uint8 * 32)()
        out_loc = POINTER(c_uint8)()
        out_len = c_size_t(0)
        rc = self._rt.lib.pancake_peer_poll_event_session_established(
            self.handle, pubkey, byref(out_loc), byref(out_len)
        )
        if rc == 0:
            return None
        if rc != 1:
            self._rt._check(rc, "pancake_peer_poll_event_session_established")
        length = out_len.value
        loc = b""
        if length and out_loc:
            loc = string_at(cast(out_loc, c_void_p).value, length)
            self._rt.lib.pancake_typed_partner_locator_free(out_loc, length)
        return bytes(pubkey), loc.decode("utf-8", "replace")


class SturdyrefDedup:
    """A shared sturdyref-enliven dedup table (the host-managed runtime piece)."""

    def __init__(self, rt: "Runtime", handle: int):
        self._rt = rt
        self.handle = handle

    def free(self) -> None:
        if self.handle:
            self._rt.lib.pancake_sturdyref_dedup_free(self.handle)
        self.handle = 0


class Runtime:
    """Loaded ``libpancake_ffi_runtime`` + the factory for peers / keypairs."""

    def __init__(self):
        self.runtime = _runtime.load()
        self.lib = self.runtime  # alias: bound functions live on the RuntimeLib

    # ─── diagnostics ────────────────────────────────────────────────────────

    def last_error(self) -> Optional[str]:
        return self.runtime.last_error()

    def _check(self, rc: int, op: str) -> None:
        if rc != PANCAKE_OK:
            raise PancakeError(op, rc, self.runtime.last_error())

    def version(self) -> str:
        return self.lib.pancake_version().decode("utf-8")

    # ─── keypairs ─────────────────────────────────────────────────────────

    def keypair_new(self) -> KeyPair:
        h = self.lib.pancake_keypair_new()
        if not h:
            raise PancakeError("pancake_keypair_new", 0, self.runtime.last_error())
        return KeyPair(self, h)

    def keypair_from_seed(self, seed: bytes) -> KeyPair:
        if len(seed) != 32:
            raise ValueError(f"seed must be exactly 32 bytes; got {len(seed)}")
        buf = (c_uint8 * 32).from_buffer_copy(bytes(seed))
        h = self.lib.pancake_keypair_from_seed(buf, 32)
        if not h:
            raise PancakeError("pancake_keypair_from_seed", 0, self.runtime.last_error())
        return KeyPair(self, h)

    # ─── peers ──────────────────────────────────────────────────────────────

    def peer_new(self, keypair: KeyPair, codec: int = PANCAKE_CODEC_SYRUP) -> Peer:
        h = self.lib.pancake_peer_new(keypair.handle, codec)
        if not h:
            raise PancakeError("pancake_peer_new", 0, self.runtime.last_error())
        keypair.consumed = True  # peer took ownership
        return Peer(self, h)

    def peer_new_advanced(
        self,
        my_peer_id: Optional[str],
        partner_peer_id: Optional[str],
        codec: int,
        captp_version: int,
        keypair: Optional[KeyPair] = None,
    ) -> Peer:
        kp_handle = keypair.handle if keypair else None
        h = self.lib.pancake_peer_new_advanced(
            my_peer_id.encode("utf-8") if my_peer_id else None,
            partner_peer_id.encode("utf-8") if partner_peer_id else None,
            codec,
            captp_version,
            kp_handle,
        )
        if not h:
            raise PancakeError("pancake_peer_new_advanced", 0, self.runtime.last_error())
        if keypair:
            keypair.consumed = True
        return Peer(self, h)

    # ─── OCapN URI parse ──────────────────────────────────────────────────

    def ocapn_uri_parse(self, uri: str) -> OcapnUri:
        ptr = self.lib.pancake_ocapn_uri_parse(uri.encode("utf-8"))
        if not ptr:
            raise PancakeError("pancake_ocapn_uri_parse", 0, self.runtime.last_error())
        parsed = cast(ptr, POINTER(PancakeOcapnUri)).contents
        transport = (parsed.transport_cstr or b"").decode("utf-8", "replace")
        designator = (parsed.designator_cstr or b"").decode("utf-8", "replace")
        swissnum: Optional[bytes] = None
        if parsed.swissnum_bytes and parsed.swissnum_len:
            swissnum = string_at(parsed.swissnum_bytes, parsed.swissnum_len)
        self.lib.pancake_ocapn_uri_free(ptr)
        return OcapnUri(transport, designator, swissnum)

    # ─── Syrup frame probe ────────────────────────────────────────────────

    def syrup_frame_probe(self, buf: bytes, max_frame_bytes: int = 16 << 20):
        """Probe ``buf`` for the first complete Syrup frame.

        Returns ``(outcome, end_offset_or_None)`` where ``outcome`` is one of
        the ``PANCAKE_FRAME_*`` constants.
        """
        cbuf = (c_uint8 * len(buf)).from_buffer_copy(bytes(buf)) if buf else None
        out_end = c_size_t(0)
        rc = self.lib.pancake_syrup_frame_probe(
            cbuf, len(buf), byref(out_end), max_frame_bytes
        )
        return rc, (out_end.value if rc == 1 else None)

    # ─── cross-peer ─────────────────────────────────────────────────────────

    def sturdyref_dedup_new(self) -> SturdyrefDedup:
        h = self.lib.pancake_sturdyref_dedup_new()
        if not h:
            raise PancakeError("pancake_sturdyref_dedup_new", 0, self.runtime.last_error())
        return SturdyrefDedup(self, h)

    def cross_peer_drain_relayed_resolutions(self, peer: Peer) -> int:
        return self.lib.pancake_cross_peer_drain_relayed_resolutions(peer.handle)

    def cross_peer_absorb_pending_sturdyref_enlivens(
        self, dedup: SturdyrefDedup, peer: Peer
    ) -> int:
        return self.lib.pancake_cross_peer_absorb_pending_sturdyref_enlivens(
            dedup.handle, peer.handle
        )

    def cross_peer_cache_settled_sturdyref_enlivens(
        self, dedup: SturdyrefDedup, peer: Peer
    ) -> int:
        return self.lib.pancake_cross_peer_cache_settled_sturdyref_enlivens(
            dedup.handle, peer.handle
        )
