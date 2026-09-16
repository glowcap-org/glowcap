//! Durable model event data. Commit gates publication; hosting scopes delivery.
const std = @import("std");
const core = @import("loam_access_core");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;
const fields = @import("fields.zig");

pub const ChangeRecord = struct {
    change: core.GrantPlan.Change,
    pub const format_version: u64 = 1;
    pub const max_encoded_bytes: usize = 256;
    pub const Error = error{ MalformedRecord, UnsupportedVersion, InvalidRecord, RecordTooLarge };
    const label = "access:change";

    pub fn encodeAlloc(self: ChangeRecord, allocator: std.mem.Allocator) (Error || syrup.shared.WalkError)![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    /// Owned scalar result; no allocation or input borrow survives decoding.
    pub fn decode(bytes: []const u8) Error!ChangeRecord {
        if (bytes.len > max_encoded_bytes) return error.RecordTooLarge;
        return decodeRecord(bytes) catch |err| switch (err) {
            error.UnsupportedVersion => error.UnsupportedVersion,
            error.InvalidRecord => error.InvalidRecord,
            else => error.MalformedRecord,
        };
    }

    fn validate(self: ChangeRecord) Error!void {
        const c = self.change;
        if (c.grant.generation == 0) return error.InvalidRecord;
        switch (c.kind) {
            .issued => |parent| if (parent) |id| {
                if (id.owner != c.grant.owner or id.generation == 0 or id.eql(c.grant)) return error.InvalidRecord;
            },
            .status_changed => |s| if (s.before == s.after or s.before == .revoked) return error.InvalidRecord,
            .policy_changed => {},
        }
    }

    fn write(sink: anytype, self: ChangeRecord) !void {
        const c = self.change;
        try syntax.beginRecord(sink);
        try syntax.writeSymbol(sink, label);
        try syntax.writePositiveInt(sink, format_version);
        try syntax.writePositiveInt(sink, @backingInt(c.version.resources));
        try syntax.writePositiveInt(sink, @backingInt(c.version.grants));
        try fields.writeId(sink, c.grant);
        try syntax.writeSymbol(sink, @tagName(c.kind));
        switch (c.kind) {
            .issued => |parent| try fields.writeParent(sink, parent),
            .policy_changed => {},
            .status_changed => |s| {
                try syntax.writeSymbol(sink, @tagName(s.before));
                try syntax.writeSymbol(sink, @tagName(s.after));
            },
        }
        try syntax.endRecord(sink);
    }

    fn decodeRecord(bytes: []const u8) !ChangeRecord {
        var cursor: usize = 0;
        try syntax.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try syntax.readSymbol(bytes, &cursor), label)) return error.MalformedRecord;
        if (try syntax.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const resources: core.Revision = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const grants: core.Revision = @fromBackingInt(try syntax.readPositiveInt(bytes, &cursor));
        const grant = try fields.readId(core.GrantId, bytes, &cursor);
        const tag = try syntax.readSymbol(bytes, &cursor);
        const kind: core.GrantPlan.Change.Kind = if (std.mem.eql(u8, tag, "issued"))
            .{ .issued = try fields.readParent(core.GrantId, bytes, &cursor) }
        else if (std.mem.eql(u8, tag, "policy_changed"))
            .policy_changed
        else if (std.mem.eql(u8, tag, "status_changed"))
            .{ .status_changed = .{ .before = try fields.readStatus(bytes, &cursor), .after = try fields.readStatus(bytes, &cursor) } }
        else
            return error.InvalidRecord;
        try syntax.readByte(bytes, &cursor, '>');
        try syntax.expectEnd(bytes, cursor);
        const value: ChangeRecord = .{ .change = .{ .version = .{ .resources = resources, .grants = grants }, .grant = grant, .kind = kind } };
        try value.validate();
        return value;
    }
};
