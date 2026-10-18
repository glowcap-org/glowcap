//! C projection of the central unreturned-failure model (ADR-0115).

const std = @import("std");
const core = @import("diagnostics");
const c_values = @import("value.zig");

pub const abi_version: u32 = 1;
pub const Layer = core.Layer;
pub const ScopeKind = core.ScopeKind;
pub const Input = core.Input;
pub const Journal = core.Journal;
pub const Claim = core.Claim;
pub const truncated_operation = core.truncated_operation;
pub const truncated_primary_name = core.truncated_primary_name;
pub const truncated_primary_message = core.truncated_primary_message;
pub const truncated_secondary_name = core.truncated_secondary_name;
pub const truncated_secondary_message = core.truncated_secondary_message;

pub const GlowcapFailureReport = extern struct {
    abi_version: u32,
    struct_size: usize,
    layer: u32,
    scope_kind: u32,
    scope_id: u64,
    operation_id: u64,
    primary_result: i32,
    secondary_result: i32,
    secondary_count: u32,
    operation: ?[*]const u8,
    operation_len: usize,
    primary_name: ?[*]const u8,
    primary_name_len: usize,
    primary_message: ?[*]const u8,
    primary_message_len: usize,
    secondary_name: ?[*]const u8,
    secondary_name_len: usize,
    secondary_message: ?[*]const u8,
    secondary_message_len: usize,
};

pub const GlowcapFailureEvent = extern struct {
    abi_version: u32,
    struct_size: usize,
    sequence: u64,
    dropped_before: u64,
    layer: u32,
    scope_kind: u32,
    scope_id: u64,
    operation_id: u64,
    primary_result: i32,
    secondary_result: i32,
    secondary_count: u32,
    flags: u32,
    operation: ?[*]const u8,
    operation_len: usize,
    primary_name: ?[*]const u8,
    primary_name_len: usize,
    primary_message: ?[*]const u8,
    primary_message_len: usize,
    secondary_name: ?[*]const u8,
    secondary_name_len: usize,
    secondary_message: ?[*]const u8,
    secondary_message_len: usize,
};

pub const ReportError = error{ InvalidVersion, InvalidSize, InvalidLayer, InvalidScope, NullPointer, InvalidUtf8 };

fn layerFromInt(value: u32) ReportError!Layer {
    return switch (value) {
        inline 0...4 => |v| @fromBackingInt(@intCast(v)),
        else => error.InvalidLayer,
    };
}

fn scopeFromInt(value: u32) ReportError!ScopeKind {
    return switch (value) {
        inline 0...6 => |v| @fromBackingInt(@intCast(v)),
        else => error.InvalidScope,
    };
}

fn text(ptr: ?[*]const u8, len: usize) ReportError![]const u8 {
    const bytes = try c_values.sliceFromC(ptr, len);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

pub fn inputFromReport(report: GlowcapFailureReport) ReportError!Input {
    if (report.abi_version != abi_version) return error.InvalidVersion;
    if (report.struct_size < @sizeOf(GlowcapFailureReport)) return error.InvalidSize;
    const operation = try text(report.operation, report.operation_len);
    const primary_name = try text(report.primary_name, report.primary_name_len);
    if (operation.len == 0 or primary_name.len == 0) return error.NullPointer;
    return .{
        .layer = try layerFromInt(report.layer),
        .operation = operation,
        .scope_kind = try scopeFromInt(report.scope_kind),
        .scope_id = report.scope_id,
        .operation_id = report.operation_id,
        .primary_result = report.primary_result,
        .primary_name = primary_name,
        .primary_message = try text(report.primary_message, report.primary_message_len),
        .secondary_result = report.secondary_result,
        .secondary_name = try text(report.secondary_name, report.secondary_name_len),
        .secondary_message = try text(report.secondary_message, report.secondary_message_len),
        .secondary_count = report.secondary_count,
    };
}

fn optionalPtr(bytes: []const u8) ?[*]const u8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

pub fn eventFromClaim(claim: Claim) GlowcapFailureEvent {
    return .{
        .abi_version = abi_version,
        .struct_size = @sizeOf(GlowcapFailureEvent),
        .sequence = claim.sequence,
        .dropped_before = claim.dropped_before,
        .layer = @backingInt(claim.layer),
        .scope_kind = @backingInt(claim.scope_kind),
        .scope_id = claim.scope_id,
        .operation_id = claim.operation_id,
        .primary_result = claim.primary_result,
        .secondary_result = claim.secondary_result,
        .secondary_count = claim.secondary_count,
        .flags = claim.flags,
        .operation = optionalPtr(claim.operation),
        .operation_len = claim.operation.len,
        .primary_name = optionalPtr(claim.primary_name),
        .primary_name_len = claim.primary_name.len,
        .primary_message = optionalPtr(claim.primary_message),
        .primary_message_len = claim.primary_message.len,
        .secondary_name = optionalPtr(claim.secondary_name),
        .secondary_name_len = claim.secondary_name.len,
        .secondary_message = optionalPtr(claim.secondary_message),
        .secondary_message_len = claim.secondary_message.len,
    };
}
