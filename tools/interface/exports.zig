//! Public export names are independent of compiler-owned implementation names.
//! Support export rows own both collision checks and the emitted declarations.
const std = @import("std");
const calls = @import("calls.zig");

pub const Support = struct { name: []const u8, enabled: bool = true, implementation: ?[]const u8 = null };

fn validate(methods: []const calls.Named, support: []const Support) !void {
    for (support, 0..) |item, i| if (item.enabled) {
        try identifier(item.name);
        for (support[0..i]) |previous| if (previous.enabled and std.mem.eql(u8, previous.name, item.name)) return error.ExportCollision;
    };
    for (methods, 0..) |method, i| {
        try identifier(method.api);
        for (support) |item| {
            if (item.enabled and std.mem.eql(u8, item.name, method.api)) return error.ExportCollision;
        }
        for (methods[0..i]) |previous| {
            if (std.mem.eql(u8, previous.api, method.api)) return error.ExportCollision;
        }
    }
}

/// Call bodies use this private namespace, never the caller's export name.
pub fn callName(buffer: []u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "call_{d}", .{index});
}

pub fn rust(a: std.mem.Allocator, implementation: []const u8, methods: []const calls.Named, support: []const Support) ![]u8 {
    try validate(methods, support);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var module_buffer: [64]u8 = undefined;
    var module: []const u8 = "__glowcap";
    var suffix: usize = 0;
    while (occupied(module, methods, support)) {
        suffix += 1;
        module = try std.fmt.bufPrint(&module_buffer, "__glowcap_{d}", .{suffix});
    }
    try out.appendSlice(a, "// Generated from checked interface descriptions.\n");
    const ordered = try a.dupe(Support, support);
    defer a.free(ordered);
    std.mem.sort(Support, ordered, {}, struct {
        fn lessThan(_: void, left: Support, right: Support) bool {
            return std.mem.lessThan(u8, left.implementation orelse left.name, right.implementation orelse right.name);
        }
    }.lessThan);
    var calls_emitted = false;
    for (ordered) |item| if (item.enabled) {
        if (!calls_emitted and std.mem.lessThan(u8, "call_0", item.implementation orelse item.name)) {
            try rustCalls(&out, a, module, methods);
            calls_emitted = true;
        }
        if (item.implementation) |source_name| {
            try out.print(a, "pub use {s}::{s} as {s};\n", .{ module, source_name, item.name });
        } else try out.print(a, "pub use {s}::{s};\n", .{ module, item.name });
    };
    if (!calls_emitted) try rustCalls(&out, a, module, methods);
    try out.print(a, "\nmod {s} {{\n", .{module});
    var lines = std.mem.splitScalar(u8, implementation, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) try out.print(a, "\t{s}\n", .{line}) else if (lines.peek() != null) try out.append(a, '\n');
    }
    try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

fn rustCalls(out: *std.ArrayList(u8), a: std.mem.Allocator, module: []const u8, methods: []const calls.Named) !void {
    for (methods, 0..) |method, i| {
        var buffer: [32]u8 = undefined;
        try out.print(a, "pub use {s}::{s} as {s};\n", .{ module, try callName(&buffer, i), method.api });
    }
}

pub fn typescript(out: *std.ArrayList(u8), a: std.mem.Allocator, methods: []const calls.Named, support: []const Support) !void {
    try validate(methods, support);
    for (support) |item| if (item.enabled) {
        try out.print(a, "export {{ {s} }};\n", .{item.name});
    };
    for (methods, 0..) |method, i| {
        var buffer: [32]u8 = undefined;
        try out.print(a, "export {{ {s} as {s} }};\n", .{ try callName(&buffer, i), method.api });
    }
}

fn occupied(name: []const u8, methods: []const calls.Named, support: []const Support) bool {
    for (methods) |method| if (std.mem.eql(u8, method.api, name)) return true;
    for (support) |item| if (item.enabled and std.mem.eql(u8, item.name, name)) return true;
    return false;
}

// Public function names share the ASCII identifier subset of both targets.
fn identifier(name: []const u8) error{InvalidIdentifier}!void {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return error.InvalidIdentifier;
    for (name, 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i != 0 and std.ascii.isDigit(c)))) return error.InvalidIdentifier;
    }
    var keywords = std.mem.tokenizeScalar(
        u8,
        "abstract arguments as async await become bool box break case catch char class const continue crate debugger default defer delete do double dyn else enum eval export extends extern false final finally float fn for function gen goto if impl implements import in instanceof int interface let long loop macro macro_rules match mod move mut namespace native new null override package priv private protected pub public ref return safe self Self short sizeof static struct super switch synchronized this throw throws trait transient true try type typeof union unsafe unsized use var virtual void volatile where while with yield",
        ' ',
    );
    while (keywords.next()) |keyword| if (std.mem.eql(u8, name, keyword)) return error.InvalidIdentifier;
}
