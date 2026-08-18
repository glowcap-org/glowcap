//! Bounded local failure evidence retained by one protocol Peer.
//!
//! This is diagnostic data, not process policy: the protocol transition and
//! its returned error remain authoritative. The record preserves one primary,
//! one later consequence, and a saturating consequence count without adding a
//! journal or allocation to every peer.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const abort_projection = @import("abort_projection.zig");

pub const AbortInfo = struct {
    /// Protocol classification of the Zig cause, independent of a boundary-
    /// supplied diagnostic name.
    domain: abort_projection.Domain,
    kind: ?model.AbortKind,
    /// Static abort text chosen by the protocol projection.
    message: []const u8,
    /// Stable `@errorName` or process-lifetime boundary name.
    error_name: []const u8,
    /// Failure publishing the protocol abort, when that was a separate act.
    abort_delivery_error: ?anyerror = null,
    /// First cleanup/consequence after the primary.
    secondary_error: ?anyerror = null,
    /// Saturating count of every cleanup/consequence after the primary.
    secondary_error_count: u8 = 0,
};

pub fn record(target: *?AbortInfo, cause: anyerror) void {
    target.* = fromCause(cause, @errorName(cause));
}

/// Replace the current record with one exact bounded causal chain. Boundary-
/// supplied primary names remain diagnostic identity; the Zig cause continues
/// to own protocol classification.
pub fn recordChain(target: *?AbortInfo, chain: foundation.FailureChain) void {
    var info = fromCause(chain.cause, chain.primaryName());
    info.secondary_error = chain.secondary_cause;
    info.secondary_error_count = @intCast(@min(
        chain.secondary_count,
        @as(u16, std.math.maxInt(u8)),
    ));
    target.* = info;
}

pub fn recordAbortDelivery(target: *?AbortInfo, cause: anyerror) void {
    const info = &(target.* orelse {
        record(target, cause);
        return;
    });
    info.abort_delivery_error = cause;
}

pub fn recordSecondary(target: *?AbortInfo, cause: anyerror) void {
    const info = &(target.* orelse {
        record(target, cause);
        return;
    });
    if (info.secondary_error == null) info.secondary_error = cause;
    info.secondary_error_count +|= 1;
}

fn fromCause(cause: anyerror, name: []const u8) AbortInfo {
    const classified = abort_projection.classify(cause);
    return .{
        .domain = classified.domain,
        .kind = if (classified.abort) |abort| abort.kind else null,
        .message = if (classified.abort) |abort| abort.message else "",
        .error_name = name,
    };
}
