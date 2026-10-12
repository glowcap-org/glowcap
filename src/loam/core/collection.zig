//! Incremental tracing through transaction-local key/value operations. The
//! durable mark queue bounds RAM use independently of the stored graph size.
const std = @import("std");
const records = @import("loam_records");

pub const Progress = struct {
    phase: enum(u8) { idle, clearing, roots, trace, sweep, finishing } = .idle,
    cursor: [33]u8 = @splat(0),
    head: u64 = 0,
    tail: u64 = 0,
    reclaimed_objects: u64 = 0,
    reclaimed_bytes: u64 = 0,
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
        const phase = std.enums.fromInt(@FieldType(Progress, "phase"), bytes[0]) orelse return error.Corrupt;
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
    /// Exclusive worker scratch. Never part of the immutable operation digest.
    scratch: []u8,
};

/// A cursor result borrows only until the next transaction mutation.
pub const Row = struct { key: []const u8, value: []const u8 };

pub fn mark(progress: *Progress, kv: anytype, id: records.ObjectId) !void {
    const key = "gm".* ++ id.key();
    if (try kv.get(&key) != null) return;
    const next = try std.math.add(u64, progress.tail, 1);
    try kv.put(&key, "");
    try kv.put(&queueKey(progress.tail), &id.key());
    progress.tail = next;
}

pub fn apply(request: Request, metadata: anytype, kv: anytype, limits: records.Limits, schemas: []const records.Schema) !void {
    if (request.work_limit == 0 or request.scratch.len < limits.max_record_bytes) return error.InvalidLimits;
    const progress = &metadata.collection;
    // Idle is committed only after finishing removed every temporary row.
    // Reopening an interrupted cycle selects clearing through Metadata.claim.
    if (progress.phase == .idle) progress.* = .{ .phase = .roots };
    var seeded = false;
    for (0..request.work_limit) |_| {
        if (progress.tracing() and !seeded) {
            for (request.roots) |id| {
                if (id.store != metadata.store) return error.ForeignObject;
                try mark(progress, kv, id);
            }
            seeded = true;
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
            .roots => {
                if (try nextObject(progress, kv)) |row| {
                    const view = try checked(row, metadata.*, limits, schemas);
                    progress.cursor = view.id.key();
                    if (view.rooted) try mark(progress, kv, view.id);
                } else {
                    progress.cursor = @splat(0);
                    progress.phase = .trace;
                }
            },
            .trace => {
                if (progress.head == progress.tail) {
                    progress.phase = .sweep;
                    continue;
                }
                const key = queueKey(progress.head);
                const id = try records.ObjectId.fromKey((try kv.get(&key)) orelse return error.Corrupt);
                try kv.remove(&key);
                progress.head += 1;
                const bytes = (try kv.get(&id.key())) orelse continue; // Explicit deletion may leave gone edges.
                if (bytes.len > request.scratch.len) return error.RecordTooLarge;
                // LMDB value borrows end at the next write. Trace an owned
                // bounded copy before marking children mutates mapped pages.
                @memcpy(request.scratch[0..bytes.len], bytes);
                const view = try checked(.{ .key = &id.key(), .value = request.scratch[0..bytes.len] }, metadata.*, limits, schemas);
                var edges = view.edges();
                while (edges.next()) |edge| if (edge.strength == .strong) try mark(progress, kv, edge.target);
            },
            .sweep => {
                // Both live-retention seeds and concurrent writer barriers
                // must drain before another candidate can be deleted.
                if (progress.head != progress.tail) {
                    progress.phase = .trace;
                    continue;
                }
                if (try nextObject(progress, kv)) |row| {
                    const view = try checked(row, metadata.*, limits, schemas);
                    const length = row.value.len;
                    const key = view.id.key();
                    progress.cursor = key;
                    if (view.rooted or try kv.get(&("gm".* ++ key)) != null) continue;
                    metadata.objects = std.math.sub(u64, metadata.objects, 1) catch return error.Corrupt;
                    metadata.record_bytes = std.math.sub(u64, metadata.record_bytes, length) catch return error.Corrupt;
                    progress.reclaimed_objects = try std.math.add(u64, progress.reclaimed_objects, 1);
                    progress.reclaimed_bytes = try std.math.add(u64, progress.reclaimed_bytes, length);
                    try kv.remove(&key);
                } else progress.phase = .finishing;
            },
        }
    }
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
