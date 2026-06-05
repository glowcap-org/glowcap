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

/// The wire-meaning domain of a dispatch error — the codec-vs-session split a C
/// consumer keys on, plus `foreign` for host-internal failures (allocation, …)
/// that carry no protocol meaning. One enum, derived everywhere, so the
/// codec/session error space is enumerated in exactly one switch ([`classify`]).
pub const Domain = enum {
    /// The codec could not decode the bytes as a frame (malformed, an
    /// unsupported wire shape, or a borrowed-view projection failure).
    codec,
    /// The session's authoritative validate/apply rejected the frame — a
    /// protocol violation, a resource cap, or an already-closed session.
    session,
    /// Neither: a host-internal failure (out of memory, …).
    foreign,
};

/// The full classification of a dispatch error: which abort (if any) to project
/// onto the wire, and which [`Domain`] a higher layer reports it as. This is the
/// single place the codec + session error space is enumerated; [`abortForError`]
/// and the C ABI's `feedErrorToCode` both derive from it, so they cannot drift.
/// Completeness over the codec / session / projection error sets is pinned by
/// `test/runtime/error_taxonomy_test.zig`.
pub const Classification = struct {
    /// The outbound abort to project, or `null` when the error surfaces without
    /// one (`SessionClosed`, host-internal errors).
    abort: ?InboundAbort,
    domain: Domain,
};

/// Classify a dispatch `err`. `CaptpVersionMismatch` is a handshake-time refusal
/// that does not close (the session never reached `open`); every other protocol
/// violation closes.
pub fn classify(err: anyerror) Classification {
    return switch (err) {
        // ── codec decode / projection failures → malformed_frame ─────
        // `Incomplete` never escapes `decodeBody` (it is folded to
        // `MalformedFrame`); classified here defensively as malformed.
        error.MalformedFrame,
        error.InvalidFrameShape,
        error.MalformedView,
        error.Incomplete,
        => .{ .domain = .codec, .abort = .{
            .kind = .malformed_frame,
            .message = "inbound frame failed to decode",
            .close = true,
        } },
        error.UnsupportedArgument, error.UnsupportedMessage, error.UnsupportedReference => .{
            .domain = .codec,
            .abort = .{
                .kind = .protocol_error,
                .message = "inbound frame carried an unsupported wire shape",
                .close = true,
            },
        },
        // ── session: handshake version mismatch (non-closing) ────────
        error.CaptpVersionMismatch => .{ .domain = .session, .abort = .{
            .kind = .version_mismatch,
            .message = "op:start-session captp-version does not match this session's profile",
            .close = false,
        } },
        error.QueueCapExceeded => .{ .domain = .session, .abort = .{
            .kind = .queue_cap_exceeded,
            .message = "pipelined-call queue cap exceeded on a pending answer (ADR-0007)",
            .close = true,
        } },
        error.HandoffReplay => .{ .domain = .session, .abort = .{
            .kind = .handoff_replay,
            .message = "handoff-receive replayed or out-of-order handoff-count (ADR-0009)",
            .close = true,
        } },
        // ── resource bounds → resource_exhausted (ADR-0025) ──────────
        // The session table caps plus the parse-stage nesting and stream
        // frame-size bounds: a partner cannot push any of them past its cap.
        error.InboundAnswerCapExceeded,
        error.ListenerCapExceeded,
        error.ImportCapExceeded,
        error.HandoffCountCapExceeded,
        error.DepositedGiftCapExceeded,
        error.NestingTooDeep,
        error.FrameTooLarge,
        => .{ .domain = .session, .abort = .{
            .kind = .resource_exhausted,
            .message = "inbound message would push a session resource past its cap (ADR-0025)",
            .close = true,
        } },
        // ── generic partner protocol violations → protocol_error ─────
        error.MalformedMessage,
        error.InvalidReference,
        error.FeatureNotNegotiated,
        error.InvalidGift,
        error.GcUnderflow,
        error.UnexpectedMessage,
        error.DuplicateStartSession,
        error.ResolutionCycle,
        error.HostMismatch,
        => .{ .domain = .session, .abort = .{
            .kind = .protocol_error,
            .message = "inbound message violated the session state machine",
            .close = true,
        } },
        // An already-closed session is a session-domain error, but there is no
        // abort to emit (the session is gone).
        error.SessionClosed => .{ .domain = .session, .abort = null },
        // Host-internal (OutOfMemory, …): no abort, no protocol meaning.
        else => .{ .domain = .foreign, .abort = null },
    };
}

/// Project a dispatch `err` to its outbound abort, or `null` when the runtime
/// returns the error without emitting `op:abort` (`SessionClosed`, `OutOfMemory`).
pub fn abortForError(err: anyerror) ?InboundAbort {
    return classify(err).abort;
}
