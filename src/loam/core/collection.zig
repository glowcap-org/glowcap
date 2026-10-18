//! Incremental tracing through transaction-local key/value operations. The
//! durable mark queue bounds RAM use independently of the stored graph size.
const std = @import("std");
const records = @import("loam_records");

pub const Progress = struct {
    phase: Phase = .idle,
    cursor: [33]u8 = @splat(0),
    head: u64 = 0,
    tail: u64 = 0,
    reclaimed_objects: u64 = 0,
    reclaimed_bytes: u64 = 0,
    pub const Phase = enum(u8) { idle, clearing, roots, trace, sweep, finishing };
    pub const encoded_size = 66;

    pub fn encode(self: Progress) [encoded_size]u8 {
        var out: [encoded_size]u8 = undefined;
        out[0] = @backingInt(self.phase);
        @memcpy(out[1..34], &self.cursor);
        for ([_]u64{ self.head, self.tail, self.reclaimed_objects, self.reclaimed_bytes }, 0..) |v, i|
            std.mem.writeInt(u64, out[34 + i * 8 ..][0..8], v, .big);
        return out;
    }

    pub fn decode(bytes: *const [encoded_size]u8) !Progress {
        const phase = std.enums.fromInt(Phase, bytes[0]) orelse return error.Corrupt;
        const result: Progress = .{
            .phase = phase,
            .cursor = bytes[1..34].*,
            .head = std.mem.readInt(u64, bytes[34..42], .big),
            .tail = std.mem.readInt(u64, bytes[42..50], .big),
            .reclaimed_objects = std.mem.readInt(u64, bytes[50..58], .big),
            .reclaimed_bytes = std.mem.readInt(u64, bytes[58..66], .big),
        };
        if (result.head > result.tail) return error.Corrupt;
        return result;
    }

    pub fn tracing(self: Progress) bool {
        return self.phase == .roots or self.phase == .trace or self.phase == .sweep;
    }
};

pub const Request = struct {
    roots: []const records.ObjectId,
    work_limit: usize,
    /// Exclusive worker scratch, outside the batch the evaluator validates.
    scratch: []u8,
};

/// A cursor result borrows until the next write or the next walk.
pub const Row = struct { key: []const u8, value: []const u8 };

/// What a resumed evaluation must not redo. A suspended read leaves a batch
/// in the middle of one step, and this holds the reads that step has already
/// completed so the retry continues the step instead of restarting it. It lives
/// as long as one batch, and the persisted `Progress` alone survives a commit.
pub const Resume = struct {
    /// Steps this batch has spent of its work limit.
    steps: usize = 0,
    /// Roots this batch has marked so far, zero when the batch starts.
    seeded: usize = 0,
    /// Bytes of the record under trace copied into the scratch buffer, or
    /// null before that read.
    record_len: ?usize = null,
    /// The edge of the traced record to mark next.
    edge_cursor: usize = 0,
    /// The queued record under trace, read before its row.
    traced: ?records.ObjectId = null,
    /// A walked row whose mark lookup is the next step. A walk and a lookup
    /// never share a step, because a store that holds one loaded row would
    /// evict the walk's answer with the lookup.
    held: ?Held = null,

    pub const Held = struct { id: records.ObjectId, length: usize };

    /// Whether a multi-step unit is open.
    pub fn pending(self: Resume) bool {
        return self.held != null or self.traced != null;
    }
};

/// The longest physical key is a mark row: the two-byte mark prefix and a
/// 33-byte object key. An engine sizes key buffers with it.
pub const max_key_bytes: usize = 35;

comptime {
    const object_key = @typeInfo(@TypeOf(records.ObjectId.key)).@"fn".return_type.?;
    std.debug.assert("gm".len + @sizeOf(object_key) == max_key_bytes);
}

pub fn mark(progress: *Progress, kv: anytype, id: records.ObjectId) !void {
    const key = "gm".* ++ id.key();
    if (try kv.get(&key) != null) return;
    const next = try std.math.add(u64, progress.tail, 1);
    try kv.put(&key, "");
    try kv.put(&queueKey(progress.tail), &id.key());
    progress.tail = next;
}

pub fn apply(request: Request, metadata: anytype, kv: anytype, limits: records.Limits, schemas: []const records.Schema, carry: *Resume) !void {
    if (request.work_limit == 0 or request.scratch.len < limits.max_record_bytes) return error.InvalidLimits;
    var cycle: Cycle(@TypeOf(metadata), @TypeOf(kv)) = .{
        .request = request,
        .metadata = metadata,
        .kv = kv,
        .limits = limits,
        .schemas = schemas,
        .carry = carry,
    };
    const progress = cycle.cycleProgress();
    // Idle is committed only after finishing removed every temporary row.
    // Reopening an interrupted cycle selects clearing through Metadata.claim.
    if (progress.phase == .idle) progress.* = .{ .phase = .roots };
    // A unit of several steps finishes inside its batch, because only the
    // persisted Progress survives a commit and the unit's reads do not.
    while (carry.steps < request.work_limit or carry.pending()) : (carry.steps += 1) {
        if (progress.tracing()) {
            for (request.roots[carry.seeded..]) |id| {
                if (id.store != metadata.store) return error.ForeignObject;
                try mark(progress, kv, id);
                carry.seeded += 1;
            }
        }
        switch (progress.phase) {
            .idle => break,
            .clearing, .finishing => {
                if (try kv.next("g", null)) |row| {
                    // remove() consumes its key before invalidating the borrow.
                    try kv.remove(row.key);
                } else if (progress.phase == .clearing) {
                    progress.phase = .roots;
                    // A clearing request submits no custody obligations: its
                    // mutations erase old marks. Retire this batch before the
                    // Store submits pending custody and tracing can reach sweep.
                    break;
                } else progress.phase = .idle;
            },
            .roots => try cycle.roots(),
            .trace => try cycle.trace(),
            .sweep => try cycle.sweep(),
        }
    }
}

/// One collection cycle's phase steps over the store's row access. Each
/// step spends one unit of the batch's work limit.
fn Cycle(comptime Metadata: type, comptime Kv: type) type {
    return struct {
        request: Request,
        metadata: Metadata,
        kv: Kv,
        limits: records.Limits,
        schemas: []const records.Schema,
        carry: *Resume,

        const Self = @This();

        fn cycleProgress(self: *Self) *Progress {
            return &self.metadata.collection;
        }

        /// Walk every object row and mark the rooted ones.
        fn roots(self: *Self) !void {
            const progress = self.cycleProgress();
            if (self.carry.held) |held| {
                try mark(progress, self.kv, held.id);
                progress.cursor = held.id.key();
                self.carry.held = null;
            } else if (try nextObject(progress, self.kv)) |row| {
                const view = try checked(row, self.metadata.*, self.limits, self.schemas);
                if (view.rooted) self.carry.held = .{ .id = view.id, .length = row.value.len } else progress.cursor = view.id.key();
            } else {
                progress.cursor = @splat(0);
                progress.phase = .trace;
            }
        }

        /// Pop one queued record, trace its strong edges, and mark their targets.
        fn trace(self: *Self) !void {
            const progress = self.cycleProgress();
            if (progress.head == progress.tail) {
                progress.phase = .sweep;
                return;
            }
            const id = self.carry.traced orelse {
                self.carry.traced = try records.ObjectId.fromKey((try self.kv.get(&queueKey(progress.head))) orelse return error.Corrupt);
                return;
            };
            const key = id.key();
            const length = self.carry.record_len orelse {
                const bytes = (try self.kv.get(&key)) orelse {
                    // Explicit deletion may leave gone edges.
                    try self.kv.remove(&queueKey(progress.head));
                    progress.head += 1;
                    self.carry.traced = null;
                    return;
                };
                if (bytes.len > self.request.scratch.len) return error.RecordTooLarge;
                // A row borrow ends at the next write. Trace an owned bounded
                // copy before marking children mutates the store.
                @memcpy(self.request.scratch[0..bytes.len], bytes);
                self.carry.record_len = bytes.len;
                self.carry.edge_cursor = 0;
                return;
            };
            const view = try checked(.{ .key = &key, .value = self.request.scratch[0..length] }, self.metadata.*, self.limits, self.schemas);
            var edges = view.edges();
            edges.cursor = self.carry.edge_cursor;
            while (edges.next()) |edge| {
                if (edge.strength == .strong) try mark(progress, self.kv, edge.target);
                self.carry.edge_cursor = edges.cursor;
            }
            try self.kv.remove(&queueKey(progress.head));
            progress.head += 1;
            self.carry.traced = null;
            self.carry.record_len = null;
        }

        /// Walk every object row again and delete the unmarked, unrooted ones.
        fn sweep(self: *Self) !void {
            const progress = self.cycleProgress();
            // Both live-retention seeds and concurrent writer barriers
            // must drain before another candidate can be deleted.
            if (progress.head != progress.tail) {
                progress.phase = .trace;
                return;
            }
            if (self.carry.held) |held| {
                const key = held.id.key();
                const marked = (try self.kv.get(&("gm".* ++ key))) != null;
                progress.cursor = key;
                self.carry.held = null;
                if (marked) return;
                self.metadata.objects = std.math.sub(u64, self.metadata.objects, 1) catch return error.Corrupt;
                self.metadata.record_bytes = std.math.sub(u64, self.metadata.record_bytes, held.length) catch return error.Corrupt;
                progress.reclaimed_objects = try std.math.add(u64, progress.reclaimed_objects, 1);
                progress.reclaimed_bytes = try std.math.add(u64, progress.reclaimed_bytes, held.length);
                try self.kv.remove(&key);
            } else if (try nextObject(progress, self.kv)) |row| {
                const view = try checked(row, self.metadata.*, self.limits, self.schemas);
                if (view.rooted) progress.cursor = view.id.key() else self.carry.held = .{ .id = view.id, .length = row.value.len };
            } else progress.phase = .finishing;
        }
    };
}

fn nextObject(progress: *Progress, kv: anytype) !?Row {
    return kv.next("o", if (progress.cursor[0] == 0) null else &progress.cursor);
}

fn checked(row: Row, meta: anytype, limits: records.Limits, schemas: []const records.Schema) !records.View {
    const id = try records.ObjectId.fromKey(row.key);
    const view = try records.View.decode(row.value, limits, schemas);
    if (!view.id.eql(id) or id.store != meta.store or view.revision > meta.revision) return error.Corrupt;
    return view;
}

fn queueKey(sequence: u64) [10]u8 {
    var key: [10]u8 = undefined;
    @memcpy(key[0..2], "gq");
    std.mem.writeInt(u64, key[2..10], sequence, .big);
    return key;
}
