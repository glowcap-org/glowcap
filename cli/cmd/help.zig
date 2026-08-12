//! Scoped help rendering for one command-tree node.
const std = @import("std");
const types = @import("types.zig");
const argv = @import("../argv.zig");
const exit_codes = @import("../exit_codes.zig");
const ocapn = @import("../ocapn/mod.zig");

const Command = types.Command;
const Flag = types.Flag;

const Stream = enum { stdout, stderr };

/// Write help for the node at the end of `path` (path[0] is root).
/// `-h` / `--help` use stdout; parse errors use stderr (Cobra-shaped).
pub fn writeNodeHelp(io: std.Io, path: []const *const Command) !void {
    try writeNodeHelpTo(.{ .stream = .{ .io = io, .stream = .stdout } }, path);
}

pub fn writeNodeHelpErr(io: std.Io, path: []const *const Command) !void {
    try writeNodeHelpTo(.{ .stream = .{ .io = io, .stream = .stderr } }, path);
}

/// Render help into caller-owned memory: the assertion-friendly arm of the
/// same renderer, used by tests that check help text in isolation.
pub fn writeNodeHelpAlloc(gpa: std.mem.Allocator, path: []const *const Command) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try writeNodeHelpTo(.{ .list = .{ .gpa = gpa, .out = &list } }, path);
    return try list.toOwnedSlice(gpa);
}

const Dest = union(enum) {
    stream: struct { io: std.Io, stream: Stream },
    list: struct { gpa: std.mem.Allocator, out: *std.ArrayList(u8) },

    fn writeAll(self: Dest, bytes: []const u8) !void {
        switch (self) {
            .list => |sink| try sink.out.appendSlice(sink.gpa, bytes),
            .stream => |s| switch (s.stream) {
                .stdout => try argv.writeStdout(s.io, bytes),
                .stderr => try argv.writeStderr(s.io, bytes),
            },
        }
    }

    fn writeFmt(self: Dest, comptime fmt: []const u8, args: anytype) !void {
        var buf: [2048]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeAll(msg);
    }
};

fn writeNodeHelpTo(dest: Dest, path: []const *const Command) !void {
    std.debug.assert(path.len > 0);
    const node = path[path.len - 1];

    try dest.writeAll("Usage:\n  ");
    for (path, 0..) |c, i| {
        if (i > 0) try dest.writeAll(" ");
        try dest.writeAll(c.name);
    }
    // Flags before the subcommand placeholder (POSIX/GNU-shaped synopsis).
    if (node.flags.len > 0 or path.len > 1) {
        try dest.writeAll(" [flags]");
    }
    if (node.children.len > 0) {
        try dest.writeAll(" <command>");
    }
    for (node.positionals) |p| {
        try dest.writeAll(" ");
        if (p.required) {
            if (p.variadic) {
                try dest.writeFmt("<{s}…>", .{p.name});
            } else {
                try dest.writeFmt("<{s}>", .{p.name});
            }
        } else if (p.variadic) {
            try dest.writeFmt("[{s}…]", .{p.name});
        } else {
            try dest.writeFmt("[{s}]", .{p.name});
        }
    }
    try dest.writeAll("\n\n");
    try dest.writeAll(node.short_help);
    try dest.writeAll("\n");

    var persist_buf: [48]Flag = undefined;
    var persist_n: usize = 0;
    types.collectPersistent(path, &persist_buf, &persist_n);

    if (node.flags.len > 0 or persist_n > 0) {
        try dest.writeAll("\nFlags:\n");
        for (node.flags) |f| {
            try writeFlagLine(dest, f);
        }
        for (persist_buf[0..persist_n]) |f| {
            var dup = false;
            for (node.flags) |lf| {
                if (std.mem.eql(u8, lf.long, f.long)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try writeFlagLine(dest, f);
        }
    }

    if (node.positionals.len > 0) {
        try dest.writeAll("\nArguments:\n");
        for (node.positionals) |p| {
            try dest.writeFmt("  {s:<16} {s}\n", .{ p.name, p.help });
        }
    }

    if (node.children.len > 0) {
        var any_visible = false;
        for (node.children) |c| {
            if (!c.hidden_from_help) {
                any_visible = true;
                break;
            }
        }
        if (any_visible) {
            try dest.writeAll("\nCommands:\n");
            for (node.children) |c| {
                if (c.hidden_from_help) continue;
                try dest.writeFmt("  {s:<16} {s}\n", .{ c.name, c.short_help });
            }
        }
    }

    // Root-only human footer (keep leaves short). Exit codes and CapTP budgets
    // are formatted from the owning constants so help cannot drift.
    if (path.len == 1 and std.mem.eql(u8, node.name, "pancake")) {
        try dest.writeAll(
            \\
            \\Examples:
            \\  pancake init
            \\  pancake ocapn dial ocapn://…
            \\  pancake ocapn listen --once
            \\
            \\Exit status:
            \\
        );
        try dest.writeFmt("  {d}  ok\n", .{exit_codes.ok});
        try dest.writeFmt("  {d}  internal error\n", .{exit_codes.internal});
        try dest.writeFmt("  {d}  usage\n", .{exit_codes.usage});
        try dest.writeFmt("  {d}  identity\n", .{exit_codes.identity});
        try dest.writeFmt("  {d}  dial\n", .{exit_codes.dial});
        try dest.writeFmt("  {d}  protocol abort\n", .{exit_codes.protocol_abort});
        try dest.writeFmt("  {d}  timeout\n", .{exit_codes.timeout});
        try dest.writeFmt("  {d}  busy (identity lock)\n", .{exit_codes.busy});
        try dest.writeAll(
            \\
            \\CapTP waits (product defaults):
            \\
        );
        try dest.writeFmt("  handshake  {d} ms\n", .{ocapn.default_handshake_timeout_ms});
        try dest.writeFmt("  settle     {d} ms\n", .{ocapn.default_settle_timeout_ms});
        try dest.writeAll(
            \\
            \\Environment:
            \\  PANCAKE_STATE       State dir (lock + default identity)
            \\  PANCAKE_IDENTITY    Identity seed path (overrides state dir)
            \\  PANCAKE_RENDEZVOUS  Relay URL (ws://host:port/relay) for keyed-relay and noise-relay dials
            \\  XDG_STATE_HOME      Default state parent (…/pancake)
            \\  HOME                Fallback for XDG defaults
            \\
        );
    }

    try dest.writeAll("\n");
}

fn writeFlagLine(dest: Dest, f: Flag) !void {
    if (f.short) |s| {
        try dest.writeFmt("  -{c}, --{s:<12} {s}\n", .{ s, f.long, f.help });
    } else {
        try dest.writeFmt("      --{s:<12} {s}\n", .{ f.long, f.help });
    }
}
