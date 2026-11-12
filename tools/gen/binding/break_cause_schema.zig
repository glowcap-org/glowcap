//! Reflected failure metadata shared by the C and language projections.
const std = @import("std");
const abi = @import("c_abi");
pub const Cause = abi.BreakCause;
pub const RouteFailure = abi.RouteFailure;
pub const Origin = @FieldType(Cause, "origin");
pub const Reason = @FieldType(Cause, "reason");
pub const Context = @FieldType(Cause, "context");
pub const Buffer = std.ArrayList(u8);

pub fn pascal(out: *Buffer, allocator: std.mem.Allocator, name: []const u8) !void {
    var capitalize = true;
    for (name) |char| {
        if (char == '_') {
            capitalize = true;
        } else {
            try out.append(allocator, if (capitalize) std.ascii.toUpper(char) else char);
            capitalize = false;
        }
    }
}
pub fn upper(out: *Buffer, allocator: std.mem.Allocator, name: []const u8) !void {
    for (name) |char| try out.append(allocator, std.ascii.toUpper(char));
}
pub fn kebab(out: *Buffer, allocator: std.mem.Allocator, name: []const u8) !void {
    for (name) |char| try out.append(allocator, if (char == '_') '-' else char);
}
pub fn valid(comptime origin: Origin, comptime reason: Reason) bool {
    return if (abi.GlowcapBreakCause.fromCore(.{ .origin = origin, .reason = reason }).toCore()) |_| true else |err| switch (err) {
        error.InvalidArgument => false,
    };
}
pub fn contextMask(comptime field: []const u8) u32 {
    return @as(u32, 1) << @bitOffsetOf(Context, field);
}
pub fn contextBits(value: Context) u32 {
    return @as(@typeInfo(Context).@"struct".backing_integer.?, @bitCast(value));
}
pub const context_mask = std.math.maxInt(@typeInfo(Context).@"struct".backing_integer.?);
