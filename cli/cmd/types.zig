//! Command-tree data types (shared by parse, help, completion, tree).
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;

pub const FlagKind = enum { bool_flag, string_flag };

pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
    help: []const u8,
    kind: FlagKind = .bool_flag,
    /// Accepted at any depth when defined on an ancestor (typically root).
    persistent: bool = false,
    /// Omit from MCP tool schemas / fillParsed (argv-only flag, e.g. dial --repl).
    mcp_hide: bool = false,
};

pub const Positional = struct {
    name: []const u8,
    help: []const u8,
    required: bool = true,
    variadic: bool = false,
};

/// What one flag was given as. A flag's declaration fixes its kind, so the
/// union is the whole story: a name cannot be present as both a switch and a
/// value, and a reader of a stored flag always knows which it holds.
pub const FlagValue = union(FlagKind) {
    bool_flag: bool,
    string_flag: []const u8,
};

pub const Parsed = struct {
    gpa: std.mem.Allocator,
    flags: std.StringHashMapUnmanaged(FlagValue) = .empty,
    positionals: []const []const u8 = &.{},
    positionals_owned: ?[][]const u8 = null,

    pub fn deinit(self: *Parsed) void {
        self.flags.deinit(self.gpa);
        if (self.positionals_owned) |p| self.gpa.free(p);
        self.* = undefined;
    }

    pub fn setBool(self: *Parsed, long: []const u8, on: bool) !void {
        try self.flags.put(self.gpa, long, .{ .bool_flag = on });
    }

    pub fn setString(self: *Parsed, long: []const u8, value: []const u8) !void {
        try self.flags.put(self.gpa, long, .{ .string_flag = value });
    }

    pub fn flagBool(self: *const Parsed, long: []const u8) bool {
        const v = self.flags.get(long) orelse return false;
        return switch (v) {
            .bool_flag => |on| on,
            .string_flag => false,
        };
    }

    pub fn flagString(self: *const Parsed, long: []const u8) ?[]const u8 {
        const v = self.flags.get(long) orelse return null;
        return switch (v) {
            .string_flag => |s| s,
            .bool_flag => null,
        };
    }
};

pub const Command = struct {
    name: []const u8,
    short_help: []const u8,
    flags: []const Flag = &.{},
    positionals: []const Positional = &.{},
    children: []const Command = &.{},
    aliases: []const []const u8 = &.{},
    /// Omit from argv help "Commands:" and shell completion (runtime leaf still
    /// exists — e.g. supervised-only `rooms-peer peer`).
    hidden_from_help: bool = false,
    /// Leaf runner. Parents leave this null.
    run: ?*const fn (*Ctx, *Parsed) anyerror!u8 = null,

    pub fn isLeaf(self: *const Command) bool {
        return self.children.len == 0;
    }

    pub fn findChild(self: *const Command, name: []const u8) ?*const Command {
        for (self.children) |*c| {
            if (std.mem.eql(u8, c.name, name)) return c;
            for (c.aliases) |a| {
                if (std.mem.eql(u8, a, name)) return c;
            }
        }
        return null;
    }
};

/// Gather the persistent flags visible at `path`'s node: every flag an
/// ancestor (typically root) declared persistent is accepted at any depth, so
/// parsing and help both need the same set. Fills `buf` and writes the count
/// to `n`, stopping at capacity rather than growing.
pub fn collectPersistent(path: []const *const Command, buf: *[48]Flag, n: *usize) void {
    n.* = 0;
    for (path) |cmd| {
        for (cmd.flags) |f| {
            if (!f.persistent) continue;
            if (n.* >= buf.len) return;
            buf[n.*] = f;
            n.* += 1;
        }
    }
}
