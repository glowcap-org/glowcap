//! One batch cursor for synchronous and asynchronously supplied transaction rows.
const std = @import("std");
const records = @import("loam_records");
const tx = @import("transaction.zig");
const names = @import("names.zig");
const collection = @import("collection.zig");

/// The immutable batch and its bytes stay at stable addresses until evaluation
/// retires. Only get may return RecordUnloaded. Writes must synchronously consume
/// their borrows. A resume keeps scalars and batch-owned views, never a backend
/// row borrow. Earlier emissions remain in the same atomic KV transaction.
/// Fixed cursor state replaces repeated fingerprint/validation/write passes.
pub const Evaluation = struct {
    batch: *const tx.Batch,
    phase: enum { fingerprint, metadata, change, previous, edges, account, writes, index, name, source, barrier, collect, finish, done, failed } = .fingerprint,
    next: tx.Metadata = undefined,
    index: usize = 0,
    view: ?records.View = null,
    edge_cursor: usize = 0,

    pub fn init(batch: *const tx.Batch) Evaluation {
        return .{ .batch = batch };
    }

    pub fn advance(self: *Evaluation, kv: anytype) !tx.Metadata {
        var synchronous = SynchronousWrites(@TypeOf(kv)){ .kv = kv };
        return self.run(&synchronous) catch |err| {
            if (err != error.RecordUnloaded) self.phase = .failed;
            return err;
        };
    }

    fn run(self: *Evaluation, kv: anytype) !tx.Metadata {
        const batch = self.batch;
        while (true) switch (self.phase) {
            .fingerprint => {
                if (!std.mem.eql(u8, &batch.digest, &tx.Batch.fingerprint(batch.ticket, batch.changes, batch.collection))) return error.Corrupt;
                self.phase = .metadata;
            },
            .metadata => {
                const old = try tx.Metadata.decode((try kv.get(tx.metadata_key)) orelse return error.Corrupt);
                if (old.store != batch.ticket.store or old.incarnation != batch.ticket.incarnation) return error.StaleWriter;
                if (old.revision != batch.ticket.revision) return error.RevisionConflict;
                if (batch.ticket.sequence <= old.last_sequence or (batch.changes.len == 0 and batch.collection == null) or (batch.changes.len != 0 and batch.collection != null)) return error.InvalidBatch;
                self.next = old;
                self.next.revision = try std.math.add(u64, old.revision, 1);
                self.phase = .change;
            },
            .change => {
                if (self.index == batch.changes.len) {
                    self.index = 0;
                    self.phase = .writes;
                    continue;
                }
                const change = batch.changes[self.index];
                if (change.id.store != self.next.store) return error.ForeignObject;
                for (batch.changes[0..self.index]) |prior| if (prior.id.eql(change.id)) return error.DuplicateMutation;
                self.view = if (change.bytes) |bytes| try records.View.decode(bytes, batch.limits, batch.schemas) else null;
                self.phase = .previous;
            },
            .previous => {
                const change = batch.changes[self.index];
                if (try kv.get(&change.id.key())) |bytes| {
                    const old = try records.View.decode(bytes, batch.limits, batch.schemas);
                    if (!old.id.eql(change.id) or old.revision > batch.ticket.revision) return error.Corrupt;
                    if (change.expected == null or old.revision != change.expected.?) return error.RevisionConflict;
                    if (self.view) |replacement| {
                        if (!std.meta.eql(try names.of(old, batch.schemas), try names.of(replacement, batch.schemas))) return error.NameChanged;
                    }
                    if (change.bytes == null and old.rooted) return error.Rooted;
                    self.next.record_bytes = std.math.sub(u64, self.next.record_bytes, bytes.len) catch return error.Corrupt;
                    self.next.objects = std.math.sub(u64, self.next.objects, 1) catch return error.Corrupt;
                    self.next.roots = std.math.sub(u64, self.next.roots, @intFromBool(old.rooted)) catch return error.Corrupt;
                } else if (change.expected != null or change.bytes == null) return error.Gone;
                if (self.view) |view| {
                    if (!view.id.eql(change.id) or view.revision != self.next.revision) return error.Corrupt;
                    if (change.expected == null and change.id.incarnation != self.next.incarnation) return error.StaleWriter;
                }
                self.edge_cursor = 0;
                self.phase = .edges;
            },
            .edges => {
                if (self.view) |view| {
                    var edges = view.edges();
                    edges.cursor = self.edge_cursor;
                    if (edges.next()) |edge| {
                        if (edge.strength == .strong) {
                            const target = blk: {
                                for (batch.changes) |candidate| if (candidate.id.eql(edge.target)) break :blk candidate.bytes;
                                break :blk try kv.get(&edge.target.key());
                            } orelse return error.DanglingReference;
                            const target_view = try records.View.decode(target, batch.limits, batch.schemas);
                            if (!target_view.id.eql(edge.target) or target_view.revision > self.next.revision) return error.Corrupt;
                        }
                        self.edge_cursor = edges.cursor;
                        continue;
                    }
                }
                self.phase = .account;
            },
            .account => {
                if (self.view) |view| {
                    self.next.record_bytes = try std.math.add(u64, self.next.record_bytes, batch.changes[self.index].bytes.?.len);
                    self.next.objects = try std.math.add(u64, self.next.objects, 1);
                    self.next.roots = try std.math.add(u64, self.next.roots, @intFromBool(view.rooted));
                }
                self.index += 1;
                self.phase = .change;
            },
            .writes => {
                if (self.index == batch.changes.len) {
                    self.index = 0;
                    self.phase = .index;
                    continue;
                }
                const change = batch.changes[self.index];
                const key = change.id.key();
                if (change.bytes) |bytes| try kv.put(&key, bytes) else try kv.remove(&key);
                self.index += 1;
            },
            .index => {
                if (self.index == batch.changes.len) {
                    self.phase = .collect;
                    continue;
                }
                self.view = if (batch.changes[self.index].bytes) |bytes| try records.View.decode(bytes, batch.limits, batch.schemas) else null;
                self.phase = .name;
            },
            .name => {
                if (self.view) |view| try names.install(kv, view, batch.schemas);
                self.phase = .source;
            },
            .source => {
                // Changed sources survive this cycle. Added strong edges are
                // marked even when the source had already been traced.
                if (self.view) |view| if (self.next.collection.tracing()) try collection.mark(&self.next.collection, kv, view.id);
                self.edge_cursor = 0;
                self.phase = .barrier;
            },
            .barrier => {
                if (self.view) |view| if (self.next.collection.tracing()) {
                    var edges = view.edges();
                    edges.cursor = self.edge_cursor;
                    if (edges.next()) |edge| {
                        if (edge.strength == .strong) try collection.mark(&self.next.collection, kv, edge.target);
                        self.edge_cursor = edges.cursor;
                        continue;
                    }
                };
                self.index += 1;
                self.phase = .index;
            },
            .collect => {
                // Cursor-driven collection still requires synchronous KV walks.
                // The embedding ABI explicitly has no collection submission.
                if (batch.collection) |request| collection.apply(request, &self.next, kv, batch.limits, batch.schemas) catch |err| {
                    if (err == error.RecordUnloaded) return error.UnsupportedCollection;
                    return err;
                };
                self.next.last_sequence = batch.ticket.sequence;
                self.next.last_digest = batch.digest;
                self.phase = .finish;
            },
            .finish => {
                try kv.put(tx.metadata_key, &self.next.encode());
                self.phase = .done;
                return self.next;
            },
            .done => return error.StaleCompletion,
            .failed => return error.InvalidBatch,
        };
    }
};

/// Helpers for names and collection use this same seam. A partially emitted
/// write cannot become a resumable read refusal, regardless of callback policy.
fn SynchronousWrites(comptime Kv: type) type {
    return struct {
        kv: Kv,
        pub fn get(self: *@This(), key: []const u8) !?[]const u8 {
            return self.kv.get(key);
        }
        pub fn next(self: *@This(), prefix: []const u8, after: ?[]const u8) !?collection.Row {
            return self.kv.next(prefix, after);
        }
        pub fn put(self: *@This(), key: []const u8, bytes: []const u8) !void {
            self.kv.put(key, bytes) catch |err| return if (err == error.RecordUnloaded) error.WriteWouldBlock else err;
        }
        pub fn remove(self: *@This(), key: []const u8) !void {
            self.kv.remove(key) catch |err| return if (err == error.RecordUnloaded) error.WriteWouldBlock else err;
        }
    };
}
