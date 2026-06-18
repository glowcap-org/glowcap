//! Answer-table storage for a direct CapTP session.
//!
//! `Session` remains the authority boundary: validation and state transitions stay
//! in `mod.zig`, `validate.zig`, and `apply.zig`. This module owns only the
//! concrete answer rows, lazy payload, snapshots, and cleanup mechanics.

const std = @import("std");
const model = @import("model");

pub const AnswerStatus = enum {
    pending,
    fulfilled,
    broken,
};

/// A party that asked (via `op:listen`) to be told when an answer resolves. The
/// `target` is the capability the resolution is delivered to; `wants_partial`
/// requests intermediate notifications when the answer resolves to another
/// promise rather than only the final value. The entry owns `target`.
pub const ListenerEntry = struct {
    target: model.Reference,
    wants_partial: bool,
};

/// What a projection selects from the settled value: a Struct field by name,
/// a List element by zero-based index, or a Tagged payload by asserted tag.
pub const ProjectionKind = union(enum) {
    field: []const u8,
    index: i64,
    untag: []const u8,
};

/// A pending `op:get` / `op:index` / `op:untag` projection anchored on an
/// answer, the shape ADR-0050 settles: when the answer resolves, the engine
/// resolves `answer` to the named field, element, or unwrapped Tagged payload
/// of the resolution. The `.field` and `.untag` arms own their name bytes.
pub const Projection = struct {
    kind: ProjectionKind,
    /// The inbound answer position the projection was exported at — the
    /// promise the requester pipelines against.
    answer: u64,
    /// Re-anchor hops consumed so far. A projection follows a resolution that
    /// is itself a promise onto that promise's answer; the engine caps the
    /// hops at `SessionLimits.max_projection_chain` so a stored-resolution
    /// cycle breaks the projected answer instead of walking forever.
    hops: u32 = 0,
};

/// Release a projection's owned bytes (a `.field` arm's name or a `.untag`
/// arm's tag).
pub fn deinitProjection(allocator: std.mem.Allocator, projection: Projection) void {
    switch (projection.kind) {
        .field => |field| allocator.free(field),
        .index => {},
        .untag => |tag| allocator.free(tag),
    }
}

/// Cold pipelining payload for an answer (ADR-0007), allocated lazily only when
/// an answer actually accrues a queued call, a listener, a projection, or a
/// stored resolution.
pub const AnswerPayload = struct {
    /// Pipelined `op:deliver`s that arrived for this answer while it was still
    /// `pending`. FIFO; each is an owned `model.Message` released on drain or
    /// removal.
    queue: std.ArrayList(model.Message) = .empty,
    /// Parties listening for this answer's resolution. Each owns its `target`.
    listeners: std.ArrayList(ListenerEntry) = .empty,
    /// `op:get` / `op:index` projections waiting on this answer's resolution
    /// (ADR-0050). Each entry's `.field` bytes are owned; released on drain or
    /// removal.
    projections: std.ArrayList(Projection) = .empty,
    /// The resolution, stored once the answer resolves so a late `op:listen`
    /// fires immediately. Owned; released on removal.
    resolution: ?model.Resolution = null,
};

/// Hot answer row: just the state-machine fields read on every lookup. The
/// pipelining payload hangs off `payload`, present only when needed.
pub const AnswerEntry = struct {
    status: AnswerStatus,
    /// Single-reference wire-delta count per ADR-0008 `op:gc-answers`.
    /// Initialized to 1 on install; decremented to 0 on the matching GC message.
    count: u64 = 1,
    /// Lazily-allocated cold payload (queued calls / listeners / resolution).
    payload: ?*AnswerPayload = null,
};

/// By-value snapshot of an answer's observable state, returned by the public
/// `Session.inboundAnswer` / `Session.outboundAnswer` accessors.
pub const AnswerView = struct {
    status: AnswerStatus,
    count: u64,
    /// Number of pipelined calls queued against this answer.
    queued_calls: usize,
    /// Number of listeners registered on this answer.
    listeners: usize,
    /// Number of `op:get` / `op:index` projections anchored on this answer.
    projections: usize,
    /// Whether a resolution has been stored for this answer.
    resolved: bool,

    pub fn of(entry: *const AnswerEntry) AnswerView {
        return .{
            .status = entry.status,
            .count = entry.count,
            .queued_calls = if (entry.payload) |p| p.queue.items.len else 0,
            .listeners = if (entry.payload) |p| p.listeners.items.len else 0,
            .projections = if (entry.payload) |p| p.projections.items.len else 0,
            .resolved = if (entry.payload) |p| p.resolution != null else false,
        };
    }
};

/// Position-keyed answer table (ADR-0007). Inbound and outbound answers are
/// addressed by dense, monotonic answer-pos; this maps the position straight to
/// its row in O(1) instead of scanning.
pub const AnswerTable = struct {
    rows: std.AutoHashMapUnmanaged(u64, AnswerEntry) = .empty,

    pub const empty: AnswerTable = .{};

    pub fn deinit(self: *AnswerTable, allocator: std.mem.Allocator) void {
        var it = self.rows.valueIterator();
        while (it.next()) |entry| deinitAnswerEntry(allocator, entry);
        self.rows.deinit(allocator);
    }

    /// Mutable borrow of the row for `position`, or null when absent. Valid
    /// until the next insert into this table (a `put` may rehash and move rows).
    pub fn getPtr(self: *AnswerTable, position: u64) ?*AnswerEntry {
        return self.rows.getPtr(position);
    }

    pub fn contains(self: *const AnswerTable, position: u64) bool {
        return self.rows.contains(position);
    }

    /// Refcount of `position`, or 0 if the answer is not held.
    pub fn count(self: *const AnswerTable, position: u64) u64 {
        if (self.rows.getPtr(position)) |entry| return entry.count;
        return 0;
    }

    /// Number of live answer rows — the value the inbound-answer cap bounds.
    pub fn len(self: *const AnswerTable) usize {
        return self.rows.count();
    }

    pub fn put(self: *AnswerTable, allocator: std.mem.Allocator, position: u64, entry: AnswerEntry) !void {
        try self.rows.put(allocator, position, entry);
    }

    pub fn remove(self: *AnswerTable, position: u64) void {
        _ = self.rows.remove(position);
    }
};

/// Borrow the answer's payload, allocating it on first use. The returned pointer
/// is owned by the entry and freed by `deinitAnswerEntry`.
pub fn ensureAnswerPayload(allocator: std.mem.Allocator, entry: *AnswerEntry) !*AnswerPayload {
    if (entry.payload) |payload| return payload;
    const payload = try allocator.create(AnswerPayload);
    payload.* = .{};
    entry.payload = payload;
    return payload;
}

/// Release the owned memory an `AnswerEntry` holds: queued pipelined calls,
/// listener targets, and any stored resolution. The entry's queue / listener
/// lists are emptied so the struct is safe to drop or remove afterward.
pub fn deinitAnswerEntry(allocator: std.mem.Allocator, entry: *AnswerEntry) void {
    const payload = entry.payload orelse return;
    for (payload.queue.items) |message| model.freeMessage(allocator, message);
    payload.queue.deinit(allocator);
    for (payload.listeners.items) |listener| model.freeReference(allocator, listener.target);
    payload.listeners.deinit(allocator);
    for (payload.projections.items) |projection| deinitProjection(allocator, projection);
    payload.projections.deinit(allocator);
    if (payload.resolution) |resolution| model.freeResolution(allocator, resolution);
    allocator.destroy(payload);
    entry.payload = null;
}
