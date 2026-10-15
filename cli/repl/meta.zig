//! The REPL-only meta commands, one owner: dispatch (`exec`), Tab completion,
//! the `help` footer, and the gloss column all read this table, so an entry
//! cannot exist in one surface and be missing from another.
const std = @import("std");

/// Dispatch identity. `quit` and `exit` are two spellings of one command.
pub const Meta = enum { help, quit, focus, guide, tour, question };

pub const Entry = struct {
    meta: Meta,
    name: []const u8,
    gloss: []const u8,
};

pub const entries = [_]Entry{
    .{ .meta = .help, .name = "help", .gloss = "Everyday CapTP verbs and REPL help." },
    .{ .meta = .quit, .name = "quit", .gloss = "Leave the CapTP lab." },
    .{ .meta = .quit, .name = "exit", .gloss = "Leave the CapTP lab." },
    .{ .meta = .focus, .name = "focus", .gloss = "Toggle the quiet focus view (the side panel collapses to counts)." },
    .{ .meta = .guide, .name = "guide", .gloss = "Enter or exit the optional CapTP walkthrough." },
    .{ .meta = .tour, .name = "tour", .gloss = "Point at a CapTP pane: exports, imports, or answers." },
    .{ .meta = .question, .name = "?", .gloss = "Help: workbench tips, or the guide coach while guided." },
};

pub fn resolve(token: []const u8) ?Meta {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, token)) return e.meta;
    }
    return null;
}

pub fn glossOf(token: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, token)) return e.gloss;
    }
    return null;
}

/// The `help` footer line, derived so it cannot drift from the table.
pub const footer = blk: {
    var s: []const u8 = "REPL-only:";
    for (entries, 0..) |e, i| {
        s = s ++ (if (i == 0) " " else ", ") ++ e.name;
    }
    break :blk s ++ " (help captp shows the CapTP noun map)\n";
};
