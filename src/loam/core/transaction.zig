//! Shared batch validation and exact commit metadata for storage adapters.
//! Adapters invoke this code inside their atomic transaction on the embedding's
//! executor. This module owns no I/O, worker, or backend policy.
const std = @import("std");
const records = @import("loam_records");
const collection = @import("collection.zig");
pub const ObjectId = records.ObjectId;
pub const StoreId = records.StoreId;
pub const metadata_key = "m";
pub const OpenMode = enum(u32) { open = 0, create = 1, bootstrap = 2 };
/// How an engine opens a store and the identity it expects there.
pub const Opening = struct { id: StoreId, mode: OpenMode };

pub const Metadata = struct {
    store: StoreId,
    incarnation: u64 = 0,
    revision: u64 = 0,
    objects: u64 = 0,
    record_bytes: u64 = 0,
    roots: u64 = 0,
    last_sequence: u64 = 0,
    collection: collection.Progress = .{},

    const magic = "LOAM\x00\x00\x00\x03";
    const scalars = [_][]const u8{ "incarnation", "revision", "objects", "record_bytes", "roots", "last_sequence" };
    const store_offset = magic.len;
    const scalars_offset = store_offset + @sizeOf(u128);
    const collection_offset = scalars_offset + scalars.len * @sizeOf(u64);
    const checksum_offset = collection_offset + collection.Progress.encoded_size;
    pub const encoded_size = checksum_offset + @sizeOf(u32);

    /// Select metadata inside the adapter's exclusively held atomic opening.
    /// Bootstrap admits known absence, preserving every existing identity and
    /// record. It never replaces corrupt, mismatched or unreadable metadata.
    pub fn select(identity: StoreId, mode: OpenMode, previous: ?[]const u8) !Metadata {
        const metadata = if (previous) |bytes| blk: {
            if (mode == .create) return error.AlreadyExists;
            break :blk try decode(bytes);
        } else blk: {
            if (mode == .open) return error.MissingStore;
            break :blk Metadata{ .store = identity };
        };
        if (metadata.store != identity) return error.StoreMismatch;
        return metadata;
    }

    pub fn encode(self: Metadata) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = undefined;
        bytes[0..magic.len].* = magic.*;
        std.mem.writeInt(u128, bytes[store_offset..][0..@sizeOf(u128)], @backingInt(self.store), .big);
        inline for (scalars, 0..) |name, i| std.mem.writeInt(u64, bytes[scalars_offset + i * @sizeOf(u64) ..][0..@sizeOf(u64)], @field(self, name), .big);
        bytes[collection_offset..checksum_offset].* = self.collection.encode();
        std.mem.writeInt(u32, bytes[checksum_offset..][0..@sizeOf(u32)], std.hash.Crc32.hash(bytes[0..checksum_offset]), .big);
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Metadata {
        if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Corrupt;
        if (std.hash.Crc32.hash(bytes[0..checksum_offset]) != std.mem.readInt(u32, bytes[checksum_offset..][0..@sizeOf(u32)], .big)) return error.Corrupt;
        var result: Metadata = .{
            .store = @fromBackingInt(std.mem.readInt(u128, bytes[store_offset..][0..@sizeOf(u128)], .big)),
            .collection = try collection.Progress.decode(bytes[collection_offset..][0..collection.Progress.encoded_size]),
        };
        inline for (scalars, 0..) |name, i| @field(result, name) = std.mem.readInt(u64, bytes[scalars_offset + i * @sizeOf(u64) ..][0..@sizeOf(u64)], .big);
        if (result.roots > result.objects) return error.Corrupt;
        return result;
    }

    /// Each exclusive opening reserves a fresh durable incarnation before it
    /// exposes object IDs or tickets. Abandoned creations cannot alias on reopen.
    pub fn claim(self: Metadata) !Metadata {
        var next = self;
        next.incarnation = try std.math.add(u64, self.incarnation, 1);
        next.last_sequence = 0;
        // In-memory roots from the old opening are gone. Never resume its status-allow: replacement state identity
        // sweep using a partial mark set; rebuild from the new opening's roots.
        if (next.collection.phase != .idle) next.collection = .{ .phase = .clearing };
        return next;
    }
};

pub const Ticket = struct { store: StoreId, incarnation: u64, sequence: u64, revision: u64 };
pub const Mutation = struct {
    id: ObjectId,
    /// Null requires absence. A revision requires exactly that existing row.
    expected: ?u64,
    /// Null destroys a non-root record. Incoming references then resolve gone.
    /// This explicit deletion is distinct from tracing garbage collection.
    bytes: ?[]u8,
};
pub const Batch = struct {
    ticket: Ticket,
    changes: []const Mutation,
    limits: records.Limits,
    schemas: []const records.Schema,
    collection: ?collection.Request = null,

    pub const Evaluation = @import("evaluation.zig").Evaluation;

    /// The synchronous adapters drive the same evaluator used by asynchronous
    /// KV embeddings. Index and tracing refusals require atomic backend abort.
    pub fn apply(self: Batch, kv: anytype) !Metadata {
        var evaluation = Evaluation.init(&self);
        return evaluation.advance(kv);
    }

    pub fn resolve(self: Batch, current: Metadata) !Resolution {
        if (current.store != self.ticket.store or current.incarnation != self.ticket.incarnation) return error.StaleWriter;
        if (current.revision == self.ticket.revision and current.last_sequence < self.ticket.sequence) return .unchanged;
        const committed_revision = std.math.add(u64, self.ticket.revision, 1) catch return error.RecoveryRequired;
        if (current.revision == committed_revision and current.last_sequence == self.ticket.sequence) return .{ .committed = current };
        return error.RecoveryRequired;
    }
};
pub const Resolution = union(enum) { committed: Metadata, unchanged };
pub const Outcome = union(enum) { committed: Metadata, unchanged: anyerror, unknown };
