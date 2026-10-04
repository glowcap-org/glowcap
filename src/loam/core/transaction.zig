//! Shared batch validation and exact commit metadata for storage adapters.
//! Adapters invoke this code inside their atomic transaction on the embedding's
//! executor. This module owns no I/O, worker, or backend policy.
const std = @import("std");
const records = @import("loam_records");
const collection = @import("collection.zig");
pub const ObjectId = records.ObjectId;
pub const StoreId = records.StoreId;
pub const metadata_key = "m";

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

    /// Validates record deltas before writing; index and tracing refusals still
    /// require atomic backend abort. `kv` supplies bounded transaction-local
    /// get/put/remove operations. Borrows stay valid until the write pass.
    pub fn apply(self: Batch, kv: anytype) !Metadata {
        if (!std.mem.eql(u8, &self.digest, &fingerprint(self.ticket, self.changes, self.collection))) return error.Corrupt;
        const old = try Metadata.decode((try kv.get(metadata_key)) orelse return error.Corrupt);
        if (old.store != self.ticket.store or old.incarnation != self.ticket.incarnation) return error.StaleWriter;
        if (old.revision != self.ticket.revision) return error.RevisionConflict;
        if (self.ticket.sequence <= old.last_sequence or (self.changes.len == 0 and self.collection == null) or (self.changes.len != 0 and self.collection != null)) return error.InvalidBatch;
        var next = old;
        next.revision = try std.math.add(u64, old.revision, 1);
        for (self.changes, 0..) |change, i| {
            if (change.id.store != old.store) return error.ForeignObject;
            for (self.changes[0..i]) |prior| if (prior.id.eql(change.id)) return error.DuplicateMutation;
            const proposed = if (change.bytes) |bytes| try records.View.decode(bytes, self.limits, self.schemas) else null;
            const previous = try kv.get(&change.id.key());
            if (previous) |bytes| {
                const view = try records.View.decode(bytes, self.limits, self.schemas);
                if (!view.id.eql(change.id) or view.revision > old.revision) return error.Corrupt;
                if (change.expected == null or view.revision != change.expected.?) return error.RevisionConflict;
                if (proposed) |replacement| {
                    if (!std.meta.eql(try @import("names.zig").of(view, self.schemas), try @import("names.zig").of(replacement, self.schemas))) return error.NameChanged;
                }
                if (change.bytes == null and view.rooted) return error.Rooted;
                next.record_bytes = std.math.sub(u64, next.record_bytes, bytes.len) catch return error.Corrupt;
                next.objects = std.math.sub(u64, next.objects, 1) catch return error.Corrupt;
                next.roots = std.math.sub(u64, next.roots, @intFromBool(view.rooted)) catch return error.Corrupt;
            } else if (change.expected != null or change.bytes == null) return error.Gone;
            if (proposed) |view| {
                const bytes = change.bytes.?;
                if (!view.id.eql(change.id) or view.revision != next.revision) return error.Corrupt;
                if (previous == null and change.id.incarnation != old.incarnation) return error.StaleWriter;
                var edges = view.edges();
                while (edges.next()) |edge| {
                    if (edge.strength == .weak) continue;
                    const target = blk: {
                        for (self.changes) |candidate| if (candidate.id.eql(edge.target)) break :blk candidate.bytes;
                        break :blk try kv.get(&edge.target.key());
                    } orelse return error.DanglingReference;
                    const target_view = try records.View.decode(target, self.limits, self.schemas);
                    if (!target_view.id.eql(edge.target) or target_view.revision > next.revision) return error.Corrupt;
                }
                next.record_bytes = try std.math.add(u64, next.record_bytes, bytes.len);
                next.objects = try std.math.add(u64, next.objects, 1);
                next.roots = try std.math.add(u64, next.roots, @intFromBool(view.rooted));
            }
        }
        next.last_sequence = self.ticket.sequence;
        next.last_digest = self.digest;
        for (self.changes) |change| {
            const key = change.id.key();
            if (change.bytes) |bytes| try kv.put(&key, bytes) else try kv.remove(&key);
        }
        for (self.changes) |change| if (change.bytes) |bytes| {
            // Proposed bytes belong to the immutable batch, so backend writes
            // cannot invalidate the edge iterator used by the barrier.
            const view = try records.View.decode(bytes, self.limits, self.schemas);
            try @import("names.zig").install(kv, view, self.schemas);
            try collection.writeBarrier(&next.collection, kv, view);
        };
        if (self.collection) |request| try collection.apply(request, &next, kv, self.limits, self.schemas);
        try kv.put(metadata_key, &next.encode());
        return next;
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
