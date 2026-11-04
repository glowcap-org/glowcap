//! Exact JavaScript representations for the admitted scalar vocabulary.
const std = @import("std");
const calls = @import("calls.zig");

pub fn typeName(kind: calls.Type) []const u8 {
    return switch (kind) {
        .boolean => "boolean",
        .bytes => "Uint8Array",
        .symbol => "Sym",
        .float64 => "number",
        .error_value => "Error",
        else => unreachable,
    };
}

pub fn invalid(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type, value: []const u8) !void {
    switch (kind) {
        .boolean => try out.print(a, "typeof {s} !== \"boolean\"", .{value}),
        .float64 => try out.print(a, "typeof {s} !== \"number\"", .{value}),
        .bytes, .symbol, .error_value => try out.print(a, "!({s} instanceof {s})", .{ value, typeName(kind) }),
        else => unreachable,
    }
}

pub fn bounded(limits: @import("call_type.zig").ByteBounds) bool {
    return limits.min != 0 or limits.max != null;
}

pub fn byteBounds(out: *std.ArrayList(u8), a: std.mem.Allocator, limits: @import("call_type.zig").ByteBounds, value: []const u8) !void {
    // Relational number/bigint comparison preserves u64 schema endpoints and
    // avoids allocating a converted BigInt for the byteLength on each call.
    if (limits.min != 0) try out.print(a, "{s}.byteLength < {d}n", .{ value, limits.min });
    if (limits.max) |max| {
        if (limits.min != 0) try out.appendSlice(a, " || ");
        try out.print(a, "{s}.byteLength > {d}n", .{ value, max });
    }
}

pub fn decoder(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type) !void {
    switch (kind) {
        .bytes => |limits| {
            try out.print(a, "bytes_{d}_", .{limits.min});
            if (limits.max) |max| try out.print(a, "{d}", .{max}) else try out.appendSlice(a, "unbounded");
        },
        .boolean => try out.appendSlice(a, "boolean_value"),
        .symbol => try out.appendSlice(a, "symbol_value"),
        .float64 => try out.appendSlice(a, "float64_value"),
        .error_value => try out.appendSlice(a, "error_value"),
        else => unreachable,
    }
}

pub fn replies(out: *std.ArrayList(u8), a: std.mem.Allocator, methods: []const calls.Named) !void {
    for (methods, 0..) |method, i| {
        const kind = method.call.result;
        switch (kind) {
            .boolean, .bytes, .symbol, .float64, .error_value => {},
            else => continue,
        }
        if (method.call.effect != .call) continue;
        var seen = false;
        for (methods[0..i]) |previous| if (previous.call.effect == .call and std.meta.eql(previous.call.result, kind)) {
            seen = true;
        };
        if (seen) continue;
        try out.appendSlice(a, "function ");
        try decoder(out, a, kind);
        try out.print(a, "(value: Argument): {s} {{\n\tif (", .{typeName(kind)});
        try invalid(out, a, kind, "value");
        try out.appendSlice(a, ") throw new TypeError(\"wrong scalar reply\");\n");
        if (kind == .bytes and bounded(kind.bytes)) {
            try out.appendSlice(a, "\tif (");
            try byteBounds(out, a, kind.bytes, "value");
            try out.appendSlice(a, ") throw new TypeError(\"byte reply outside bounds\");\n");
        }
        try out.appendSlice(a, "\treturn value;\n}\n");
    }
}
