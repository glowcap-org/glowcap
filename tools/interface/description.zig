//! Bounded build-input reader. Syrup owns leaf syntax, this module owns the
//! description tree and canonical dictionaries. No CapTP state is interpreted.
const std = @import("std");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;
pub const Error = syrup.Error || std.mem.Allocator.Error || error{ InvalidDescription, ResourceLimit, UnsupportedProjection };

pub const Node = struct {
    kind: enum { string, symbol, integer, boolean, list, dictionary, record },
    bytes: []const u8 = "",
    integer: i64 = 0,
    boolean: bool = false,
    children: []const Node = &.{},
    source: []const u8 = "",

    pub fn fields(self: Node, label: []const u8, count: usize) Error![]const Node {
        if (self.kind != .record or !std.mem.eql(u8, self.bytes, label) or self.children.len != count) return error.InvalidDescription;
        return self.children;
    }

    pub fn get(self: Node, name: []const u8) Error!Node {
        if (self.kind != .dictionary) return error.InvalidDescription;
        var i: usize = 0;
        while (i < self.children.len) : (i += 2) {
            const key = self.children[i];
            if (key.kind == .string and std.mem.eql(u8, key.bytes, name)) return self.children[i + 1];
        }
        return error.InvalidDescription;
    }

    pub fn string(self: Node) Error![]const u8 {
        if (self.kind != .string) return error.InvalidDescription;
        return self.bytes;
    }

    pub fn number(self: Node) Error!i64 {
        if (self.kind != .integer) return error.InvalidDescription;
        return self.integer;
    }

    pub fn is(self: Node, symbol: []const u8) bool {
        return self.kind == .symbol and std.mem.eql(u8, self.bytes, symbol);
    }
};

pub fn read(arena: std.mem.Allocator, bytes: []const u8) Error!Node {
    if (bytes.len > 1 << 20) return error.ResourceLimit;
    var reader: Reader = .{ .arena = arena, .bytes = bytes };
    const result = reader.node(0) catch |err| switch (err) {
        error.OutOfMemory, error.ResourceLimit => return err,
        else => return error.InvalidDescription,
    };
    if (reader.at != bytes.len) return error.InvalidDescription;
    return result;
}

const Reader = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    at: usize = 0,
    remaining: usize = 65536,

    fn node(self: *Reader, depth: usize) Error!Node {
        if (depth > 64 or self.remaining == 0) return error.ResourceLimit;
        self.remaining -= 1;
        if (self.at == self.bytes.len) return error.InvalidDescription;
        const start = self.at;
        var result: Node = undefined;
        switch (self.bytes[self.at]) {
            't', 'f' => {
                result = .{ .kind = .boolean, .boolean = self.bytes[self.at] == 't' };
                self.at += 1;
            },
            '0'...'9' => {
                var end = self.at;
                while (end < self.bytes.len and std.ascii.isDigit(self.bytes[end])) : (end += 1) {}
                if (end == self.bytes.len) return error.InvalidDescription;
                if (end - self.at > 1 and self.bytes[self.at] == '0') return error.InvalidDescription;
                result = switch (self.bytes[end]) {
                    '"' => .{ .kind = .string, .bytes = try syntax.readString(self.bytes, &self.at) },
                    '\'' => .{ .kind = .symbol, .bytes = try syntax.readSymbol(self.bytes, &self.at) },
                    '+', '-' => .{ .kind = .integer, .integer = try syntax.readInteger(self.bytes, &self.at) },
                    else => return error.InvalidDescription,
                };
                if (result.kind == .integer and result.integer == 0 and self.bytes[end] == '-') return error.InvalidDescription;
                if ((result.kind == .string or result.kind == .symbol) and !std.unicode.utf8ValidateSlice(result.bytes)) return error.InvalidDescription;
            },
            '[', '{', '<' => |open| {
                self.at += 1;
                const close: u8 = switch (open) {
                    '[' => ']',
                    '{' => '}',
                    else => '>',
                };
                var label: []const u8 = "";
                if (open == '<') {
                    const name = try self.node(depth + 1);
                    if (name.kind != .symbol) return error.InvalidDescription;
                    label = name.bytes;
                }
                var children: std.ArrayList(Node) = .empty;
                while (true) {
                    if (self.at == self.bytes.len) return error.InvalidDescription;
                    if (self.bytes[self.at] == close) break;
                    try children.append(self.arena, try self.node(depth + 1));
                }
                self.at += 1;
                if (open == '{') {
                    if (children.items.len % 2 != 0) return error.InvalidDescription;
                    var i: usize = 2;
                    while (i < children.items.len) : (i += 2) {
                        if (std.mem.order(u8, children.items[i - 2].source, children.items[i].source) != .lt) return error.InvalidDescription;
                    }
                }
                result = .{ .kind = switch (open) {
                    '[' => .list,
                    '{' => .dictionary,
                    else => .record,
                }, .bytes = label, .children = try children.toOwnedSlice(self.arena) };
            },
            else => return error.InvalidDescription,
        }
        result.source = self.bytes[start..self.at];
        return result;
    }
};

test "description input rejects truncation duplicates trailing and noncanonical integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "[", "01+", "0-", "1+f", "{1\"a1+1\"a2+}", "{1\"b1+1\"a2+}" }) |bad| {
        try std.testing.expectError(error.InvalidDescription, read(arena.allocator(), bad));
    }
}
