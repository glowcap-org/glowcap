//! Answer-table storage for a direct CapTP session.
//!
//! `Session` remains the authority boundary: validation and state transitions stay
//! in `mod.zig`, `validate.zig`, and `apply.zig`. This module owns only the
//! concrete answer rows, lazy payload, snapshots, and cleanup mechanics.

const std = @import("std");
const model = @import("model");
const slot = @import("../slot.zig");

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

    pub fn ensureUnusedCapacity(self: *ListenerList, allocator: std.mem.Allocator, count: usize) !void {
        try self.entries.ensureUnusedCapacity(allocator, count);
    }

    pub fn appendAssumeCapacity(self: *ListenerList, listener: ListenerEntry) void {
        self.entries.appendAssumeCapacity(listener);
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
    /// One reference belongs to the live answer row. A staged settlement and
    /// each queued notification carrier retain another reference so
    /// `op:gc-answers` can release/reuse the pipelining name without cancelling
    /// a resolver or listener that was already accepted for this incarnation.
    refs: u32 = 1,
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
    resolution: ?StoredResolution = null,
    /// Exact owned-model charge paired with `resolution`. Session aggregates
    /// it so a succession of published answers cannot hide variable retained
    /// trees behind the fixed answer-row cap.
    resolution_charge: usize = 0,
    /// V1.0's independently accepted resolver callback. The BiMap remains the
    /// live answer-name index; this captured import is the detached obligation
    /// that survives removal and legal reuse of that name.
    resolver_import: ?model.ImportPosition = null,
};

/// Session-local identity of one inbound answer incarnation. `AnswerName`
/// carries the wire/virtual namespace; `row_id` carries the epoch. Application
/// work must return this whole token so a late result cannot settle a new
/// question that reused the same wire position.
pub const AnswerTarget = struct {
    name: model.AnswerName,
    row_id: u64,
};

/// One owned resolution plus the exact answer incarnation named by a top-level
/// promise fulfillment. The wire value carries only a reusable position; this
/// sidecar keeps later local consequence walks from following a replacement row.
pub const StoredResolution = struct {
    value: model.Resolution,
    promise_target: ?AnswerTarget,
};

/// An accepted notification whose pipelining row has been released. The
/// payload is still single-owner data: this row owns one payload reference and
/// queued settlement/listener carriers retain the same box, never a resolution
/// clone.
pub const DetachedAnswer = struct {
    target: AnswerTarget,
    payload: *AnswerPayload,
};

pub const DetachedAnswerStore = struct {
    rows: std.AutoHashMapUnmanaged(u64, DetachedAnswer) = .empty,
};

/// One answer row plus its lazily allocated consequence payload.
pub const AnswerCell = struct {
    answer_status: AnswerStatus = .pending,
    /// Instance stamp from `Session.store_stamp_counter` (partner may reuse positions).
    row_id: u64,
    /// Wire-delta count per ADR-0008 `op:gc-answers`.
    count: u64 = 1,
    /// The application layer claimed responsibility for releasing this outbound
    /// answer, so a stateless serve policy must not release it at settlement.
    /// Meaningless on inbound rows.
    application_release_claimed: bool = false,
    /// The application consumed or discarded the one-shot notification. Wire
    /// settlement can precede notification, so answer_status cannot own this
    /// guard. Meaningless on inbound rows. Retired rows need no marker.
    application_notification_consumed: bool = false,
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
            while (it.next()) |cell| _ = deinitAnswerCell(allocator, cell);
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

/// An exact pending-answer payload prepared for one wider transaction. A cold
/// live row receives a fresh empty payload immediately; this token remains its
/// sole publication owner until commit and removes it on abandon. Detached rows
/// can only be prepared when their already-owned payload still exists.
pub const PreparedPendingPayload = struct {
    target: AnswerTarget,
    payload: *AnswerPayload,
    owns_fresh: bool,

    pub fn abandon(self: *PreparedPendingPayload, owner: anytype) void {
        if (!self.owns_fresh) return;
        const entry = owner.inbound_answers.getPtr(self.target.name) orelse unreachable;
        std.debug.assert(entry.row_id == self.target.row_id and entry.payload == self.payload);
        std.debug.assert(self.payload.queue.items.len == 0);
        std.debug.assert(self.payload.listeners.len() == 0);
        std.debug.assert(self.payload.projections.items.len == 0);
        std.debug.assert(self.payload.resolution == null);
        entry.payload = null;
        owner.releaseAnswerPayload(self.payload);
        self.owns_fresh = false;
    }

    pub fn commit(self: *PreparedPendingPayload) void {
        self.owns_fresh = false;
    }
};

pub fn preparePendingPayloadTarget(self: anytype, target: AnswerTarget) !PreparedPendingPayload {
    if (self.answerPayloadForTarget(target)) |payload| {
        if (payload.resolution != null) return error.UnexpectedMessage;
        return .{ .target = target, .payload = payload, .owns_fresh = false };
    }
    const entry = self.inbound_answers.getPtr(target.name) orelse return error.InvalidReference;
    if (entry.row_id != target.row_id or entry.status() != .pending)
        return error.InvalidReference;
    const payload = try ensureAnswerPayload(self.allocator, entry);
    return .{ .target = target, .payload = payload, .owns_fresh = true };
}

pub fn retainAnswerPayload(payload: *AnswerPayload) !void {
    payload.refs = std.math.add(u32, payload.refs, 1) catch
        return error.QueueCapExceeded;
}

/// Release one owner of a stable answer payload. Returns the exact retained
/// resolution charge only when this was the final owner, so the Session can
/// subtract it once regardless of whether the live row or a detached carrier
/// dies last.
pub fn releaseAnswerPayload(allocator: std.mem.Allocator, payload: *AnswerPayload) usize {
    std.debug.assert(payload.refs != 0);
    payload.refs -= 1;
    if (payload.refs != 0) return 0;
    const resolution_charge = payload.resolution_charge;
    for (payload.queue.items) |message| model.freeMessage(allocator, message);
    payload.queue.deinit(allocator);
    payload.listeners.deinit(allocator);
    for (payload.projections.items) |projection| deinitProjection(allocator, projection);
    payload.projections.deinit(allocator);
    if (payload.resolution) |resolution| model.freeResolution(allocator, resolution.value);
    allocator.destroy(payload);
    return resolution_charge;
}

/// Allocation-free admission result for one stored resolution. It measures the
/// owned tree once, computes replacement delta and the durable-byte ceiling,
/// and resolves promise identity before any capacity reservation or authority
/// mutation. Preparation below only materializes a missing lazy payload.
pub const ResolutionStorePlan = struct {
    entry: ?*AnswerCell,
    payload: ?*AnswerPayload,
    charge: usize,
    next_retained: usize,
    promise_target: ?AnswerTarget,
};

pub const PreparedResolutionStore = struct {
    entry: ?*AnswerCell,
    payload: *AnswerPayload,
    charge: usize,
    next_retained: usize,
    promise_target: ?AnswerTarget,
};

pub fn promiseTargetForResolution(self: anytype, resolution: model.Resolution) !?AnswerTarget {
    if (resolution != .fulfill or resolution.fulfill != .reference or
        resolution.fulfill.reference != .promise)
        return null;
    const name = model.AnswerName.fromWire(
        resolution.fulfill.reference.promise.answer_position,
    );
    const row = self.inbound_answers.getPtr(name) orelse return error.InvalidReference;
    return .{ .name = name, .row_id = row.row_id };
}

pub fn planResolutionStoreNamed(
    self: anytype,
    answer: model.AnswerName,
    resolution: model.Resolution,
) !ResolutionStorePlan {
    const entry = self.inbound_answers.getPtr(answer) orelse
        return error.InvalidReference;
    const charge = try model.measureResolutionOwnedBytes(resolution);
    const prior_charge = if (entry.payload) |payload| payload.resolution_charge else 0;
    std.debug.assert(self.retained_sent_answer_bytes >= prior_charge);
    const without_prior = self.retained_sent_answer_bytes - prior_charge;
    const next_retained = std.math.add(usize, without_prior, charge) catch
        return error.RetainedAnswerCapExceeded;
    if (next_retained > @as(usize, self.limits.max_retained_sent_answer_bytes))
        return error.RetainedAnswerCapExceeded;
    return .{
        .entry = entry,
        .payload = entry.payload,
        .charge = charge,
        .next_retained = next_retained,
        .promise_target = try promiseTargetForResolution(self, resolution),
    };
}

pub fn prepareResolutionStore(self: anytype, plan: ResolutionStorePlan) !PreparedResolutionStore {
    const payload = plan.payload orelse try ensureAnswerPayload(self.allocator, plan.entry.?);
    return .{
        .entry = plan.entry,
        .payload = payload,
        .charge = plan.charge,
        .next_retained = plan.next_retained,
        .promise_target = plan.promise_target,
    };
}

pub fn commitPreparedResolutionStore(
    self: anytype,
    prepared: PreparedResolutionStore,
    resolution: model.Resolution,
) void {
    if (prepared.payload.resolution) |prior|
        model.freeResolution(self.allocator, prior.value);
    self.retained_sent_answer_bytes = prepared.next_retained;
    prepared.payload.resolution = .{
        .value = resolution,
        .promise_target = prepared.promise_target,
    };
    prepared.payload.resolution_charge = prepared.charge;
    if (prepared.entry) |entry| if (entry.status() == .pending) switch (resolution) {
        .fulfill => entry.fulfill() catch unreachable,
        .@"break" => entry.breakCell() catch unreachable,
    };
}

pub fn planResolutionStoreTarget(
    self: anytype,
    target: AnswerTarget,
    payload: *AnswerPayload,
    resolution: model.Resolution,
) !ResolutionStorePlan {
    const found = self.answerPayloadForTarget(target) orelse return error.InvalidReference;
    if (found != payload or payload.resolution != null) return error.UnexpectedMessage;
    const charge = try model.measureResolutionOwnedBytes(resolution);
    std.debug.assert(self.retained_sent_answer_bytes >= payload.resolution_charge);
    const without_prior = self.retained_sent_answer_bytes - payload.resolution_charge;
    const next_retained = std.math.add(usize, without_prior, charge) catch
        return error.RetainedAnswerCapExceeded;
    if (next_retained > @as(usize, self.limits.max_retained_sent_answer_bytes))
        return error.RetainedAnswerCapExceeded;
    const promise_target = try promiseTargetForResolution(self, resolution);
    const live_entry = if (self.inbound_answers.getPtr(target.name)) |entry|
        if (entry.row_id == target.row_id) entry else null
    else
        null;
    return .{
        .entry = live_entry,
        .payload = payload,
        .charge = charge,
        .next_retained = next_retained,
        .promise_target = promise_target,
    };
}

/// Store one owned semantic resolution and move its exact charge into the
/// Session's retained-answer aggregate. Replacement computes its complete
/// accounting result before releasing the prior value.
pub fn storeResolutionNamed(self: anytype, answer: model.AnswerName, resolution: model.Resolution) !void {
    const plan = planResolutionStoreNamed(self, answer, resolution) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    const prepared = prepareResolutionStore(self, plan) catch |err| {
        model.freeResolution(self.allocator, resolution);
        return err;
    };
    commitPreparedResolutionStore(self, prepared, resolution);
}

/// Store `resolution` on the wire-named inbound answer, taking ownership and
/// marking it resolved. A replacement preserves the prior value if measuring
/// or accounting for the new resolution fails; every failure consumes the new
/// resolution.
pub fn storeResolution(self: anytype, answer: model.AnswerPosition, resolution: model.Resolution) !void {
    return storeResolutionNamed(self, .fromWire(answer), resolution);
}

pub fn retainedSentAnswerBytes(self: anytype) usize {
    return self.retained_sent_answer_bytes;
}

/// Borrow the stored resolution for `answer`, if it has resolved. The borrow
/// remains valid until that answer is replaced or removed.
pub fn peekResolutionNamed(self: anytype, answer: model.AnswerName) ?*const model.Resolution {
    const stored = peekStoredResolutionNamed(self, answer) orelse return null;
    return &stored.value;
}

pub fn peekStoredResolutionNamed(self: anytype, answer: model.AnswerName) ?*const StoredResolution {
    const entry = self.inbound_answers.getPtr(answer) orelse return null;
    const payload = entry.payload orelse {
        std.debug.assert(entry.status() == .pending);
        return null;
    };
    std.debug.assert((payload.resolution != null) == (entry.status() != .pending));
    if (payload.resolution) |*resolution| return resolution;
    return null;
}

pub fn peekResolution(self: anytype, answer: model.AnswerPosition) ?*const model.Resolution {
    return peekResolutionNamed(self, .fromWire(answer));
}

/// Whether `answer` is a known inbound answer that has resolved.
pub fn answerResolvedNamed(self: anytype, answer: model.AnswerName) bool {
    const entry = self.inbound_answers.getPtr(answer) orelse return false;
    return entry.status() != .pending;
}

pub fn answerResolved(self: anytype, answer: model.AnswerPosition) bool {
    return answerResolvedNamed(self, .fromWire(answer));
}

fn freeAnswerPayload(allocator: std.mem.Allocator, payload_ptr: *?*AnswerPayload) usize {
    const payload = payload_ptr.* orelse return 0;
    payload_ptr.* = null;
    return releaseAnswerPayload(allocator, payload);
}

pub fn deinitAnswerCell(allocator: std.mem.Allocator, cell: *AnswerCell) usize {
    return freeAnswerPayload(allocator, &cell.payload);
}
