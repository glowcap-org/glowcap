//! Turning a rejected inbound frame into an outbound `op:abort`.
//!
//! When we reject an inbound frame, whether the codec couldn't parse it or the
//! session ruled it a protocol violation, the right thing to do is tell the
//! partner with a typed `op:abort` rather than swallow a host error and leave
//! the other side hanging. That's the fail-loud posture. This module is the
//! pure mapping from a dispatch error to the abort shape and CapTP disposition
//! (`close` vs stay `negotiating`); `engine.Peer` plugs it into both inbound
//! entry points, `Peer.step` and `Peer.recvBorrowed`.
//!
//! Session `Error` values don't carry a payload, so the abort's `message` is a
//! fixed per-kind string, not something with an id in it. The part a well-behaved
//! partner actually keys on is the `kind`.

const model = @import("model");

/// CapTP lifecycle after a successful outbound abort push (ADR-0083).
pub const AbortDisposition = enum {
    /// Handshake refusal: partner sees the abort; session stays negotiating.
    keep_negotiating,
    /// Tear the CapTP session down after the frame is on outbound.
    close,
};

/// The outbound abort shape an inbound failure projects to.
pub const InboundAbort = struct {
    /// Typed `op:abort` reason kind to emit on the wire.
    kind: model.AbortKind,
    /// Static diagnostic embedded in the outbound abort.
    message: []const u8,
    /// CapTP disposition after a successful outbound push.
    disposition: AbortDisposition,
};

/// The wire-meaning domain of a dispatch error — the codec-vs-session split a C
/// consumer keys on, plus `foreign` for host-internal failures (allocation, …)
/// that carry no protocol meaning. One enum, derived everywhere, so the
/// codec/session error space is enumerated in exactly one switch (`classify`).
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
/// onto the wire, and which `Domain` a higher layer reports it as. This is the
/// single place the codec + session error space is enumerated; `abortForError`
/// and the C ABI's `feedErrorToCode` both derive from it, so they cannot drift.
/// Completeness over the codec / session / projection error sets is pinned by
/// `test/engine/error_taxonomy_test.zig`.
pub const Classification = struct {
    /// The outbound abort to project, or `null` when the error surfaces without
    /// one (`SessionClosed`, host-internal errors).
    abort: ?InboundAbort,
    domain: Domain,
};

/// Classify a dispatch `err`. Handshake refusals keep negotiating; every other
/// protocol violation closes after a successful outbound abort push.
pub fn classify(err: anyerror) Classification {
    return switch (err) {
        // ── codec decode / projection failures to malformed_frame ─────
        // `Incomplete` never escapes `decodeBody` (it is folded to
        // `MalformedFrame`); classified here defensively as malformed. The
        // Cap'n Proto structural failures (`Truncated` short/over-claimed
        // segment, `InvalidPointer` bad pointer word, `UnsupportedSegmentCount`
        // multi-segment frame) are decode malformations exactly like Syrup's
        // `MalformedFrame` — the partner sent bytes that are not a valid frame.
        error.MalformedFrame,
        error.InvalidFrameShape,
        error.MalformedView,
        error.Incomplete,
        error.Truncated,
        error.InvalidPointer,
        error.UnsupportedSegmentCount,
        => .{ .domain = .codec, .abort = .{
            .kind = .malformed_frame,
            .message = "inbound frame failed to decode",
            .disposition = .close,
        } },
        error.UnsupportedArgument, error.UnsupportedMessage, error.UnsupportedReference => .{
            .domain = .codec,
            .abort = .{
                .kind = .protocol_error,
                .message = "inbound frame carried an unsupported wire shape",
                .disposition = .close,
            },
        },
        // ── session: handshake refusals (non-closing) ────────────────
        // Both are decided before the session reaches `open`, so they emit the
        // abort without tearing down an open session.
        error.CaptpVersionMismatch => .{ .domain = .session, .abort = .{
            .kind = .version_mismatch,
            .message = "op:start-session captp-version does not match this session's profile",
            .disposition = .keep_negotiating,
        } },
        error.InvalidStartSessionSignature => .{ .domain = .session, .abort = .{
            .kind = .invalid_start_session_signature,
            .message = "op:start-session location signature failed to verify",
            .disposition = .keep_negotiating,
        } },
        // The dial-side identity pin (`Peer.expectPartnerKey`): the handshake
        // carried a valid signature, but not from the key the dialer dialed.
        // Same handshake-time refusal domain as the signature failure — the
        // session never reached `open`, so it does not close.
        error.PartnerKeyMismatch => .{ .domain = .session, .abort = .{
            .kind = .invalid_start_session_signature,
            .message = "op:start-session session key does not match the dialed key designator",
            .disposition = .keep_negotiating,
        } },
        error.QueueCapExceeded => .{ .domain = .session, .abort = .{
            .kind = .queue_cap_exceeded,
            .message = "pipelined-call queue cap exceeded on a pending answer",
            .disposition = .close,
        } },
        error.HandoffReplay => .{ .domain = .session, .abort = .{
            .kind = .handoff_replay,
            .message = "handoff-receive replayed or out-of-order handoff-count",
            .disposition = .close,
        } },
        // ── resource bounds to resource_exhausted (ADR-0025) ──────────
        // The session table caps plus the parse-stage nesting and stream
        // frame-size bounds, and the engine's drain-time local-delivery bound
        // (ADR-0007): a partner cannot push any of them past its cap.
        error.InboundAnswerCapExceeded,
        error.ListenerCapExceeded,
        error.ProjectionCapExceeded,
        error.ImportCapExceeded,
        error.HandoffCountCapExceeded,
        error.DepositedGiftCapExceeded,
        error.PendingWithdrawCapExceeded,
        error.NestingTooDeep,
        error.FrameTooLarge,
        error.LocalDeliveryCapExceeded,
        => .{ .domain = .session, .abort = .{
            .kind = .resource_exhausted,
            .message = "inbound message would push a session resource past its cap",
            .disposition = .close,
        } },
        // ── generic partner protocol violations to protocol_error ─────
        error.DuplicateSetElement,
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
            .disposition = .close,
        } },
        // A V1.0 `op:resolve` reached encode with no resolver row recorded for
        // its answer — the translation state is broken, so the session fails
        // closed rather than leave the partner hanging on an answer that can
        // never settle.
        error.MissingV1_0Resolver => .{ .domain = .session, .abort = .{
            .kind = .protocol_error,
            .message = "v1.0 resolve has no resolver recorded for its answer",
            .disposition = .close,
        } },
        // A `field` pipeline step has no Syrup wire shape
        // (`pipeline.decomposeOutboundDeliver`). The deliver is refused at send
        // time, before anything reaches the wire, so there is no abort to emit.
        error.UnsupportedPipelineOp => .{ .domain = .codec, .abort = null },
        // An already-closed session is a session-domain error, but there is no
        // abort to emit (the session is gone).
        error.SessionClosed => .{ .domain = .session, .abort = null },
        // Host-internal (OutOfMemory, …): no abort, no protocol meaning.
        else => .{ .domain = .foreign, .abort = null },
    };
}

/// Project a dispatch `err` to its outbound abort, or `null` when the engine
/// returns the error without emitting `op:abort` (`SessionClosed`, `OutOfMemory`).
pub fn abortForError(err: anyerror) ?InboundAbort {
    return classify(err).abort;
}
