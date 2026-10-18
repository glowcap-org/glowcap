//! Shared scalar grammar for managed access records. No authority decisions.
const std = @import("std");
const core = @import("loam_access_core");
const records = @import("loam_records");
const syntax = @import("syrup").RecordSyntax;

pub fn writeWide(sink: anytype, value: u128) !void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, value, .big);
    try syntax.writeBytes(sink, &bytes);
}

pub fn readWide(bytes: []const u8, cursor: *usize) !u128 {
    // The syntax limit is an absolute record boundary, not a field length.
    // Public decoders already cap bytes before entering this grammar.
    const value = try syntax.readBytes(bytes, cursor);
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
    return std.meta.stringToEnum(core.GrantView.Status, try syntax.readSymbol(bytes, cursor)) orelse error.InvalidRecord;
}

/// The next edge, which must be strong and point into `store`.
pub fn readEdge(edges: *records.EdgeIterator, store: records.StoreId) error{InvalidRecord}!records.ObjectId {
    const edge = edges.next() orelse return error.InvalidRecord;
    if (edge.strength != .strong or edge.target.store != store) return error.InvalidRecord;
    return edge.target;
}

/// A durable object name inside a payload, beside the edge that retains it.
pub fn writeObject(sink: anytype, id: records.ObjectId) !void {
    try writeWide(sink, @backingInt(id.store));
    try syntax.writePositiveInt(sink, id.incarnation);
    try syntax.writePositiveInt(sink, id.sequence);
}

pub fn readObject(bytes: []const u8, cursor: *usize) !records.ObjectId {
    return .{
        .store = @fromBackingInt(try readWide(bytes, cursor)),
        .incarnation = try syntax.readPositiveInt(bytes, cursor),
        .sequence = try syntax.readPositiveInt(bytes, cursor),
    };
}
