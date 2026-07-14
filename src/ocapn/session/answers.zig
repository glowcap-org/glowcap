//! Answer-table storage for a direct CapTP session.
//!
//! `Session` remains the authority boundary: validation and state transitions stay
//! in `mod.zig`, `validate.zig`, and `apply.zig`. This module owns only the
//! concrete answer rows, lazy payload, snapshots, and cleanup mechanics.

const std = @import("std");
const model = @import("model");
const slot = @import("slot.zig");

pub const AnswerStatus = enum {
    pending,
    fulfilled,
    broken,
};

/// Pending inbound answer → `Slot.remote_unresolved`.
pub fn pendingInboundSlot(position: model.AnswerPosition) slot.Slot {
    return answerSlot(position, .pending);
}

/// Answer `(position, status)` → CapTP Slot. Agrees with `slot.fulfill` /
/// `slot.breakSlot` on the pending arm.
pub fn answerSlot(position: model.AnswerPosition, status: AnswerStatus) slot.Slot {
    const p = position.int();
    return switch (status) {
        .pending => .{ .remote_unresolved = p },
        .fulfilled => .{ .remote_value = p },
        .broken => .{ .broken = .{ .mint = .remote, .position = p } },
    };
}

/// A party that asked (via `op:listen`) to be told when an answer resolves.
/// `listener` is `op:listen`'s listener capability, the far export the
/// resolution is delivered to when the answer fires (it becomes the fire
/// `op:deliver`'s target). The field mirrors the wire name so it is not
/// confused with `op:listen`'s `target` (the promise being listened on, which
/// the cap `max_listeners_per_target` counts). `wants_partial` requests
/// intermediate notifications when the answer resolves to another promise
/// rather than only the final value. The type is a bare `FarRef`, not a full
/// `Reference`: the installs only ever anchor a positional far target
/// (`pipeline.installAnswerListener` and the imported-promise install both
/// build `FarRef.object`), so an entry is POD — no heap, nothing to free.
pub const ListenerEntry = struct {
    listener: model.FarRef,
    wants_partial: bool,
};

/// A row's `op:listen` subscribers — the parties to notify when the row's
/// promise resolves. An inbound answer's pipelining payload and a third-party
/// imported promise (ADR-0009) hold listeners the same way: accumulate POD
/// entries until resolve, then hand the whole batch off. This type is that one
/// shared mechanic, so the two substrates cannot drift apart.
///
/// The fan-out bound (`max_listeners_per_target`, ADR-0025) is the length of
/// this whole list: it caps how many listeners one *listened-on promise*
/// accumulates — `op:listen`'s `target`, the answer or import — which is the
/// quantity a flooding partner grows. It is deliberately not a per-
/// `ListenerEntry.listener` (per notify-destination) count: that would let a
/// partner evade the bound by naming a fresh destination each time. The check
/// stays at the call site because the answer side must read the length before
/// lazily allocating its payload. The stored resolution stays on each row —
/// its other consumers (an answer's projections and status) make it answer
/// state, not listener state.
pub const ListenerList = struct {
    entries: std.ArrayList(ListenerEntry) = .empty,

    pub const empty: ListenerList = .{};

    pub fn len(self: *const ListenerList) usize {
        return self.entries.items.len;
    }

    /// Append `listener` (a POD entry; nothing to free on failure).
    pub fn append(self: *ListenerList, allocator: std.mem.Allocator, listener: ListenerEntry) !void {
        try self.entries.append(allocator, listener);
    }

    /// Hand the caller every listener, leaving the list empty. Returns an
    /// empty slice when there are none; the caller frees only the slice (the
    /// entries are POD).
    pub fn take(self: *ListenerList, allocator: std.mem.Allocator) ![]ListenerEntry {
        if (self.entries.items.len == 0) return &.{};
        return self.entries.toOwnedSlice(allocator);
    }

    /// Release the backing store (entries are POD).
    pub fn deinit(self: *ListenerList, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
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
    /// The inbound answer position the projection was exported at, the
    /// promise the requester pipelines against.
    answer: model.AnswerPosition,
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
    /// `pending`. FIFO; each is an owned `model.Message` freed on drain or
    /// removal.
    queue: std.ArrayList(model.Message) = .empty,
    /// Parties listening for this answer's resolution (POD entries).
    listeners: ListenerList = .empty,
    /// `op:get` / `op:index` projections waiting on this answer's resolution
    /// (ADR-0050). Each entry's `.field` bytes are owned; freed on drain or
    /// removal.
    projections: std.ArrayList(Projection) = .empty,
    /// The resolution, stored once the answer resolves so a late `op:listen`
    /// fires immediately. Owned; freed on removal.
    resolution: ?model.Resolution = null,
};

/// Answer row as Slot binding + cold payload. Status is derived from binding.
pub const AnswerCell = struct {
    binding: slot.Slot,
    /// Instance stamp from `Session.store_stamp_counter` (partner may reuse positions).
    row_id: u64,
    /// Wire-delta count per ADR-0008 `op:gc-answers`.
    count: u64 = 1,
    payload: ?*AnswerPayload = null,

    pub fn initPending(position: model.AnswerPosition, row_id: u64) AnswerCell {
        return .{
            .binding = pendingInboundSlot(position),
            .row_id = row_id,
        };
    }

    /// CapTP answer status from the Slot binding (remote mint only).
    pub fn status(self: *const AnswerCell) AnswerStatus {
        return switch (self.binding) {
            .remote_unresolved => .pending,
            .remote_value => .fulfilled,
            .broken => .broken,
            .local_unresolved, .local_value => unreachable,
        };
    }

    pub fn fulfill(self: *AnswerCell) slot.TransitionError!void {
        self.binding = try slot.fulfill(self.binding);
    }

    pub fn breakCell(self: *AnswerCell) slot.TransitionError!void {
        self.binding = try slot.breakSlot(self.binding);
    }
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

    pub fn of(cell: *const AnswerCell) AnswerView {
        return .{
            .status = cell.status(),
            .count = cell.count,
            .queued_calls = if (cell.payload) |p| p.queue.items.len else 0,
            .listeners = if (cell.payload) |p| p.listeners.len() else 0,
            .projections = if (cell.payload) |p| p.projections.items.len else 0,
            .resolved = if (cell.payload) |p| p.resolution != null else false,
        };
    }
};

/// Position-keyed answer table. Rows are `AnswerCell` (Slot binding + payload).
pub const AnswerTable = struct {
    rows: std.AutoHashMapUnmanaged(u64, AnswerCell) = .empty,

    pub const Id = model.AnswerPosition;
    pub const empty: AnswerTable = .{};

    pub fn deinit(self: *AnswerTable, allocator: std.mem.Allocator) void {
        var it = self.rows.valueIterator();
        while (it.next()) |cell| deinitAnswerCell(allocator, cell);
        self.rows.deinit(allocator);
    }

    /// Mutable borrow of the row for `position`, or null when absent. Valid
    /// until the next insert into this table (a `put` may rehash and move rows).
    pub fn getPtr(self: *AnswerTable, position: Id) ?*AnswerCell {
        return self.rows.getPtr(position.int());
    }

    pub fn contains(self: *const AnswerTable, position: Id) bool {
        return self.rows.contains(position.int());
    }

    /// Refcount of `position`, or 0 if the answer is not held.
    pub fn count(self: *const AnswerTable, position: Id) u64 {
        if (self.rows.getPtr(position.int())) |cell| return cell.count;
        return 0;
    }

    /// Number of live answer rows, the value the inbound-answer cap bounds.
    pub fn len(self: *const AnswerTable) usize {
        return self.rows.count();
    }

    pub fn put(self: *AnswerTable, allocator: std.mem.Allocator, position: Id, cell: AnswerCell) !void {
        try self.rows.put(allocator, position.int(), cell);
    }

    pub fn remove(self: *AnswerTable, position: Id) void {
        // idempotent: this wrapper's contract is ensure-gone; callers remove a
        // position without knowing (or caring) whether a row was present.
        _ = self.rows.remove(position.int());
    }
};

/// Borrow the answer's payload, allocating it on first use.
pub fn ensureAnswerPayload(allocator: std.mem.Allocator, cell: *AnswerCell) !*AnswerPayload {
    if (cell.payload) |payload| return payload;
    const payload = try allocator.create(AnswerPayload);
    payload.* = .{};
    cell.payload = payload;
    return payload;
}

fn freeAnswerPayload(allocator: std.mem.Allocator, payload_ptr: *?*AnswerPayload) void {
    const payload = payload_ptr.* orelse return;
    for (payload.queue.items) |message| model.freeMessage(allocator, message);
    payload.queue.deinit(allocator);
    payload.listeners.deinit(allocator);
    for (payload.projections.items) |projection| deinitProjection(allocator, projection);
    payload.projections.deinit(allocator);
    if (payload.resolution) |resolution| model.freeResolution(allocator, resolution);
    allocator.destroy(payload);
    payload_ptr.* = null;
}

pub fn deinitAnswerCell(allocator: std.mem.Allocator, cell: *AnswerCell) void {
    freeAnswerPayload(allocator, &cell.payload);
}
