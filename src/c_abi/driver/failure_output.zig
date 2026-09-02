//! Versioned caller-owned outcome for deterministic driver barriers.
//!
//! Thread-local `last_error` remains human detail for one synchronous call.
//! This fixed record is the machine contract for provider installation,
//! listener close, and the consuming loop-release barrier, including the first
//! cleanup consequence and total consequence count.

const driver = @import("driver");
const shared = @import("c_abi_shared");
const driver_error = @import("error.zig");
const carrier_phase = @import("carrier_phase.zig");

pub const abi_version: u32 = 2;

pub const GlowcapDriverFailure = extern struct {
    abi_version: u32,
    struct_size: usize,
    primary_result: i32,
    secondary_result: i32,
    secondary_count: u32,
    /// GLOWCAP_CARRIER_PHASE_* or NONE when the failure is not carrier-owned.
    carrier_phase: u32,
    carrier_detail_flags: u32,
    carrier_verification_flags: u32,
    carrier_peer_alert: u32,
    carrier_engine_code: i32,
    primary_name: ?[*]const u8,
    primary_name_len: usize,
    secondary_name: ?[*]const u8,
    secondary_name_len: usize,

    pub fn init() GlowcapDriverFailure {
        return .{
            .abi_version = abi_version,
            .struct_size = @sizeOf(GlowcapDriverFailure),
            .primary_result = shared.GLOWCAP_OK,
            .secondary_result = shared.GLOWCAP_OK,
            .secondary_count = 0,
            .carrier_phase = shared.transport_provider.GLOWCAP_CARRIER_PHASE_NONE,
            .carrier_detail_flags = 0,
            .carrier_verification_flags = 0,
            .carrier_peer_alert = 0,
            .carrier_engine_code = 0,
            .primary_name = null,
            .primary_name_len = 0,
            .secondary_name = null,
            .secondary_name_len = 0,
        };
    }
};

pub const SlotError = error{ NullPointer, InvalidLayout };
pub const Claim = union(enum) { slot: *GlowcapDriverFailure, refused: i32 };

/// Validate before a consuming operation changes ownership. A valid slot is
/// cleared immediately, so success and every refusal have one deterministic
/// output shape.
pub fn begin(out: ?*GlowcapDriverFailure) SlotError!*GlowcapDriverFailure {
    const slot = out orelse return error.NullPointer;
    if (slot.abi_version != abi_version or
        slot.struct_size < @sizeOf(GlowcapDriverFailure)) return error.InvalidLayout;
    slot.* = .init();
    return slot;
}

pub fn claim(out: ?*GlowcapDriverFailure, operation: []const u8) Claim {
    return .{ .slot = begin(out) catch |err| {
        shared.setLastError("{s}: invalid failure output: {s}", .{ operation, @errorName(err) });
        return .{ .refused = if (err == error.NullPointer)
            shared.GLOWCAP_ERR_NULL_POINTER
        else
            shared.GLOWCAP_ERR_INVALID_ARGUMENT };
    } };
}

pub fn refuse(slot: *GlowcapDriverFailure, result: i32, cause: anyerror) i32 {
    project(slot, result, .fromError(cause));
    return result;
}

pub fn operationCode(runtime: anytype, err: anyerror) i32 {
    const failure = runtime.operationFailure(err);
    if (failure.cause != error.InvalidArgument or failure.secondary_cause != null)
        setLastError("driver", failure);
    return driver_error.code(failure.kind);
}

pub fn project(
    slot: *GlowcapDriverFailure,
    primary_result: i32,
    failure: driver.OperationFailure,
) void {
    const primary_name = failure.primaryName();
    slot.primary_result = primary_result;
    slot.primary_name = primary_name.ptr;
    slot.primary_name_len = primary_name.len;
    slot.secondary_count = failure.secondary_count;
    const carrier = carrier_phase.project(failure.carrier_phase, failure.carrier_detail);
    slot.carrier_phase = carrier.phase;
    slot.carrier_detail_flags = carrier.detail_flags;
    slot.carrier_verification_flags = carrier.verification_flags;
    slot.carrier_peer_alert = carrier.peer_alert;
    slot.carrier_engine_code = carrier.engine_code;
    if (failure.secondary_cause) |cause| {
        const secondary_name = failure.secondaryName().?;
        slot.secondary_result = if (failure.secondary_kind) |kind|
            driver_error.code(kind)
        else
            driver_error.fromError(cause);
        slot.secondary_name = secondary_name.ptr;
        slot.secondary_name_len = secondary_name.len;
    }
}

pub fn setLastError(prefix: []const u8, failure: driver.OperationFailure) void {
    if (failure.secondary_cause != null) {
        shared.setLastError("{s}: {s}; cleanup: {s} ({d} secondary failures)", .{
            prefix,
            failure.primaryName(),
            failure.secondaryName().?,
            failure.secondary_count,
        });
    } else {
        shared.setLastError("{s}: {s}", .{ prefix, failure.primaryName() });
    }
}

pub fn note(target: *?driver.OperationFailure, later: driver.OperationFailure) void {
    if (target.*) |*failure| failure.noteFailure(later) else target.* = later;
}

pub fn noteError(target: *?driver.OperationFailure, cause: anyerror) void {
    note(target, .fromError(cause));
}
