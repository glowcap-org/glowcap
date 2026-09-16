//! Shared scalar grammar for managed access records; no authority decisions.
const std = @import("std");
const core = @import("loam_access_core");
const syntax = @import("syrup").RecordSyntax;

pub fn writeWide(sink: anytype, value: u128) !void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, value, .big);
    try syntax.writeBytes(sink, &bytes);
}

pub fn readWide(bytes: []const u8, cursor: *usize) !u128 {
    // The syntax limit is an absolute record boundary, not a field length.
    // Public decoders already cap bytes before entering this grammar.
    const value = try syntax.readBytesLimited(bytes, cursor, bytes.len);
    if (value.len != 16) return error.InvalidRecord;
    return std.mem.readInt(u128, value[0..16], .big);
}

pub fn writeId(sink: anytype, id: anytype) !void {
    try writeWide(sink, @backingInt(id.owner));
    try syntax.writePositiveInt(sink, id.slot);
    try syntax.writePositiveInt(sink, id.generation);
}

pub fn readId(comptime Id: type, bytes: []const u8, cursor: *usize) !Id {
    const owner: core.OwnerId = @fromBackingInt(try readWide(bytes, cursor));
    const slot = std.math.cast(u32, try syntax.readPositiveInt(bytes, cursor)) orelse return error.InvalidRecord;
    const generation = try syntax.readPositiveInt(bytes, cursor);
    if (generation == 0) return error.InvalidRecord;
    return .{ .owner = owner, .slot = slot, .generation = generation };
}

pub fn writeParent(sink: anytype, parent: anytype) !void {
    if (parent) |id| {
        try syntax.beginList(sink);
        try writeId(sink, id);
        try syntax.endList(sink);
    } else try syntax.writeBool(sink, false);
}

pub fn readParent(comptime Id: type, bytes: []const u8, cursor: *usize) !?Id {
    if (cursor.* < bytes.len and bytes[cursor.*] == '[') {
        cursor.* += 1;
        const id = try readId(Id, bytes, cursor);
        try syntax.readByte(bytes, cursor, ']');
        return id;
    }
    if (try syntax.readBool(bytes, cursor)) return error.MalformedRecord;
    return null;
}

pub fn readStatus(bytes: []const u8, cursor: *usize) !core.GrantView.Status {
    const symbol = try syntax.readSymbol(bytes, cursor);
    inline for (std.meta.tags(core.GrantView.Status)) |tag| {
        if (std.mem.eql(u8, symbol, @tagName(tag))) return tag;
    }
    return error.InvalidRecord;
}
