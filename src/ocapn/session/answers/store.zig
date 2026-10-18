//! Answer-table storage for a direct CapTP session.
//!
//! `Session` remains the authority boundary: validation and state transitions stay
//! in `mod.zig`, `validate.zig`, and `apply.zig`. This module owns only the
//! concrete answer rows, lazy payload, snapshots, and cleanup mechanics.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const slot = @import("../slot.zig");
const session = @import("../mod.zig");

const Session = session.Session;

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
/// build `FarRef.object`), so an entry is POD, no heap, nothing to free.
pub const ListenerEntry = struct {
    listener: model.FarRef,
    mode: model.ListenMode,
};

/// A row's `op:listen` subscribers, the parties to notify when the row's
/// promise resolves. An inbound answer's pipelining payload and a third-party
/// imported promise (ADR-0009) hold listeners the same way: accumulate POD
/// entries until resolve, then hand the whole batch off. This type is that one
/// shared mechanic, so the two substrates cannot drift apart.
///
/// The fan-out bound (`max_listeners_per_target`, ADR-0025) is the length of
/// this whole list: it caps how many listeners one *listened-on promise*
/// accumulates, `op:listen`'s `target`, the answer or import, which is the
/// quantity a flooding partner grows. It is not a per-
/// `ListenerEntry.listener` (per notify-destination) count: that would let a
/// partner evade the bound by naming a fresh destination each time. The check
/// stays at the call site because the answer side must read the length before
/// lazily allocating its payload. The stored resolution stays on each row,
/// its other consumers (an answer's projections and status) make it answer
/// state, not listener state.
pub const ListenerList = struct {
    entries: std.ArrayList(ListenerEntry) = .empty,

    pub const empty: ListenerList = .{};

    pub fn len(self: *const ListenerList) usize {
        return self.entries.items.len;
    }

    /// Append `listener` (a POD entry, nothing to free on failure).
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
    /// empty slice when there are none. The caller frees only the slice (the
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
    /// resolve and tear the session down. A stamp that does not match
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

/// A queued call retains its exact reply incarnation alongside the owned message.
/// Resolver-only calls have no wire answer position. This metadata prevents
/// reusing their callback capability or wire position from aliasing replies. It
/// shares the existing bounded queue allocation and dies with the queued call.
pub const QueuedCall = struct {
    message: model.Message,
    answer: ?AnswerTarget = null,
    /// Original wire mentions survive shortening and transfer to a local event
    /// or the forwarding drain's GC, independently of rewritten arguments.
    introduced_far_imports: ?[]model.ImportPosition = null,
    reference_slots: ?u32 = null,

    pub fn deinit(self: QueuedCall, allocator: std.mem.Allocator) void {
        model.freeMessage(allocator, self.message);
        if (self.introduced_far_imports) |imports| allocator.free(imports);
    }
};

/// Cold pipelining payload for an answer (ADR-0007), allocated lazily when
/// an answer acquires a queued call, listener, projection or stored resolution.
pub const AnswerPayload = struct {
    /// Whether releasing this answer's wire name would drop work already
    /// accepted for it: a staged settlement or carrier reference, a V1.0
    /// resolver callback, queued pipelined calls, listeners, or projections.
    pub fn hasConsequences(self: *const AnswerPayload) bool {
        return self.refs > 1 or self.resolver_import != null or self.hasAnchoredWork();
    }

    /// Whether settlement has local work to drain: queued pipelined calls,
    /// listeners, or projections anchored while the answer was pending.
    pub fn hasAnchoredWork(self: *const AnswerPayload) bool {
        return self.queue.items.len != 0 or self.listeners.len() != 0 or
            self.projections.items.len != 0;
    }

    /// One reference belongs to the live answer row. A staged settlement and
    /// each queued notification carrier retain another reference so
    /// `op:gc-answers` can release/reuse the pipelining name without cancelling
    /// a resolver or listener that was already accepted for this incarnation.
    refs: u32 = 1,
    /// Pipelined `op:deliver`s that arrived for this answer while it was still
    /// `pending`. FIFO. Each is an owned `model.Message` freed on drain or
    /// removal.
    queue: std.ArrayList(QueuedCall) = .empty,
    /// Parties listening for this answer's resolution (POD entries).
    listeners: ListenerList = .empty,
    /// `op:get` / `op:index` projections waiting on this answer's resolution
    /// (ADR-0050). Each entry's `.field` bytes are owned. Freed on drain or
    /// removal.
    projections: std.ArrayList(Projection) = .empty,
    /// The resolution, stored once the answer resolves so a late `op:listen`
    /// fires immediately. Owned. Freed on removal.
    resolution: ?StoredResolution = null,
    /// Exact owned-model charge paired with `resolution`. Session aggregates
    /// it so a succession of published answers cannot hide variable retained
    /// trees behind the fixed answer-row cap.
    resolution_charge: usize = 0,
    /// Exact callback import retains; final payload release queues their GC.
    imported_result: ?*@import("../import_release_outbox.zig").Batch = null,
    /// V1.0's independently accepted resolver callback. The BiMap remains the
    /// live answer-name index. This captured import is the detached obligation
    /// that survives removal and legal reuse of that name.
    resolver_import: ?model.ImportPosition = null,
};

/// Session-local identity of one inbound answer incarnation. `AnswerName`
/// carries the wire/virtual namespace. `row_id` carries the epoch. Application
/// work must return this whole token so a late result cannot settle a new
/// question that reused the same wire position.
pub const AnswerTarget = struct {
    name: model.AnswerName,
    row_id: u64,
};

/// One owned resolution plus the exact answer behind a same-peer promise.
/// Wire answers and paired local exports share this captured identity, so later
/// consequence walks neither notify early nor follow a replacement row.
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
    rows: foundation.identity_hash.MapOf(.wire, u64, DetachedAnswer),
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
    /// Next permits one shortening and one settling wire subscription per
    /// question incarnation, including the inline deliver subscription.
    sent_listen_modes: u2 = 0,
    /// The application consumed or discarded the one-shot notification. Wire
    /// settlement can precede notification, so answer_status cannot own this
    /// guard. Meaningless on inbound rows. Retired rows need no marker.
    application_notification_consumed: bool = false,
    payload: ?*AnswerPayload = null,
    /// Next-profile local settling fan-out. The target import owns the ordered
    /// answer list. This back-link makes `op:gc-answers` removal O(1) without a
    /// scan of every imported promise. `settling_index == 0` names the inline
    /// primary answer, larger values are one-based indexes into its followers.
    settling_target: model.ImportPosition = .from(0),
    settling_index: usize = 0,
    has_settling_target: bool = false,
    /// The local export whose settlement callback is this answer: on an
    /// outbound row, the resolver the partner delivers to when it settles
    /// the answer (ADR-0010, ADR-0095); on a local promise's virtual inbound
    /// row, the projection export that names it. The export's own row says
    /// what the export is for (`ExportRow.purpose`), and this is how the
    /// answer side finds it without a reverse row (ADR-0254).
    /// `.from(0)` under a clear flag is none, as for `settling_target`.
    resolver_export: model.ExportPosition = .from(0),
    has_resolver_export: bool = false,

    pub fn initPending(row_id: u64) AnswerCell {
        return .{ .row_id = row_id };
    }

    pub fn resolverExport(self: *const AnswerCell) ?model.ExportPosition {
        return if (self.has_resolver_export) self.resolver_export else null;
    }

    pub fn setResolverExport(self: *AnswerCell, position: model.ExportPosition) void {
        self.resolver_export = position;
        self.has_resolver_export = true;
    }

    pub fn clearResolverExport(self: *AnswerCell) void {
        self.resolver_export = .from(0);
        self.has_resolver_export = false;
    }

    /// CapTP answer status.
    pub fn status(self: *const AnswerCell) AnswerStatus {
        return self.answer_status;
    }

    /// Settle a pending cell the way `resolution` says, whichever resolution
    /// type (owned, view, or its tag) names it. Settling twice is a session bug.
    pub fn settle(self: *AnswerCell, resolution: anytype) void {
        std.debug.assert(self.answer_status == .pending);
        self.answer_status = switch (resolution) {
            .fulfill => .fulfilled,
            .@"break" => .broken,
        };
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

/// Inbound answers: the questions the partner asked, at positions it chose,
/// hashed under the session's secret multiplier (ADR-0223).
pub const InboundAnswerTable = struct {
    rows: foundation.identity_hash.MapOf(.wire, model.AnswerName, AnswerCell),

    pub const Id = model.AnswerName;

    pub fn keyed(multiplier: u64) InboundAnswerTable {
        return .{ .rows = .keyed(multiplier) };
    }

    /// Key an empty table under the session's secret.
    pub fn keyWire(self: *InboundAnswerTable, multiplier: u64) void {
        self.rows.keyWire(multiplier);
    }

    pub fn deinit(self: *InboundAnswerTable, allocator: std.mem.Allocator) void {
        var it = self.rows.valueIterator();
        while (it.next()) |cell| _ = deinitAnswerCell(allocator, cell);
        self.rows.deinit(allocator);
    }

    pub fn getPtr(self: *const InboundAnswerTable, position: Id) ?*AnswerCell {
        return self.rows.getPtr(position);
    }

    pub fn contains(self: *const InboundAnswerTable, position: Id) bool {
        return self.rows.contains(position);
    }

    pub fn count(self: *const InboundAnswerTable, position: Id) u64 {
        if (self.rows.getPtr(position)) |cell| return cell.count;
        return 0;
    }

    pub fn len(self: *const InboundAnswerTable) usize {
        return self.rows.count();
    }

    pub fn put(self: *InboundAnswerTable, allocator: std.mem.Allocator, position: Id, cell: AnswerCell) !void {
        try self.rows.put(allocator, position, cell);
    }

    pub fn ensureUnusedCapacity(self: *InboundAnswerTable, allocator: std.mem.Allocator, additional: u32) !void {
        try self.rows.ensureUnusedCapacity(allocator, additional);
    }

    pub fn putAssumeCapacity(self: *InboundAnswerTable, position: Id, cell: AnswerCell) void {
        self.rows.putAssumeCapacity(position, cell);
    }

    pub fn remove(self: *InboundAnswerTable, position: Id) void {
        // idempotent: this wrapper's contract is ensure-gone; callers remove a
        // position without knowing (or caring) whether a row was present.
        _ = self.rows.remove(position);
    }
};

pub const OutboundAnswerTable = @import("outbound_table.zig").OutboundAnswerTable;
pub const OutboundAnswerTarget = @import("outbound_table.zig").OutboundAnswerTarget;

pub fn ensureAnswerPayload(allocator: std.mem.Allocator, cell: *AnswerCell) !*AnswerPayload {
    if (cell.payload) |payload| return payload;
    const payload = try allocator.create(AnswerPayload);
    payload.* = .{};
    cell.payload = payload;
    return payload;
}

/// An exact pending-answer payload prepared for one wider transaction. A cold
/// live row receives a fresh empty payload immediately. This token remains its
/// sole publication owner until commit and removes it on abandon. Detached rows
/// can only be prepared when their already-owned payload still exists.
pub const PreparedPendingPayload = struct {
    target: AnswerTarget,
    payload: *AnswerPayload,
    owns_fresh: bool,

    pub fn abandon(self: *PreparedPendingPayload, owner: *Session) void {
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

pub fn preparePendingPayloadTarget(self: *Session, target: AnswerTarget) !PreparedPendingPayload {
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
    if (payload.imported_result) |batch| batch.ready();
    for (payload.queue.items) |call| call.deinit(allocator);
    payload.queue.deinit(allocator);
    payload.listeners.deinit(allocator);
    for (payload.projections.items) |projection| deinitProjection(allocator, projection);
    payload.projections.deinit(allocator);
    if (payload.resolution) |resolution| model.freeResolution(allocator, resolution.value);
    allocator.destroy(payload);
    return resolution_charge;
}

fn freeAnswerPayload(allocator: std.mem.Allocator, payload_ptr: *?*AnswerPayload) usize {
    const payload = payload_ptr.* orelse return 0;
    payload_ptr.* = null;
    return releaseAnswerPayload(allocator, payload);
}

pub fn deinitAnswerCell(allocator: std.mem.Allocator, cell: *AnswerCell) usize {
    return freeAnswerPayload(allocator, &cell.payload);
}
