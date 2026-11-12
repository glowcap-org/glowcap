//! Failure constants reflect the shared metadata fields, with no manual list.
const std = @import("std");
const Cause = @import("c_abi").BreakCause;
fn upper(comptime name: []const u8) []const u8 {
    comptime var buffer: [name.len]u8 = undefined;
    return comptime "" ++ std.ascii.upperString(&buffer, name);
}
pub fn emit(out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    inline for (.{ "origin", "reason" }) |field| {
        inline for (std.enums.values(@FieldType(Cause, field))) |value| {
            try out.print(allocator, "#define GLOWCAP_BREAK_{s}_{s} {d}u\n", .{ upper(field), upper(@tagName(value)), @backingInt(value) });
        }
    }
    const Context = @FieldType(Cause, "context");
    inline for (comptime std.meta.fieldNames(Context)) |field| {
        try out.print(allocator, "#define GLOWCAP_BREAK_CONTEXT_{s} {d}u\n", .{ upper(field), @as(u32, 1) << @bitOffsetOf(Context, field) });
    }
    inline for (std.enums.values(@import("c_abi").RouteFailure)) |value| {
        try out.print(allocator, "#define GLOWCAP_ROUTE_FAILURE_{s} {d}u\n", .{ upper(@tagName(value)), @backingInt(value) });
    }
    try out.appendSlice(allocator, "\n");
}
