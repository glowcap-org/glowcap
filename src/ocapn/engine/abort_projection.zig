//! Turning a rejected inbound frame into an outbound `op:abort`.
//!
//! When we reject an inbound frame, whether the codec couldn't parse it or the
//! session ruled it a protocol violation, the right thing to do is tell the
//! partner with a typed `op:abort` rather than swallow a host error and leave
//! the other side hanging. That's the fail-loud posture. This module is the
//! pure mapping from a dispatch error to the abort shape. `engine.Peer` plugs
//! it into both inbound entry points, the inbound-dispatch arm of `Peer.step`
//! and `Peer.recvBorrowed`. Every projected abort is
//! terminal: CapTP does not admit a corrected message after either side aborts.
//!
//! Session `Error` values don't carry a payload, so the abort's `message` is a
//! fixed per-kind string, not something with an id in it. The part a well-behaved
//! partner keys on is the `kind`.

const model = @import("model");

/// The outbound abort shape an inbound failure projects to.
pub const InboundAbort = struct {
    /// Typed `op:abort` reason kind to emit on the wire.
    kind: model.AbortKind,
    /// Static diagnostic embedded in the outbound abort.
    message: []const u8,
};

/// The wire-meaning domain of a dispatch error, the codec-vs-session split a C
/// consumer keys on, plus `foreign` for host-internal failures (allocation, …)
/// that carry no protocol meaning. One enum, derived everywhere, so the
/// codec/session error space is enumerated in exactly one switch (`classify`).
pub const Domain = enum {
    /// The codec could not decode the bytes as a frame (malformed, an
    /// unsupported wire shape, or a borrowed-view projection failure).
    codec,
    /// The session's authoritative validate/apply rejected the frame, a
    /// protocol violation, a resource cap, or an already-closed session.
    session,
    /// Neither: a host-internal failure (out of memory, …).
    foreign,
};

/// The full classification of a dispatch error: which abort (if any) to project
/// onto the wire, and which `Domain` a higher layer reports it as. This is the
/// single place the codec + session error space is enumerated. `abortForError`
/// and the C ABI's `feedErrorToCode` both derive from it, so they cannot drift.
/// Completeness over the codec / session / projection error sets is pinned by
/// `test/engine/error_taxonomy_test.zig`.
pub const Classification = struct {
    /// The outbound abort to project, or `null` when the error surfaces without
    /// one (`SessionClosed`, host-internal errors).
    abort: ?InboundAbort,
    domain: Domain,
};

/// Classify a dispatch `err`. Every projected abort closes the session after a
/// successful outbound push. If the push fails, the caller still closes.
pub fn classify(err: anyerror) Classification {
    return switch (err) {
        // ── codec decode / projection failures to malformed_frame ─────
        // The Cap'n Proto structural failures (`Truncated` short/over-claimed
        // segment, `InvalidPointer` bad pointer word, `UnsupportedSegmentCount`
        // multi-segment frame) are decode malformations exactly like Syrup's
        // `MalformedFrame`, the partner sent bytes that are not a valid frame.
        error.MalformedFrame,
        error.InvalidFrameShape,
        error.MalformedView,
        error.Truncated,
        error.InvalidPointer,
        error.UnsupportedSegmentCount,
        => .{ .domain = .codec, .abort = .{
            .kind = .malformed_frame,
            .message = "inbound frame failed to decode",
        } },
        error.UnsupportedArgument, error.UnsupportedMessage, error.UnsupportedReference => .{
            .domain = .codec,
            .abort = .{
                .kind = .protocol_error,
                .message = "inbound frame carried an unsupported wire shape",
            },
        },
        // ── session: handshake refusals ───────────────────────────────
        error.CaptpVersionMismatch => .{ .domain = .session, .abort = .{
            .kind = .version_mismatch,
            .message = "op:start-session captp-version does not match this session's profile",
        } },
        error.InvalidStartSessionSignature => .{ .domain = .session, .abort = .{
            .kind = .invalid_start_session_signature,
            .message = "op:start-session location signature failed to verify",
        } },
        // The durable-identity claim check (ADR-0028): the hello claimed an
        // identity this session did not expect, a key-designator dial that
        // reached someone else, or a remote naming what it never proved.
        // Handshake-time refusal: the session never reached `open`, but the
        // abort is still terminal for this CapTP session.
        error.PartnerDesignatorMismatch => .{ .domain = .session, .abort = .{
            .kind = .invalid_start_session_signature,
            .message = "op:start-session claims a key designator this session did not expect",
        } },
        error.UnknownTransportSemantics => .{ .domain = .session, .abort = .{
            .kind = .protocol_error,
            .message = "op:start-session names a transport whose designator semantics are unknown",
        } },
        error.QueueCapExceeded => .{ .domain = .session, .abort = .{
            .kind = .queue_cap_exceeded,
            .message = "pipelined-call queue cap exceeded on a pending answer",
        } },
        error.HandoffReplay => .{ .domain = .session, .abort = .{
            .kind = .handoff_replay,
            .message = "handoff-receive replayed or out-of-order handoff-count",
        } },
        // The receive's own names disagree with the ones derived from the
        // gifter-signed give and this node's session key, so it does not belong
        // to the conversation it claims. Like a replay, the
        // partner is not speaking the protocol, and the counter it was reaching
        // for is not its own.
        error.InvalidHandoffSession => .{ .domain = .session, .abort = .{
            .kind = .protocol_error,
            .message = "handoff-receive names the wrong receiving session or side",
        } },
        // ── resource bounds to resource_exhausted (ADR-0008) ──────────
        // The session table caps plus the parse-stage nesting and stream
        // frame-size bounds, the engine's drain-time local-delivery bound
        // (ADR-0003), and the Host's local-turn amplification budget
        // (ADR-0018): a partner cannot push any of them past its cap.
        error.InboundAnswerCapExceeded,
        error.RetainedAnswerCapExceeded,
        error.QueuedCallBytesExceeded,
        error.ListenerCapExceeded,
        error.ProjectionCapExceeded,
        error.ImportCapExceeded,
        error.DepositedGiftCapExceeded,
        error.PendingWithdrawCapExceeded,
        error.NestingTooDeep,
        error.CompareBudgetExhausted,
        error.ExportRangeExhausted,
        error.VirtualAnswerSpaceExhausted,
        error.FrameTooLarge,
        error.LocalDeliveryCapExceeded,
        error.LocalTurnLimitExceeded,
        error.OutboundBackpressure,
        => .{ .domain = .session, .abort = .{
            .kind = .resource_exhausted,
            .message = "inbound message would push a session resource past its cap",
        } },
        // ── generic partner protocol violations to protocol_error ─────
        error.DuplicateSetElement,
        error.DuplicateStructKey,
        error.MalformedMessage,
        error.InvalidReference,
        error.FeatureNotNegotiated,
        error.InvalidGift,
        error.GcUnderflow,
        error.GcOverflow,
        error.UnexpectedMessage,
        error.DuplicateStartSession,
        => .{ .domain = .session, .abort = .{
            .kind = .protocol_error,
            .message = "inbound message violated the session state machine",
        } },
        // The exact-size Syrup encoder detected disagreement between its two
        // internal passes. This is codec-owned but outbound-only: no partner
        // sent a frame to condemn, so contain it to the operation without an
        // abort.
        error.EncoderInvariantViolation => .{ .domain = .codec, .abort = null },
        // An already-closed session is a session-domain error, but there is no
        // abort to emit (the session is gone).
        error.SessionClosed => .{ .domain = .session, .abort = null },
        // A local caller chose a mutable bootstrap name inside the reserved
        // durable namespace (ADR-0007). This is an API refusal on the send
        // side, never an inbound frame's fault, so no abort is emitted.
        error.ReservedDurableNamespace => .{ .domain = .session, .abort = null },
        // Host configuration failures happen before an inbound frame is
        // applied. They have no wire meaning and must never emit an abort.
        error.MissingAdvertisedLocator,
        => .{ .domain = .foreign, .abort = null },
        // Host-internal (OutOfMemory, …): no abort, no protocol meaning.
        else => .{ .domain = .foreign, .abort = null },
    };
}

/// Project a dispatch `err` to its outbound abort, or `null` when the engine
/// returns the error without emitting `op:abort` (`SessionClosed`, `OutOfMemory`).
pub fn abortForError(err: anyerror) ?InboundAbort {
    return classify(err).abort;
}
