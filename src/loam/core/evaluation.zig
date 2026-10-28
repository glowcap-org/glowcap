//! One batch cursor for synchronous and asynchronously supplied transaction rows.
const std = @import("std");
const records = @import("loam_records");
const tx = @import("transaction.zig");
const names = @import("names.zig");
const collection = @import("collection.zig");

/// The immutable batch and its bytes stay at stable addresses until evaluation
/// retires. Only get and next may return RecordUnloaded. Writes must synchronously consume
/// their borrows. A resume keeps scalars and batch-owned views, never a backend
/// row borrow. Earlier emissions remain in the same atomic KV transaction. status-allow: event or source ordering
/// One cursor carries the validation and write passes.
///
/// A commit verifies the strong edges it introduces: each must reach a record
/// at or before this revision. An edge the record's committed revision already
/// held was verified when that revision committed and is not fetched again.
/// Every strong edge still answers for a target the same batch removes.
pub const Evaluation = struct {
    batch: *const tx.Batch,
    phase: enum { metadata, change, previous, edges, account, writes, index, name, source, barrier, collect, finish, done, failed } = .metadata,
    next: tx.Metadata = undefined,
    index: usize = 0,
    view: ?records.View = null,
    edge_cursor: usize = 0,
    edge_index: usize = 0,
    /// The change's strong edges its committed revision did not hold, by
    /// edge index. Decided while the previous revision is in hand, so a
    /// suspended target read resumes without fetching it again.
    introduced: std.StaticBitSet(records.Limits.max_edges_bound) = .empty,
    collection_resume: collection.Resume = .{},

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
            .metadata => {
                const old = try tx.Metadata.decode((try kv.get(tx.metadata_key)) orelse return error.Corrupt);
                if (old.store != batch.ticket.store or old.incarnation != batch.ticket.incarnation) return error.StaleWriter;
                if (old.revision != batch.ticket.revision) return error.RevisionConflict;
                if (batch.ticket.sequence <= old.last_sequence or (batch.changes.len == 0 and batch.collection == null) or (batch.changes.len != 0 and batch.collection != null)) return error.InvalidBatch;
                // One pass over the ascending order refuses a repeated record
                // and lets every later lookup search the batch. A collection
                // batch carries no changes.
                if (batch.changes.len != 0) for (batch.changes[0 .. batch.changes.len - 1], batch.changes[1..]) |prior, change| switch (prior.id.order(change.id)) {
                    .lt => {},
                    .eq => return error.DuplicateMutation,
                    .gt => return error.InvalidBatch,
                };
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
                const change = &batch.changes[self.index];
                if (change.id.store != self.next.store) return error.ForeignObject;
                self.view = if (change.staged) |staged| staged.view else null;
                self.phase = .previous;
            },
            .previous => {
                const change = &batch.changes[self.index];
                self.introduced = .empty;
                if (try kv.get(&change.id.key())) |bytes| {
                    const old = try records.View.decode(bytes, batch.limits, batch.schemas);
                    if (!old.id.eql(change.id) or old.revision > batch.ticket.revision) return error.Corrupt;
                    if (change.expected == null or old.revision != change.expected.?) return error.RevisionConflict;
                    if (self.view) |replacement| {
                        if (!std.meta.eql(try names.of(old, batch.schemas), try names.of(replacement, batch.schemas))) return error.NameChanged;
                    }
                    if (change.staged == null and old.rooted) return error.Rooted;
                    if (self.view) |replacement| self.introduced = introducedEdges(old, replacement);
                    self.next.record_bytes = std.math.sub(u64, self.next.record_bytes, bytes.len) catch return error.Corrupt;
                    self.next.objects = std.math.sub(u64, self.next.objects, 1) catch return error.Corrupt;
                    self.next.roots = std.math.sub(u64, self.next.roots, @intFromBool(old.rooted)) catch return error.Corrupt;
                } else if (change.expected != null or change.staged == null) return error.Gone else if (self.view) |created| {
                    self.introduced.setRangeValue(.{ .start = 0, .end = created.edge_count }, true);
                }
                if (self.view) |view| {
                    if (!view.id.eql(change.id) or view.revision != self.next.revision) return error.Corrupt;
                    if (change.expected == null and change.id.incarnation != self.next.incarnation) return error.StaleWriter;
                }
                self.edge_cursor = 0;
                self.edge_index = 0;
                self.phase = .edges;
            },
            .edges => {
                if (self.view) |view| {
                    var edges = view.edges();
                    edges.cursor = self.edge_cursor;
                    // A suspended target read resumes at this edge.
                    while (edges.next()) |edge| {
                        if (edge.strength == .strong) try verifyEdge(self, kv, edge.target, self.introduced.isSet(self.edge_index));
                        self.edge_cursor = edges.cursor;
                        self.edge_index += 1;
                    }
                }
                self.phase = .account;
            },
            .account => {
                if (self.view) |view| {
                    self.next.record_bytes = try std.math.add(u64, self.next.record_bytes, batch.changes[self.index].staged.?.bytes.len);
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
                const change = &batch.changes[self.index];
                const key = change.id.key();
                if (change.staged) |staged| try kv.put(&key, staged.bytes) else try kv.remove(&key);
                self.index += 1;
            },
            .index => {
                if (self.index == batch.changes.len) {
                    self.phase = .collect;
                    continue;
                }
                self.view = if (batch.changes[self.index].staged) |staged| staged.view else null;
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
                // A suspended read inside the sweep resumes the same step.
                if (batch.collection) |request| try collection.apply(request, &self.next, kv, batch.limits, batch.schemas, &self.collection_resume);
                self.next.last_sequence = batch.ticket.sequence;
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

/// A target this batch rewrites was validated by its own change, and one it
/// removes is dangling. Only an introduced edge fetches and decodes its target.
fn verifyEdge(self: *Evaluation, kv: anytype, target: records.ObjectId, introduced: bool) !void {
    const batch = self.batch;
    if (batch.change(target)) |candidate| {
        if (candidate.staged == null) return error.DanglingReference;
        return;
    }
    if (!introduced) return;
    const bytes = (try kv.get(&target.key())) orelse return error.DanglingReference;
    const view = try records.View.decode(bytes, batch.limits, batch.schemas);
    if (!view.id.eql(target) or view.revision > self.next.revision) return error.Corrupt;
}

/// The strong edges of `new` that `old` does not hold, by index in `new`.
fn introducedEdges(old: records.View, new: records.View) std.StaticBitSet(records.Limits.max_edges_bound) {
    var introduced: std.StaticBitSet(records.Limits.max_edges_bound) = .empty;
    var cursor: usize = 0;
    var edges = new.edges();
    var index: usize = 0;
    while (edges.next()) |edge| : (index += 1) {
        if (edge.strength == .strong and !keeps(old, edge.target, &cursor)) introduced.set(index);
    }
    return introduced;
}

/// Whether `old` holds a strong edge to `target`. An edit keeps the edges'
/// relative order, so the search resumes after the last match and wraps
/// once.
fn keeps(old: records.View, target: records.ObjectId, cursor: *usize) bool {
    const start = cursor.*;
    var edges = old.edges();
    edges.cursor = start;
    while (edges.next()) |edge| if (edge.strength == .strong and edge.target.eql(target)) {
        cursor.* = edges.cursor;
        return true;
    };
    edges = old.edges();
    while (edges.cursor < start) {
        const edge = edges.next() orelse break;
        if (edge.strength == .strong and edge.target.eql(target)) {
            cursor.* = edges.cursor;
            return true;
        }
    }
    return false;
}

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
