//! Fallible, whole-document JSON emission for rooms-peer command results.

const std = @import("std");
const common = @import("../common.zig");
const argv = @import("../../../argv.zig");

const Io = common.Io;
const Allocator = common.Allocator;

pub const Document = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    filled: [4]bool = @splat(false),
    closer: [4]u8 = @splat('}'),
    depth: usize = 0,

    pub fn init(gpa: Allocator) Document {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Document) void {
        self.buf.deinit(self.gpa);
    }

    pub fn beginObject(self: *Document) !void {
        if (self.depth > 0) try self.separate();
        try self.push('{', '}');
    }

    pub fn arrayMember(self: *Document, key: []const u8) !void {
        try self.member(key);
        try self.push('[', ']');
    }

    pub fn string(self: *Document, key: []const u8, value: []const u8) !void {
        try self.member(key);
        try argv.writeJsonString(&self.buf, self.gpa, value);
    }

    pub fn boolean(self: *Document, key: []const u8, value: bool) !void {
        try self.member(key);
        try self.buf.appendSlice(self.gpa, if (value) "true" else "false");
    }

    pub fn number(self: *Document, key: []const u8, value: anytype) !void {
        try self.member(key);
        try self.buf.print(self.gpa, "{d}", .{value});
    }

    pub fn rawValue(self: *Document, key: []const u8, value: []const u8) !void {
        try self.member(key);
        try self.buf.appendSlice(self.gpa, value);
    }

    pub fn end(self: *Document) !void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        try self.buf.append(self.gpa, self.closer[self.depth]);
    }

    pub fn line(self: *Document) ![]const u8 {
        std.debug.assert(self.depth == 0);
        try self.buf.append(self.gpa, '\n');
        return self.buf.items;
    }

    fn push(self: *Document, open: u8, close: u8) !void {
        std.debug.assert(self.depth < self.filled.len);
        try self.buf.append(self.gpa, open);
        self.filled[self.depth] = false;
        self.closer[self.depth] = close;
        self.depth += 1;
    }

    fn separate(self: *Document) !void {
        if (self.filled[self.depth - 1]) try self.buf.append(self.gpa, ',');
        self.filled[self.depth - 1] = true;
    }

    fn member(self: *Document, key: []const u8) !void {
        try self.separate();
        try argv.writeJsonString(&self.buf, self.gpa, key);
        try self.buf.append(self.gpa, ':');
    }
};

pub fn emitInternalError(io: Io) error{PeerFailed} {
    // best-effort: the returned PeerFailed still carries the failure; only
    // the JSON line is lost if stdout refuses.
    common.emitStdout(io, "{\"ok\":false,\"error\":\"internal\"}\n") catch {};
    return error.PeerFailed;
}
