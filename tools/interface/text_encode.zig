//! Canonical encoding bounds output and rejects duplicate dictionary keys.
const std = @import("std");
const description = @import("description.zig");
const Node = description.Node;
const Error = @import("text_parser.zig").Error;
pub const Encoder = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    remaining: usize = description.max_nodes,
    failed_source: []const u8 = "",
    fn append(self: *Encoder, value: []const u8) Error!void {
        if (value.len > description.max_input_bytes - self.bytes.items.len) return error.ResourceLimit;
        try self.bytes.appendSlice(self.a, value);
    }
    fn atom(self: *Encoder, value: []const u8, marker: u8) Error!void {
        var buffer: [32]u8 = undefined;
        try self.append((std.mem.print(&buffer, "{d}{c}", .{ value.len, marker }) catch unreachable));
        try self.append(value);
    }
    fn key(a: std.mem.Allocator, value: Node) Error![]const u8 {
        return if (value.kind == .string) a.print("{d}\"{s}", .{ value.bytes.len, value.bytes }) else if (value.kind == .boolean and !value.boolean) "f" else error.InvalidText;
    }
    pub fn node(self: *Encoder, value: Node, depth: usize) Error!void {
        if (depth > description.max_depth or self.remaining == 0) return error.ResourceLimit;
        self.remaining -= 1;
        switch (value.kind) {
            .string, .symbol => try self.atom(value.bytes, if (value.kind == .string) '"' else '\''),
            .integer => {
                var buffer: [32]u8 = undefined;
                try self.append((std.mem.print(&buffer, "{d}{c}", .{ @abs(value.integer), @as(u8, if (value.integer < 0) '-' else '+') }) catch unreachable));
            },
            .boolean => try self.append(if (value.boolean) "t" else "f"),
            .list, .record => {
                try self.append(if (value.kind == .list) "[" else "<");
                if (value.kind == .record) {
                    if (depth == description.max_depth or self.remaining == 0) return error.ResourceLimit;
                    self.remaining -= 1;
                    try self.atom(value.bytes, '\'');
                }
                for (value.children) |child| try self.node(child, depth + 1);
                try self.append(if (value.kind == .list) "]" else ">");
            },
            .dictionary => {
                if (value.children.len % 2 != 0) return error.InvalidText;
                const Entry = struct { key: []const u8, at: usize };
                const entries = try self.a.alloc(Entry, value.children.len / 2);
                for (entries, 0..) |*entry, i| entry.* = .{ .key = try key(self.a, value.children[i * 2]), .at = i * 2 };
                std.mem.sort(Entry, entries, {}, struct {
                    fn less(_: void, left: Entry, right: Entry) bool {
                        return switch (std.mem.order(u8, left.key, right.key)) {
                            .lt => true,
                            .gt => false,
                            .eq => left.at < right.at,
                        };
                    }
                }.less);
                try self.append("{");
                for (entries, 0..) |entry, i| {
                    if (i > 0 and std.mem.eql(u8, entries[i - 1].key, entry.key)) {
                        self.failed_source = value.children[entry.at].source;
                        return error.InvalidText;
                    }
                    try self.node(value.children[entry.at], depth + 1);
                    try self.node(value.children[entry.at + 1], depth + 1);
                }
                try self.append("}");
            },
        }
    }
};
