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

pub const Metadata = struct {
    store: StoreId,
    incarnation: u64 = 0,
    revision: u64 = 0,
    objects: u64 = 0,
    record_bytes: u64 = 0,
    roots: u64 = 0,
    last_sequence: u64 = 0,
    last_digest: [32]u8 = @splat(0),
    collection: collection.Progress = .{},
    pub const encoded_size = 174;

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
        @memcpy(bytes[0..8], "LOAM\x00\x00\x00\x03");
        std.mem.writeInt(u128, bytes[8..24], @backingInt(self.store), .big);
        const values = [_]u64{ self.incarnation, self.revision, self.objects, self.record_bytes, self.roots, self.last_sequence };
        for (values, 0..) |value, i| std.mem.writeInt(u64, bytes[24 + i * 8 ..][0..8], value, .big);
        @memcpy(bytes[72..104], &self.last_digest);
        @memcpy(bytes[104..170], &self.collection.encode());
        std.mem.writeInt(u32, bytes[170..174], std.hash.Crc32.hash(bytes[0..170]), .big);
        return bytes;
    }

    pub fn decode(bytes: []const u8) !Metadata {
        if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..8], "LOAM\x00\x00\x00\x03")) return error.Corrupt;
        if (std.hash.Crc32.hash(bytes[0..170]) != std.mem.readInt(u32, bytes[170..174], .big)) return error.Corrupt;
        const result: Metadata = .{
            .store = @fromBackingInt(std.mem.readInt(u128, bytes[8..24], .big)),
            .incarnation = std.mem.readInt(u64, bytes[24..32], .big),
            .revision = std.mem.readInt(u64, bytes[32..40], .big),
            .objects = std.mem.readInt(u64, bytes[40..48], .big),
            .record_bytes = std.mem.readInt(u64, bytes[48..56], .big),
            .roots = std.mem.readInt(u64, bytes[56..64], .big),
            .last_sequence = std.mem.readInt(u64, bytes[64..72], .big),
            .last_digest = bytes[72..104].*,
            .collection = try collection.Progress.decode(bytes[104..170]),
        };
        if (result.roots > result.objects) return error.Corrupt;
        return result;
    }

    /// Each exclusive opening reserves a fresh durable incarnation before it
    /// exposes object IDs or tickets. Abandoned creations cannot alias on reopen.
    pub fn claim(self: Metadata) !Metadata {
        var next = self;
        next.incarnation = try std.math.add(u64, self.incarnation, 1);
        next.last_sequence = 0;
        next.last_digest = @splat(0);
        // In-memory roots from the old opening are gone. Never resume its
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
    /// Null destroys a non-root record. Incoming references then resolve gone;
    /// this explicit deletion is distinct from tracing garbage collection.
    bytes: ?[]const u8,
};
pub const Batch = struct {
    ticket: Ticket,
    digest: [32]u8,
    changes: []const Mutation,
    limits: records.Limits,
    schemas: []const records.Schema,
    collection: ?collection.Request = null,

    pub fn fingerprint(ticket: Ticket, changes: []const Mutation, request: ?collection.Request) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        const stamp = Metadata{ .store = ticket.store, .incarnation = ticket.incarnation, .revision = ticket.revision, .last_sequence = ticket.sequence };
        hash.update(&stamp.encode());
        for (changes) |change| {
            hash.update(&change.id.key());
            var numbers: [18]u8 = undefined;
            numbers[0] = @intFromBool(change.expected != null);
            numbers[1] = @intFromBool(change.bytes != null);
            std.mem.writeInt(u64, numbers[2..10], change.expected orelse 0, .big);
            std.mem.writeInt(u64, numbers[10..18], if (change.bytes) |b| b.len else 0, .big);
            hash.update(&numbers);
            if (change.bytes) |bytes| hash.update(bytes);
        }
        hash.update(&.{@intFromBool(request != null)});
        if (request) |work| {
            var limit: [8]u8 = undefined;
            std.mem.writeInt(u64, &limit, work.work_limit, .big);
            hash.update(&limit);
            for (work.roots) |id| hash.update(&id.key());
        }
        return hash.finalResult();
    }

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
        if (current.revision == self.ticket.revision + 1 and current.last_sequence == self.ticket.sequence and
            std.mem.eql(u8, &current.last_digest, &self.digest)) return .{ .committed = current };
        return error.RecoveryRequired;
    }
};
pub const Resolution = union(enum) { committed: Metadata, unchanged };
pub const Outcome = union(enum) { committed: Metadata, unchanged: anyerror, unknown };
