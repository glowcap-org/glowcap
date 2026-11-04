//! Rust lowering for checked constraints. No description AST reaches this layer.
const std = @import("std");
const calls = @import("calls.zig");

pub fn supported(kind: calls.Type) !void {
    if (kind == .integer and (kind.integer.min == null or kind.integer.max == null)) return error.UnsupportedTarget;
}

pub fn fallible(kind: calls.Type) bool {
    return switch (kind) {
        .text, .bytes => |bounds| bounds.min != 0 or bounds.max != null,
        .integer => true,
        else => false,
    };
}

pub fn decoder(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type) !void {
    switch (kind) {
        .text, .bytes => |bounds| {
            const name = if (kind == .text) "text" else "bytes";
            if (!fallible(kind)) return out.appendSlice(a, name);
            try out.print(a, "{s}_{d}_", .{ name, bounds.min });
            if (bounds.max) |maximum| try out.print(a, "{d}", .{maximum}) else try out.appendSlice(a, "unbounded");
        },
        .integer => |bounds| {
            try supported(kind);
            const minimum = bounds.min.?;
            const maximum = bounds.max.?;
            try out.print(a, "integer_{c}{d}_{c}{d}", .{ @as(u8, if (minimum < 0) 'm' else 'p'), @abs(minimum), @as(u8, if (maximum < 0) 'm' else 'p'), @abs(maximum) });
        },
        .boolean => try out.appendSlice(a, "boolean"),
        .symbol => try out.appendSlice(a, "symbol"),
        .float64 => try out.appendSlice(a, "float64"),
        .error_value => try out.appendSlice(a, "error_value"),
        .target => try out.appendSlice(a, "capability"),
        .nothing => try out.appendSlice(a, "nothing"),
        .value => try out.appendSlice(a, "Ok"),
        .pending_target, .pending_value => return error.UnsupportedProjection,
    }
}

fn outside(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type, value: []const u8) !void {
    switch (kind) {
        .integer => |bounds| try out.print(a, "!({d}..={d}).contains(&{s})", .{ bounds.min.?, bounds.max.?, value }),
        .text, .bytes => |bounds| if (bounds.max) |maximum| {
            try out.print(a, "!({d}u128..={d}u128).contains(&({s}.len() as u128))", .{ bounds.min, maximum, value });
        } else try out.print(a, "({s}.len() as u128) < {d}u128", .{ value, bounds.min }),
        else => unreachable,
    }
}

pub fn argument(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type, index: usize, optional: bool) !void {
    if (!fallible(kind)) return;
    try supported(kind);
    if (optional) try out.print(a, "\tif let Some(value) = arg{d}{s}\n\t\t&& ", .{ index, if (kind == .bytes) ".as_ref()" else "" }) else try out.appendSlice(a, "\tif ");
    var name: [32]u8 = undefined;
    const value = if (optional) "value" else try std.fmt.bufPrint(&name, "arg{d}", .{index});
    try outside(out, a, kind, value);
    try out.appendSlice(a, if (optional) "\n\t{\n" else " {\n");
    try out.appendSlice(a, "\t\treturn Err(Error::InvalidArgument);\n\t}\n");
}

pub fn replies(out: *std.ArrayList(u8), a: std.mem.Allocator, methods: []const calls.Named) !void {
    for (methods, 0..) |method, i| {
        const kind = method.call.result;
        if (method.call.effect == .tell or !fallible(kind)) continue;
        var seen = false;
        for (methods[0..i]) |previous| {
            if (previous.call.effect != .tell and std.meta.eql(previous.call.result, kind)) seen = true;
        }
        if (seen) continue;
        try out.appendSlice(a, "fn ");
        try decoder(out, a, kind);
        try out.print(a, "(value: Argument) -> Result<{s}, Error> {{\n\tlet value = {s}(value)?;\n\tif ", .{ if (kind == .text) "String" else if (kind == .bytes) "Vec<u8>" else "i64", if (kind == .text) "text" else if (kind == .bytes) "bytes" else "integer" });
        try outside(out, a, kind, "value");
        try out.appendSlice(a, " {\n\t\tErr(Error::InvalidReply)\n\t} else {\n\t\tOk(value)\n\t}\n}\n");
    }
}
