//! Decode the one structured provider-failure ABI into Zig failure values.
//! Provider archives own immutable cause names. The driver validates the
//! stable result vocabulary once and projects it without allocating.
//!
//! A dial failure lands on the `DialError` retry axis by its primary cause
//! name when that name is a `DialError` member, which is how every in-tree
//! provider names a dial fault. The status code is the coarse projection a C
//! embedder acts on, and it classifies alone only when the name is foreign to
//! the axis.

const std = @import("std");

const foundation = @import("foundation");
const driver = @import("driver");
const net = @import("net");
const shared = @import("c_abi_shared");
const carrier_phase = @import("carrier_phase.zig");
const error_projection = @import("error.zig");

/// The stable result vocabulary a provider may report, each with the Zig
/// cause its report decodes to. A code outside this table is a refused
/// report, never a guess.
const statuses = [_]struct { code: i32, cause: anyerror }{
    .{ .code = shared.GLOWCAP_ERR_NULL_POINTER, .cause = error.ProviderNullPointer },
    .{ .code = shared.GLOWCAP_ERR_INVALID_ARGUMENT, .cause = error.ProviderInvalidArgument },
    .{ .code = shared.GLOWCAP_ERR_NOT_FOUND, .cause = error.ProviderNotFound },
    .{ .code = shared.GLOWCAP_ERR_INTERNAL, .cause = error.ProviderInternal },
    .{ .code = shared.GLOWCAP_ERR_WOULD_BLOCK, .cause = error.ProviderWouldBlock },
    .{ .code = shared.GLOWCAP_ERR_CLOSED, .cause = error.ProviderClosed },
    .{ .code = shared.GLOWCAP_ERR_TIMEOUT, .cause = error.ProviderTimedOut },
    .{ .code = shared.GLOWCAP_ERR_SESSION, .cause = error.ProviderSession },
    .{ .code = shared.GLOWCAP_ERR_MALFORMED, .cause = error.ProviderMalformed },
    .{ .code = shared.GLOWCAP_ERR_FRAME_TOO_LARGE, .cause = error.ProviderFrameTooLarge },
    .{ .code = shared.GLOWCAP_ERR_IO, .cause = error.ProviderIo },
};

/// The failure class whose C projection (`error.zig`) is `code`, read back
/// from that projection so the two directions cannot disagree. A null
/// pointer is an invalid argument the projection never emits.
fn classificationOf(comptime code: i32) foundation.FailureClassification {
    if (code == shared.GLOWCAP_ERR_NULL_POINTER) return .invalid_argument;
    for (std.enums.values(foundation.FailureClassification)) |class| {
        if (error_projection.code(class) == code) return class;
    }
    @compileError(std.fmt.comptimePrint("provider status {d} has no failure class", .{code}));
}

comptime {
    // Every class the driver projects to C decodes back from a provider.
    for (std.enums.values(foundation.FailureClassification)) |class| {
        for (statuses) |row| {
            if (row.code == error_projection.code(class)) break;
        } else @compileError("failure class " ++ @tagName(class) ++ " has no provider status row");
    }
}

const Status = struct { cause: anyerror, classification: foundation.FailureClassification };

/// A stable status decoded, or null when `code` is outside the vocabulary.
fn status(code: i32) ?Status {
    inline for (statuses) |row| {
        if (row.code == code) return .{ .cause = row.cause, .classification = comptime classificationOf(row.code) };
    }
    return null;
}

fn name(pointer: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0 or pointer == null) return null;
    const bytes = pointer.?[0..len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return bytes;
}

pub fn operation(
    code: i32,
    report: shared.GlowcapProviderFailure,
) error{InvalidProviderFailure}!driver.OperationFailure {
    const primary_name = name(report.primary_name, report.primary_name_len);
    const secondary_name = name(report.secondary_name, report.secondary_name_len);
    const phase = carrier_phase.decode(report.carrier_phase) catch
        return error.InvalidProviderFailure;
    const detail = carrier_phase.decodeDetail(
        phase,
        report.carrier_detail_flags,
        report.carrier_verification_flags,
        report.carrier_peer_alert,
        report.carrier_engine_code,
    ) catch return error.InvalidProviderFailure;
    if (report.result != code or primary_name == null) return error.InvalidProviderFailure;
    const primary = status(code) orelse return error.InvalidProviderFailure;
    var failure: driver.OperationFailure = .{
        .chain = .{
            .cause = primary.cause,
            .cause_name = primary_name,
            .classification = primary.classification,
        },
        .carrier_phase = phase,
        .carrier_detail = detail,
    };
    if (report.secondary_count == 0) {
        if (report.secondary_result != 0 or report.secondary_name != null or report.secondary_name_len != 0)
            return error.InvalidProviderFailure;
        return failure;
    }
    if (report.secondary_count > std.math.maxInt(u16) or secondary_name == null)
        return error.InvalidProviderFailure;
    const secondary = status(report.secondary_result) orelse return error.InvalidProviderFailure;
    failure.chain.secondary_cause = secondary.cause;
    failure.chain.secondary_cause_name = secondary_name;
    failure.chain.secondary_classification = secondary.classification;
    failure.chain.secondary_count = @intCast(report.secondary_count);
    return failure;
}

pub fn chain(
    code: i32,
    report: shared.GlowcapProviderFailure,
) error{InvalidProviderFailure}!foundation.FailureChain {
    return (try operation(code, report)).chain;
}

/// Project a provider's dial failure onto the `DialError` retry axis. A
/// primary cause name that is a `DialError` member is that classification, so
/// a refused connect the provider named stays permanent under ADR-0030
/// `isTransient` even though it rides the I/O status code. Without such a
/// name the status code decides. An I/O fault is `ConnectionLost`, unless its
/// secure handshake failed certificate verification: no retry changes the
/// certificate or the trust it was checked against, so that one is refused.
fn dialError(code: i32, failure: driver.OperationFailure) net.netlayer.DialError {
    if (failure.chain.cause_name) |named| {
        inline for (@typeInfo(net.netlayer.DialError).error_set.error_names.?) |member| {
            if (std.mem.eql(u8, member, named)) return @field(net.netlayer.DialError, member);
        }
    }
    const verification_refused = failure.carrier_phase == .secure_handshake and
        failure.carrier_detail.verification_flags != 0;
    return switch (code) {
        shared.GLOWCAP_ERR_INVALID_ARGUMENT => error.InvalidAddress,
        shared.GLOWCAP_ERR_TIMEOUT => error.TimedOut,
        shared.GLOWCAP_ERR_WOULD_BLOCK => error.WouldBlock,
        shared.GLOWCAP_ERR_INTERNAL => error.OutOfMemory,
        else => if (verification_refused) error.ConnectionRefused else error.ConnectionLost,
    };
}

pub fn dial(
    code: i32,
    report: shared.GlowcapProviderFailure,
) error{InvalidProviderFailure}!net.netlayer.DialFailure {
    const failure = try operation(code, report);
    return .{
        .classification = dialError(code, failure),
        .chain = failure.chain,
        .carrier_phase = failure.carrier_phase,
        .carrier_detail = failure.carrier_detail,
    };
}

pub const isEmpty = shared.transport_provider.providerFailureEmpty;
