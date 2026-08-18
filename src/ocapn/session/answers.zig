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

/// Pending inbound answer as `Slot.remote_unresolved`.
pub fn pendingInboundSlot(position: model.AnswerPosition) slot.Slot {
    return answerSlot(position, .pending);
}

/// Answer `(position, status)` as CapTP Slot. Agrees with `slot.fulfill` /
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
/// the cap `max_listeners_per_target` counts). `mode` says whether shortening,
/// settling, or either transition concludes the subscription. The type is a bare `FarRef`, not a full
/// `Reference`: the installs only ever anchor a positional far target
/// (`pipeline.installAnswerListener` and the imported-promise install both
/// build `FarRef.object`), so an entry is POD — no heap, nothing to free.
pub const ListenerEntry = struct {
    listener: model.FarRef,
    mode: model.ListenMode,
};

/// A row's `op:listen` subscribers — the parties to notify when the row's
/// promise resolves. An inbound answer's pipelining payload and a third-party
/// imported promise (ADR-0009) hold listeners the same way: accumulate POD
/// entries until resolve, then hand the whole batch off. This type is that one
/// shared mechanic, so the two substrates cannot drift apart.
///
/// The fan-out bound (`max_listeners_per_target`, ADR-0025) is the length of
/// this whole list: it caps how many listeners one *listened-on promise*
/// accumulates — `op:listen`'s `target`, the answer or import, which is the
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

    /// Put back a just-taken listener slice without allocating. Preparation
    /// uses this rollback when a later reservation fails before settlement.
    pub fn restoreOwned(self: *ListenerList, entries: []ListenerEntry) void {
        std.debug.assert(self.entries.items.len == 0);
        if (entries.len == 0) return;
        self.entries = .fromOwnedSlice(entries);
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
    index: ProjectionIndex,
    untag: []const u8,
};

/// The only index state a pending projection needs. A canonical big integer is
/// outside every list admitted by this session's bounded value model, so its
/// decimal wire bytes do not become session-lived authority.
pub const ProjectionIndex = union(enum) {
    candidate: usize,
    out_of_bounds,

    pub fn fromInteger(index: model.Integer) ProjectionIndex {
        return switch (index) {
            .integer => |value| if (std.math.cast(usize, value)) |candidate|
                .{ .candidate = candidate }
            else
                .out_of_bounds,
            .big_integer => .out_of_bounds,
        };
    }
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
    /// Identity stamp of the answer row at `answer`, from
    /// `Session.store_stamp_counter`. A partner names its own answer
    /// positions and may release one and reuse the number, so the position
    /// alone does not say the row is still the question this projection was
    /// asked. Resolving a projection against a reused position would answer
    /// the partner's *new* question with the old one's value, and the
    /// application's real reply to it would then be refused as a second
    /// resolve and tear the session down. A stamp that no longer matches
    /// means the question is gone, and the projection is dropped.
    answer_row_id: u64,
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

/// One answer row plus its lazily allocated consequence payload.
pub const AnswerCell = struct {
    answer_status: AnswerStatus = .pending,
    /// Instance stamp from `Session.store_stamp_counter` (partner may reuse positions).
    row_id: u64,
    /// Wire-delta count per ADR-0008 `op:gc-answers`.
    count: u64 = 1,
    payload: ?*AnswerPayload = null,
    /// Next-profile local settling fan-out. The target import owns the ordered
    /// answer list; this back-link makes `op:gc-answers` removal O(1) without a
    /// scan of every imported promise. `settling_index == 0` names the inline
    /// primary answer, larger values are one-based indexes into its followers.
    settling_target: model.ImportPosition = .from(0),
    settling_index: usize = 0,
    has_settling_target: bool = false,

    pub fn initPending(row_id: u64) AnswerCell {
        return .{ .row_id = row_id };
    }

    /// CapTP answer status.
    pub fn status(self: *const AnswerCell) AnswerStatus {
        return self.answer_status;
    }

    pub fn fulfill(self: *AnswerCell) slot.TransitionError!void {
        if (self.answer_status != .pending) return error.NotUnresolved;
        self.answer_status = .fulfilled;
    }

    pub fn breakCell(self: *AnswerCell) slot.TransitionError!void {
        if (self.answer_status != .pending) return error.NotUnresolved;
        self.answer_status = .broken;
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

/// Typed-name-keyed answer table. Inbound rows preserve wire-versus-virtual
/// provenance; outbound rows carry only real wire answer positions.
pub fn AnswerTable(comptime IdType: type) type {
    return struct {
        rows: std.AutoHashMapUnmanaged(IdType, AnswerCell) = .empty,

        pub const Id = IdType;
        const Self = @This();
        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var it = self.rows.valueIterator();
            while (it.next()) |cell| deinitAnswerCell(allocator, cell);
            self.rows.deinit(allocator);
        }

        /// Mutable borrow of the row for `position`, or null when absent. Valid
        /// until the next insert into this table (a `put` may rehash and move rows).
        pub fn getPtr(self: *Self, position: Id) ?*AnswerCell {
            return self.rows.getPtr(position);
        }

        pub fn contains(self: *const Self, position: Id) bool {
            return self.rows.contains(position);
        }

        /// Refcount of `position`, or 0 if the answer is not held.
        pub fn count(self: *const Self, position: Id) u64 {
            if (self.rows.getPtr(position)) |cell| return cell.count;
            return 0;
        }

        /// Number of live answer rows, the value the inbound-answer cap bounds.
        pub fn len(self: *const Self) usize {
            return self.rows.count();
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, position: Id, cell: AnswerCell) !void {
            try self.rows.put(allocator, position, cell);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: u32) !void {
            try self.rows.ensureUnusedCapacity(allocator, additional);
        }

        pub fn putAssumeCapacity(self: *Self, position: Id, cell: AnswerCell) void {
            self.rows.putAssumeCapacity(position, cell);
        }

        pub fn remove(self: *Self, position: Id) void {
            // idempotent: this wrapper's contract is ensure-gone; callers remove a
            // position without knowing (or caring) whether a row was present.
            _ = self.rows.remove(position);
        }
    };
}

pub const InboundAnswerTable = AnswerTable(model.AnswerName);
pub const OutboundAnswerTable = AnswerTable(model.AnswerPosition);

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
