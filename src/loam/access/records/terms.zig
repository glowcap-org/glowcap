//! Bounded grant term fields. Validation here is structural, without graph I/O.
const std = @import("std");
const core = @import("loam_access_core");
const syntax = @import("syrup").RecordSyntax;
const fields = @import("fields.zig");

pub fn validate(value: core.Terms, owner: core.OwnerId) error{InvalidRecord}!void {
    switch (value.scope) {
        .object, .owned_subtree => |id| try validateId(id, owner),
        .objects => |ids| {
            if (ids.len > core.max_scope_objects) return error.InvalidRecord;
            for (ids, 0..) |id, i| {
                try validateId(id, owner);
                if (i != 0 and !core.ResourceId.lessThan(ids[i - 1], id)) return error.InvalidRecord;
            }
        },
    }
}

fn validateId(id: core.ResourceId, owner: core.OwnerId) error{InvalidRecord}!void {
    if (id.owner != owner or id.generation == 0) return error.InvalidRecord;
}

pub fn write(sink: anytype, value: core.Terms) !void {
    try syntax.beginList(sink);
    try syntax.beginList(sink);
    try syntax.writeSymbol(sink, @tagName(value.scope));
    switch (value.scope) {
        .object, .owned_subtree => |id| try fields.writeId(sink, id),
        .objects => |ids| {
            try syntax.writePositiveInt(sink, ids.len);
            for (ids) |id| try fields.writeId(sink, id);
        },
    }
    try syntax.endList(sink);
    try fields.writeWide(sink, @backingInt(value.policy.schema));
    try syntax.writePositiveInt(sink, value.policy.permissions);
    try syntax.beginList(sink);
    for (0..core.Policy.max_constraints) |i| {
        if (value.policy.bound(i)) |n| try syntax.writePositiveInt(sink, n) else try syntax.writeBool(sink, false);
    }
    try syntax.endList(sink);
    try syntax.endList(sink);
}

pub fn readOwned(allocator: std.mem.Allocator, bytes: []const u8, cursor: *usize, owner: core.OwnerId) !core.Terms {
    try syntax.readByte(bytes, cursor, '[');
    try syntax.readByte(bytes, cursor, '[');
    const tag = try syntax.readSymbol(bytes, cursor);
    const scope: core.Scope = if (std.mem.eql(u8, tag, "object"))
        .{ .object = try fields.readId(core.ResourceId, bytes, cursor) }
    else if (std.mem.eql(u8, tag, "owned_subtree"))
        .{ .owned_subtree = try fields.readId(core.ResourceId, bytes, cursor) }
    else if (std.mem.eql(u8, tag, "objects")) blk: {
        const count = try syntax.readPositiveInt(bytes, cursor);
        if (count > core.max_scope_objects) return error.InvalidRecord;
        const ids = try allocator.alloc(core.ResourceId, @intCast(count));
        errdefer allocator.free(ids);
        for (ids) |*id| id.* = try fields.readId(core.ResourceId, bytes, cursor);
        break :blk .{ .objects = ids };
    } else return error.InvalidRecord;
    errdefer if (scope == .objects) allocator.free(scope.objects);
    try syntax.readByte(bytes, cursor, ']');
    var policy: core.Policy.Value = .{
        .schema = @fromBackingInt(try fields.readWide(bytes, cursor)),
        .permissions = try syntax.readPositiveInt(bytes, cursor),
    };
    try syntax.readByte(bytes, cursor, '[');
    for (0..core.Policy.max_constraints) |i| {
        if (cursor.* < bytes.len and bytes[cursor.*] == 'f') {
            cursor.* += 1;
        } else policy.setBound(i, try syntax.readPositiveInt(bytes, cursor));
    }
    try syntax.readByte(bytes, cursor, ']');
    try syntax.readByte(bytes, cursor, ']');
    const value: core.Terms = .{ .scope = scope, .policy = policy };
    try validate(value, owner);
    return value;
}

pub fn free(allocator: std.mem.Allocator, value: core.Terms) void {
    if (value.scope == .objects) allocator.free(value.scope.objects);
}
