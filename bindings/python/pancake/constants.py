"""All libpancake C-ABI constants, mirrored from the generated headers.

Source of truth: ``crates/ffi/*/include/pancake*.h`` (cbindgen-generated).
If these drift from the Rust enum reprs, peek/poll accessors lie — keep
them in lockstep with the headers.
"""

from __future__ import annotations

# Re-export the shared return codes so consumers can `from pancake.constants
# import *` and see the full surface.
from ._abi import (  # noqa: F401
    PANCAKE_OK,
    PANCAKE_ERR_NULL_POINTER,
    PANCAKE_ERR_INVALID_HANDLE,
    PANCAKE_ERR_PEER_CLOSED,
    PANCAKE_ERR_SESSION,
    PANCAKE_ERR_CODEC,
    PANCAKE_ERR_INTERNAL,
    PANCAKE_ERR_INVALID_UTF8,
    PANCAKE_ERR_INVALID_CODEC,
    PANCAKE_ERR_HANDSHAKE_INCOMPLETE,
    PANCAKE_ERR_PANIC,
    PANCAKE_ENDPOINT_ERR_IO,
    PANCAKE_ENDPOINT_ERR_MALFORMED,
    PANCAKE_ENDPOINT_ERR_CLOSED,
    PANCAKE_ENDPOINT_ERR_WOULD_BLOCK,
)

# ─── Codec selectors ──────────────────────────────────────────────────────
PANCAKE_CODEC_CAPNP = 0
PANCAKE_CODEC_SYRUP = 1

# ─── CapTP version selectors (pancake_peer_new_advanced) ──────────────────
PANCAKE_CAPTP_VERSION_PRESPEC = 0
PANCAKE_CAPTP_VERSION_V1_0 = 1

# ─── Step outcome ─────────────────────────────────────────────────────────
PANCAKE_STEP_MORE_WORK = 0
PANCAKE_STEP_IDLE = 1
PANCAKE_STEP_CLOSED = 2

# ─── Session state ────────────────────────────────────────────────────────
PANCAKE_SESSION_NEGOTIATING = 0
PANCAKE_SESSION_OPEN = 1
PANCAKE_SESSION_CLOSED = 2

# ─── Reference kinds ──────────────────────────────────────────────────────
PANCAKE_REF_NEAR = 0
PANCAKE_REF_FAR = 1
PANCAKE_REF_PROMISE = 2
PANCAKE_REF_STURDY = 3
PANCAKE_REF_BROKEN = 4

# ─── Argument kinds ───────────────────────────────────────────────────────
PANCAKE_ARG_SYMBOL = 0
PANCAKE_ARG_BYTES = 1
PANCAKE_ARG_REFERENCE = 2
PANCAKE_ARG_INTEGER = 3
PANCAKE_ARG_BOOL = 4
PANCAKE_ARG_STRING = 5
PANCAKE_ARG_VOID = 6
PANCAKE_ARG_LIST = 7

# ─── Resolution kinds ─────────────────────────────────────────────────────
PANCAKE_RES_FULFILL = 0
PANCAKE_RES_BREAK = 1

# ─── Abort reason kinds ───────────────────────────────────────────────────
PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN = 0
PANCAKE_ABORT_REASON_VERSION_MISMATCH = 1
PANCAKE_ABORT_REASON_MALFORMED_FRAME = 2
PANCAKE_ABORT_REASON_PROTOCOL_ERROR = 3
PANCAKE_ABORT_REASON_RESOURCE_EXHAUSTED = 4
PANCAKE_ABORT_REASON_INVALID_START_SESSION_SIGNATURE = 5
PANCAKE_ABORT_REASON_CROSSED_HELLOS = 6
PANCAKE_ABORT_REASON_CONNECTION_LOST = 7
PANCAKE_ABORT_REASON_OTHER = 0xFFFFFFFF

# ─── Event kinds (PancakeEventKind, #[repr(u32)]) ─────────────────────────
PANCAKE_EVENT_KIND_PEER_READY = 0
PANCAKE_EVENT_KIND_PEER_CLOSED = 1
PANCAKE_EVENT_KIND_SESSION_ESTABLISHED = 2
PANCAKE_EVENT_KIND_SESSION_ABORTED = 3
PANCAKE_EVENT_KIND_DELIVER_RECEIVED = 4
PANCAKE_EVENT_KIND_RESOLVE_RECEIVED = 5
PANCAKE_EVENT_KIND_ABORT_RECEIVED = 6

# ─── Syrup frame-probe outcomes ───────────────────────────────────────────
PANCAKE_FRAME_COMPLETE = 1
PANCAKE_FRAME_INCOMPLETE = 0
PANCAKE_FRAME_MALFORMED = -1


def session_state_name(state: int) -> str:
    return {
        PANCAKE_SESSION_NEGOTIATING: "Negotiating",
        PANCAKE_SESSION_OPEN: "Open",
        PANCAKE_SESSION_CLOSED: "Closed",
    }.get(state, f"Unknown({state})")


def step_kind_name(kind: int) -> str:
    return {
        PANCAKE_STEP_MORE_WORK: "MoreWork",
        PANCAKE_STEP_IDLE: "Idle",
        PANCAKE_STEP_CLOSED: "Closed",
    }.get(kind, f"Unknown({kind})")


def abort_reason_name(kind: int) -> str:
    return {
        PANCAKE_ABORT_REASON_GRACEFUL_SHUTDOWN: "GracefulShutdown",
        PANCAKE_ABORT_REASON_VERSION_MISMATCH: "VersionMismatch",
        PANCAKE_ABORT_REASON_MALFORMED_FRAME: "MalformedFrame",
        PANCAKE_ABORT_REASON_PROTOCOL_ERROR: "ProtocolError",
        PANCAKE_ABORT_REASON_RESOURCE_EXHAUSTED: "ResourceExhausted",
        PANCAKE_ABORT_REASON_INVALID_START_SESSION_SIGNATURE: "InvalidStartSessionSignature",
        PANCAKE_ABORT_REASON_CROSSED_HELLOS: "CrossedHellos",
        PANCAKE_ABORT_REASON_CONNECTION_LOST: "ConnectionLost",
        PANCAKE_ABORT_REASON_OTHER: "Other",
    }.get(kind, f"AbortReasonKind({kind})")


def event_kind_name(kind: int) -> str:
    return {
        PANCAKE_EVENT_KIND_PEER_READY: "PeerReady",
        PANCAKE_EVENT_KIND_PEER_CLOSED: "PeerClosed",
        PANCAKE_EVENT_KIND_SESSION_ESTABLISHED: "SessionEstablished",
        PANCAKE_EVENT_KIND_SESSION_ABORTED: "SessionAborted",
        PANCAKE_EVENT_KIND_DELIVER_RECEIVED: "DeliverReceived",
        PANCAKE_EVENT_KIND_RESOLVE_RECEIVED: "ResolveReceived",
        PANCAKE_EVENT_KIND_ABORT_RECEIVED: "AbortReceived",
    }.get(kind, f"EventKind({kind})")
