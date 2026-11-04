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
        .target => "Ref",
        .pending_target => "Ref | RemotePromise",
        .text => "string",
        .integer => "bigint",
        .nothing => "void",
        .value => "Argument",
        .pending_value => "RemotePromise",
        .list, .tuple, .record => unreachable,
    };
}

pub fn invalid(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type, value: []const u8) !void {
    switch (kind) {
        .boolean => try out.print(a, "typeof {s} !== \"boolean\"", .{value}),
        .integer => try out.print(a, "typeof {s} !== \"bigint\"", .{value}),
        .text => try out.print(a, "typeof {s} !== \"string\"", .{value}),
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
        .integer => |limits| {
            try out.appendSlice(a, "integer_");
            try endpoint(out, a, limits.min);
            try out.appendSlice(a, "_");
            try endpoint(out, a, limits.max);
        },
        .text, .bytes => |limits| {
            if (kind == .text and !bounded(limits)) return out.appendSlice(a, "text");
            try out.print(a, "{s}_{d}_", .{ if (kind == .text) "text" else "bytes", limits.min });
            if (limits.max) |max| try out.print(a, "{d}", .{max}) else try out.appendSlice(a, "unbounded");
        },
        .boolean => try out.appendSlice(a, "boolean_value"),
        .symbol => try out.appendSlice(a, "symbol_value"),
        .float64 => try out.appendSlice(a, "float64_value"),
        .error_value => try out.appendSlice(a, "error_value"),
        else => unreachable,
    }
}

pub fn supported(kind: calls.Type) !void {
    switch (kind) {
        .list, .tuple, .record => return error.UnsupportedProjection,
        else => {},
    }
}

pub fn checked(kind: calls.Type) bool {
    return kind == .integer or (kind == .text and bounded(kind.text));
}

fn endpoint(out: *std.ArrayList(u8), a: std.mem.Allocator, value: ?i64) !void {
    if (value) |number| try out.print(a, "{c}{d}", .{ @as(u8, if (number < 0) 'm' else 'p'), @abs(number) }) else try out.appendSlice(a, "unbounded");
}

pub fn replies(out: *std.ArrayList(u8), a: std.mem.Allocator, types: []const calls.Type, methods: []const calls.Named) !void {
    var text_bounds = false;
    for (types) |kind| {
        text_bounds = text_bounds or (kind == .text and bounded(kind.text));
    }
    for (methods) |method| for (method.call.parameters) |kind| {
        text_bounds = text_bounds or (kind == .text and bounded(kind.text));
    };
    if (text_bounds) try out.appendSlice(a, @embedFile("templates/text_bounds.ts.in"));
    for (types) |kind| {
        switch (kind) {
            .boolean, .bytes, .symbol, .float64, .error_value, .integer => {},
            .text => |limits| if (!bounded(limits)) continue,
            else => continue,
        }
        try reply(out, a, kind);
    }
    for (methods, 0..) |method, i| for (method.call.parameters, 0..) |kind, j| {
        if (!checked(kind)) continue;
        var seen = false;
        for (types) |previous| {
            seen = seen or std.meta.eql(previous, kind);
        }
        for (methods[0..i]) |previous| for (previous.call.parameters) |parameter| {
            seen = seen or std.meta.eql(parameter, kind);
        };
        for (method.call.parameters[0..j]) |previous| {
            seen = seen or std.meta.eql(previous, kind);
        }
        if (!seen) try reply(out, a, kind);
    };
}

fn reply(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: calls.Type) !void {
    try out.appendSlice(a, "function ");
    try decoder(out, a, kind);
    try out.print(a, "(value: {s}): {s} {{\n\tif (", .{ if (checked(kind)) "unknown" else "Argument", typeName(kind) });
    try invalid(out, a, kind, "value");
    try out.appendSlice(a, ") throw new TypeError(\"wrong scalar value\");\n");
    if (kind == .bytes and bounded(kind.bytes)) {
        try out.appendSlice(a, "\tif (");
        try byteBounds(out, a, kind.bytes, "value");
        try out.appendSlice(a, ") throw new TypeError(\"byte reply outside bounds\");\n");
    }
    switch (kind) {
        .integer => |limits| {
            if (limits.min != null or limits.max != null) {
                try out.appendSlice(a, "\tif (");
                if (limits.min) |min| try out.print(a, "value < {d}n", .{min});
                if (limits.max) |max| {
                    if (limits.min != null) try out.appendSlice(a, " || ");
                    try out.print(a, "value > {d}n", .{max});
                }
                try out.appendSlice(a, ") throw new TypeError(\"integer outside bounds\");\n");
            }
        },
        .text => |limits| {
            try out.print(a, "\ttext_bytes(value, {d}n, ", .{limits.min});
            if (limits.max) |max| try out.print(a, "{d}n", .{max}) else try out.appendSlice(a, "null");
            try out.appendSlice(a, ");\n");
        },
        else => {},
    }
    try out.appendSlice(a, "\treturn value;\n}\n");
}
