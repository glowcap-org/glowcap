//! Why a session tore down.
//!
//! `AbortKind` is the closed set of reasons a peer ends a session. `AbortReason`
//! pairs one with a human-readable message. The V1.0 single-string wire form
//! `"<Label>: <message>"` is the codec's vocabulary, not the model's, the
//! Syrup encoder builds it from `kind.wireName()` and the decoder recovers the
//! kind from the prefix. No codec, no allocation, no authority here.

const std = @import("std");

pub const AbortKind = enum {
    normal_shutdown,
    version_mismatch,
    protocol_error,
    timeout,
    unauthorized,
    invalid_handoff_signature,
    handoff_replay,
    queue_cap_exceeded,
    pipelining_not_negotiated,
    wire_delta_not_negotiated,
    handoffs_not_negotiated,
    sturdyrefs_not_negotiated,
    invalid_start_session_signature,
    crossed_hellos,
    connection_lost,
    graceful_shutdown,
    malformed_frame,
    resource_exhausted,
    other,

    pub fn wireName(self: AbortKind) []const u8 {
        return switch (self) {
            .normal_shutdown => "NormalShutdown",
            .version_mismatch => "VersionMismatch",
            .protocol_error => "ProtocolError",
            .timeout => "Timeout",
            .unauthorized => "Unauthorized",
            .invalid_handoff_signature => "InvalidHandoffSignature",
            .handoff_replay => "HandoffReplay",
            .queue_cap_exceeded => "QueueCapExceeded",
            .pipelining_not_negotiated => "PipeliningNotNegotiated",
            .wire_delta_not_negotiated => "WireDeltaNotNegotiated",
            .handoffs_not_negotiated => "HandoffsNotNegotiated",
            .sturdyrefs_not_negotiated => "SturdyrefsNotNegotiated",
            .invalid_start_session_signature => "InvalidStartSessionSignature",
            .crossed_hellos => "CrossedHellos",
            .connection_lost => "ConnectionLost",
            .graceful_shutdown => "GracefulShutdown",
            .malformed_frame => "MalformedFrame",
            .resource_exhausted => "ResourceExhausted",
            .other => "Other",
        };
    }

    /// The inverse of `wireName`, derived from it: every variant is matched by
    /// the exact string `wireName` emits, so the two directions cannot drift and
    /// a new variant is covered the moment it has a `wireName` arm.
    pub fn fromWireName(name: []const u8) ?AbortKind {
        inline for (@typeInfo(AbortKind).@"enum".field_values) |field_value| {
            const kind: AbortKind = @fromBackingInt(@intCast(field_value));
            if (std.mem.eql(u8, kind.wireName(), name)) return kind;
        }
        return null;
    }
};

/// A typed abort reason: the kind plus a human-readable message. The V1.0
/// single-string wire form `"<Label>: <message>"` is the codec's vocabulary,
/// not the model's, the Syrup encoder builds it from `kind.wireName()` and
/// the Syrup decoder recovers the kind from the prefix, falling back to
/// `.other` when no label matches.
pub const AbortReason = struct {
    kind: AbortKind,
    message: []const u8,
};
