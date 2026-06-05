//! Inbound-failure → outbound-`op:abort` projection.
//!
//! When an inbound frame is rejected — by the codec (a malformed frame) or by
//! the session's authoritative validate/apply (a protocol violation) — the
//! protocol-correct response is to emit a typed `op:abort` and close the
//! session, not to surface a bare host error and leave the partner hanging
//! (resilience posture § fail-loud). This module is the pure mapping from a
//! dispatch error to that abort shape; [`runtime.Peer`] wires it into both
//! inbound entry points ([`Peer.step`] / [`Peer.recvBorrowed`]).
//!
//! Mirrors the canonical runtime's `abort_session_errors` projection table.
//! Zig session [`Error`](session.Error) values carry no payload, so the abort
//! `message` is a static per-kind diagnostic rather than an id-bearing one; the
//! `kind` discriminant is what a conformant partner keys on.

const model = @import("../model/mod.zig");

/// The outbound abort shape an inbound failure projects to.
pub const InboundAbort = struct {
    /// Typed `op:abort` reason kind to emit on the wire.
    kind: model.AbortKind,
    /// Static diagnostic embedded in the outbound abort.
    message: []const u8,
    /// Whether to close the local session after emitting the abort.
    close: bool,
};

/// Project a dispatch `err` to its outbound abort, or `null` when the runtime
/// returns the error without emitting `op:abort` (e.g. `OutOfMemory`, or a
/// session already `SessionClosed`).
///
/// Codec decode failures map to `malformed_frame` / `protocol_error`; session
/// protocol violations map to their typed kind. `CaptpVersionMismatch` is a
/// handshake-time refusal that does not close (the session never reached
/// `open`); every other protocol violation closes.
pub fn abortForError(err: anyerror) ?InboundAbort {
    return switch (err) {
        // ── codec decode failures (codec.syrup.Error) ───────────────
        error.MalformedFrame, error.InvalidFrameShape => .{
            .kind = .malformed_frame,
            .message = "inbound frame failed to decode",
            .close = true,
        },
        error.UnsupportedArgument, error.UnsupportedMessage, error.UnsupportedReference => .{
            .kind = .protocol_error,
            .message = "inbound frame carried an unsupported wire shape",
            .close = true,
        },
        // ── session protocol violations (session.Error) ─────────────
        error.CaptpVersionMismatch => .{
            .kind = .version_mismatch,
            .message = "op:start-session captp-version does not match this session's profile",
            .close = false,
        },
        error.QueueCapExceeded => .{
            .kind = .queue_cap_exceeded,
            .message = "pipelined-call queue cap exceeded on a pending answer (ADR-0007)",
            .close = true,
        },
        error.HandoffReplay => .{
            .kind = .handoff_replay,
            .message = "handoff-receive replayed or out-of-order handoff-count (ADR-0009)",
            .close = true,
        },
        // Table-cap exhaustion → ResourceExhausted (ADR-0025).
        error.InboundAnswerCapExceeded,
        error.ListenerCapExceeded,
        error.ImportCapExceeded,
        error.HandoffCountCapExceeded,
        error.DepositedGiftCapExceeded,
        => .{
            .kind = .resource_exhausted,
            .message = "inbound message would push a session table past its cap (ADR-0025)",
            .close = true,
        },
        // Generic partner protocol violations → ProtocolError + close.
        error.MalformedMessage,
        error.InvalidReference,
        error.FeatureNotNegotiated,
        error.InvalidGift,
        error.GcUnderflow,
        error.UnexpectedMessage,
        error.DuplicateStartSession,
        error.ResolutionCycle,
        error.HostMismatch,
        => .{
            .kind = .protocol_error,
            .message = "inbound message violated the session state machine",
            .close = true,
        },
        // SessionClosed (already closed) and non-protocol errors (OutOfMemory,
        // …) surface to the caller without an abort.
        else => null,
    };
}
