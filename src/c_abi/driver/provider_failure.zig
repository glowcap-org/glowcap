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

fn statusError(code: i32) anyerror {
    return switch (code) {
        shared.GLOWCAP_ERR_NULL_POINTER => error.ProviderNullPointer,
        shared.GLOWCAP_ERR_INVALID_ARGUMENT => error.ProviderInvalidArgument,
        shared.GLOWCAP_ERR_INTERNAL => error.ProviderInternal,
        shared.GLOWCAP_ERR_WOULD_BLOCK => error.ProviderWouldBlock,
        shared.GLOWCAP_ERR_CLOSED => error.ProviderClosed,
        shared.GLOWCAP_ERR_TIMEOUT => error.ProviderTimedOut,
        shared.GLOWCAP_ERR_SESSION => error.ProviderSession,
        shared.GLOWCAP_ERR_MALFORMED => error.ProviderMalformed,
        shared.GLOWCAP_ERR_FRAME_TOO_LARGE => error.ProviderFrameTooLarge,
        shared.GLOWCAP_ERR_IO => error.ProviderIo,
        else => error.ProviderFailure,
    };
}

fn statusClassification(code: i32) foundation.FailureClassification {
    return switch (code) {
        shared.GLOWCAP_ERR_NULL_POINTER,
        shared.GLOWCAP_ERR_INVALID_ARGUMENT,
        => .invalid_argument,
        shared.GLOWCAP_ERR_INTERNAL => .internal,
        shared.GLOWCAP_ERR_WOULD_BLOCK => .would_block,
        shared.GLOWCAP_ERR_CLOSED => .closed,
        shared.GLOWCAP_ERR_TIMEOUT => .timeout,
        shared.GLOWCAP_ERR_SESSION => .session,
        shared.GLOWCAP_ERR_MALFORMED => .malformed,
        shared.GLOWCAP_ERR_FRAME_TOO_LARGE => .frame_too_large,
        shared.GLOWCAP_ERR_IO => .io,
        else => unreachable,
    };
}

fn statusIsStable(code: i32) bool {
    return switch (code) {
        shared.GLOWCAP_ERR_NULL_POINTER,
        shared.GLOWCAP_ERR_INVALID_ARGUMENT,
        shared.GLOWCAP_ERR_INTERNAL,
        shared.GLOWCAP_ERR_WOULD_BLOCK,
        shared.GLOWCAP_ERR_CLOSED,
        shared.GLOWCAP_ERR_TIMEOUT,
        shared.GLOWCAP_ERR_SESSION,
        shared.GLOWCAP_ERR_MALFORMED,
        shared.GLOWCAP_ERR_FRAME_TOO_LARGE,
        shared.GLOWCAP_ERR_IO,
        => true,
        else => false,
    };
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
    const valid_secondary = if (report.secondary_count == 0)
        report.secondary_result == 0 and report.secondary_name == null and report.secondary_name_len == 0
    else
        report.secondary_count <= std.math.maxInt(u16) and
            statusIsStable(report.secondary_result) and secondary_name != null;
    if (report.result != code or !statusIsStable(code) or primary_name == null or !valid_secondary)
        return error.InvalidProviderFailure;
    var failure: driver.OperationFailure = .{
        .chain = .{
            .cause = statusError(code),
            .cause_name = primary_name,
            .classification = statusClassification(code),
        },
        .carrier_phase = phase,
        .carrier_detail = detail,
    };
    if (report.secondary_count != 0) {
        failure.chain.secondary_cause = statusError(report.secondary_result);
        failure.chain.secondary_cause_name = secondary_name;
        failure.chain.secondary_classification = statusClassification(report.secondary_result);
        failure.chain.secondary_count = @intCast(report.secondary_count);
    }
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

pub fn isEmpty(report: shared.GlowcapProviderFailure) bool {
    return shared.transport_provider.providerFailureEmpty(report);
}
