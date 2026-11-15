//! Shared C-ABI argument and reference constructors for the `test/c_abi`
//! suite. Every field of the blank argument is named, so the shared-by-layout
//! `GlowcapArgument` growing a field fails these tests at compile time instead
//! of zero-filling silently. The blank is a deliberate VOID argument: the
//! all-zeroes value would read as a valid integer argument, because
//! `GLOWCAP_ARG_INTEGER` is zero.

const std = @import("std");
const c = @import("c_abi");

/// The call returned `GLOWCAP_OK`.
pub fn expectOk(rc: i32) !void {
    try std.testing.expectEqual(c.GLOWCAP_OK, rc);
}

fn zeroRef() c.GlowcapReference {
    return .{ .id = 0 };
}

pub fn argBase() c.GlowcapArgument {
    return .{
        .kind = c.GLOWCAP_ARG_VOID,
        .boolean = 0,
        .integer = 0,
        .float64 = 0,
        .bytes = null,
        .bytes_len = 0,
        .reference = zeroRef(),
        .items = null,
        .items_len = 0,
    };
}

pub fn argInt(value: i64) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_INTEGER;
    arg.integer = value;
    return arg;
}

pub fn argStr(text: []const u8) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_STRING;
    arg.bytes = text.ptr;
    arg.bytes_len = text.len;
    return arg;
}

pub fn argBytes(bytes: []const u8) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_BYTES;
    arg.bytes = bytes.ptr;
    arg.bytes_len = bytes.len;
    return arg;
}

pub fn argRef(reference: c.GlowcapReference) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_REFERENCE;
    arg.reference = reference;
    return arg;
}

/// Write `arg` as one canonical line, so two values compare field by field
/// through their text: leaves carry their bytes, containers their children in
/// order, and an integer run reads as the list of integers it holds.
pub fn render(w: *std.Io.Writer, arg: c.GlowcapArgument) std.Io.Writer.Error!void {
    const leaf: []const u8 = if (arg.bytes) |bytes| bytes[0..arg.bytes_len] else &.{};
    const items: []const c.GlowcapArgument = if (arg.items) |ptr| ptr[0..arg.items_len] else &.{};
    switch (arg.kind) {
        c.GLOWCAP_ARG_INTEGER => try w.print("i{d}", .{arg.integer}),
        c.GLOWCAP_ARG_FLOAT64 => try w.print("f{d}", .{arg.float64}),
        c.GLOWCAP_ARG_BOOLEAN => try w.print("b{d}", .{arg.boolean}),
        c.GLOWCAP_ARG_BYTES => try w.print("x\"{s}\"", .{leaf}),
        c.GLOWCAP_ARG_STRING => try w.print("s\"{s}\"", .{leaf}),
        c.GLOWCAP_ARG_SYMBOL => try w.print("y\"{s}\"", .{leaf}),
        c.GLOWCAP_ARG_KEYWORD => try w.print("k\"{s}\"", .{leaf}),
        c.GLOWCAP_ARG_ERROR => try w.print("e\"{s}\"", .{leaf}),
        c.GLOWCAP_ARG_BIG_INTEGER => try w.print("n{s}{s}", .{ if (arg.boolean != 0) "-" else "+", leaf }),
        c.GLOWCAP_ARG_VOID => try w.writeAll("v"),
        c.GLOWCAP_ARG_REFERENCE => try w.writeAll("r"),
        c.GLOWCAP_ARG_INTEGERS => {
            try w.writeAll("[");
            const words = std.mem.bytesAsSlice(i64, leaf);
            for (words, 0..) |word, i| try w.print("{s}i{d}", .{ if (i == 0) "" else " ", word });
            try w.writeAll("]");
        },
        c.GLOWCAP_ARG_TAGGED => {
            try w.print("t\"{s}\"", .{leaf});
            try renderItems(w, "(", ")", items);
        },
        c.GLOWCAP_ARG_LIST => try renderItems(w, "[", "]", items),
        c.GLOWCAP_ARG_SET => try renderItems(w, "#{", "}", items),
        c.GLOWCAP_ARG_STRUCT => try renderItems(w, "{", "}", items),
        else => try w.print("?{d}", .{arg.kind}),
    }
}

fn renderItems(w: *std.Io.Writer, open: []const u8, close: []const u8, items: []const c.GlowcapArgument) std.Io.Writer.Error!void {
    try w.writeAll(open);
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(" ");
        try render(w, item);
    }
    try w.writeAll(close);
}
