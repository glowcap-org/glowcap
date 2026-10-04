//! Persistent exact-name lookup. Index entries survive target collection so
//! recreating a record cannot reassign an old discovery name.
const std = @import("std");
const records = @import("loam_records");
const tx = @import("transaction.zig");

pub const Name = struct {
    schema: u64,
    bytes: [16]u8,

    pub fn key(self: Name) [25]u8 {
        var result: [25]u8 = undefined;
        result[0] = 'n';
        std.mem.writeInt(u64, result[1..9], self.schema, .big);
        @memcpy(result[9..25], &self.bytes);
        return result;
    }
};
pub const Lookup = struct {
    ticket: tx.Ticket,
    name: Name,

    pub fn read(request: Lookup, kv: anytype) !Result {
        const meta = try tx.Metadata.decode((try kv.get(tx.metadata_key)) orelse return error.Corrupt);
        if (meta.store != request.ticket.store or meta.incarnation != request.ticket.incarnation or meta.revision != request.ticket.revision) return error.StaleCompletion;
        const bytes = (try kv.get(&request.name.key())) orelse return .missing;
        const id = try records.ObjectId.fromKey(bytes);
        if (id.store != meta.store) return error.Corrupt;
        return .{ .found = id };
    }
};
pub const Result = union(enum) { found: records.ObjectId, missing, failed: anyerror };

pub fn of(view: records.View, schemas: []const records.Schema) !?Name {
    for (schemas) |schema| {
        if (schema.id != view.schema or schema.version != view.schema_version) continue;
        const offset = schema.name_offset orelse return null;
        if (offset > view.payload.len or view.payload.len - offset < 16) return error.InvalidRecord;
        return .{ .schema = schema.id, .bytes = view.payload[offset..][0..16].* };
    }
    return error.UnsupportedSchema;
}

/// Called inside the backend's atomic batch. The key is immutable even when
/// the target becomes a tombstone; duplicate names refuse the whole batch.
pub fn install(kv: anytype, view: records.View, schemas: []const records.Schema) !void {
    const name = (try of(view, schemas)) orelse return;
    const key = name.key();
    const id = view.id.key();
    if (try kv.get(&key)) |existing| {
        if (!std.mem.eql(u8, existing, &id)) return error.NameCollision;
        return;
    }
    try kv.put(&key, &id);
}
