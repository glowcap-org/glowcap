//! Export/answer pairing for a Host-local promise projected onto one session.
//!
//! The export is the partner-visible promise reference. The virtual inbound
//! answer is its settlement and pipelining cell. The answer row and export
//! purpose link their identities because CapTP allocates the namespaces independently.

const std = @import("std");
const model = @import("model");
const answers = @import("answers/store.zig");
const session = @import("mod.zig");

const Session = session.Session;

/// Collection waits while an engine drain owns temporarily detached values.
pub const CollectionState = enum { active, deferred };

/// Named cost: one cold box per Session while it has local promise
/// projections, plus one position per projection. Null otherwise, so a
/// Session that never projects a local promise pays one pointer. The list lets
/// collection visit projections without scanning the shared resolver map or
/// partner-sized answer tables. Each projection spends one inbound-answer
/// obligation, bounded by SessionLimits.max_inbound_answers, and a projection
/// nothing holds keeps spending it until the next trace reclaims it
/// (`local_promise_gc.collect` paces the traces). Freed with the last
/// projection or at teardown.
pub const Registry = struct {
    state: CollectionState = .active,
    projections: std.ArrayListUnmanaged(model.ExportPosition) = .empty,
    /// Projections whose stored settlement still owes its carrier
    /// (`settlement_deferred`). Nonzero makes the Peer's step retry one, and
    /// zero lets `deferredSettlement` answer without a scan.
    deferred: u32 = 0,
    /// Collections since the last trace, the pacing the collector reads.
    collects_since_trace: u32 = 0,
};

pub const Projection = struct {
    export_position: model.ExportPosition,
    answer_name: model.AnswerName,
    answer_target: answers.AnswerTarget,
};

pub fn allocate(self: *Session) !Projection {
    const created = self.local_promises == null;
    if (created) {
        const registry = try self.allocator.create(Registry);
        registry.* = .{};
        self.local_promises = registry;
    }
    errdefer if (created) destroyRegistry(self);
    const registry = self.local_promises.?;
    try registry.projections.ensureUnusedCapacity(self.allocator, 1);
    const export_position = try self.allocatePromiseExport();
    errdefer self.releaseUnsharedExport(export_position);
    const answer = try self.allocateInboundAnswer();
    const answer_name = model.AnswerName.fromVirtual(answer);
    try self.installInboundAnswerNamed(answer_name);
    errdefer self.abandonUnsharedInboundAnswerNamed(answer_name);
    // `installInboundAnswerNamed` above put the row in this dispatch. Its
    // payload is created now, so a guaranteed settlement under allocation
    // pressure (a Node's escrowed break) stores without allocating.
    const row = self.inbound_answers.getPtr(answer_name) orelse unreachable;
    _ = try answers.ensureAnswerPayload(self.allocator, row);
    self.exports.setPurpose(export_position, .{ .local_promise_answer = .{ .answer = answer } });
    registry.projections.appendAssumeCapacity(export_position);
    row.setResolverExport(export_position);
    return .{
        .export_position = export_position,
        .answer_name = answer_name,
        .answer_target = self.answerTargetNamed(answer_name).?,
    };
}

pub fn answerForExport(self: *Session, export_position: model.ExportPosition) ?model.AnswerName {
    const purpose = self.exports.purpose(export_position) orelse return null;
    return switch (purpose) {
        .local_promise_answer => |answer| answer.name(),
        else => null,
    };
}

/// Capture the exact answer behind a local promise export named in a
/// resolution this session sends. The export's live slot and its explicit
/// pairing own that meaning. An answer reference has no chain target here:
/// `validate/passable.zig` refuses one in a sent resolution.
pub fn targetForResolution(self: *Session, resolution: model.Resolution) !?answers.AnswerTarget {
    if (resolution != .fulfill or resolution.fulfill != .reference) return null;
    const near = switch (resolution.fulfill.reference) {
        .near => |near| near,
        else => return null,
    };
    const cell = self.exportSlot(near.export_position) orelse return null;
    if (cell != .local_unresolved) return null;
    const name = answerForExport(self, near.export_position) orelse return null;
    return self.answerTargetNamed(name) orelse error.InvalidReference;
}

pub fn isAnswer(self: *Session, answer_name: model.AnswerName) bool {
    return projectionExport(self, answer_name) != null;
}

/// The projection export paired with `answer_name`, read from its row.
pub fn projectionExport(self: *Session, answer_name: model.AnswerName) ?model.ExportPosition {
    const row = self.inbound_answers.getPtr(answer_name) orelse return null;
    const export_position = row.resolverExport() orelse return null;
    std.debug.assert(answerForExport(self, export_position) != null);
    return export_position;
}

/// Roll back a projection that never became observable: the Host's projection
/// rollback and the Node's proxy-recipient abandon and withdraw. Each found
/// the row it minted through `allocate` in the same record, so it is present.
pub fn abandon(self: *Session, export_position: model.ExportPosition) void {
    const answer_name = answerForExport(self, export_position) orelse unreachable;
    const purpose = self.exports.clearPurpose(export_position) orelse unreachable;
    std.debug.assert(!purpose.local_promise_answer.settlement_deferred);
    self.abandonUnsharedInboundAnswerNamed(answer_name);
    self.releaseUnsharedExport(export_position);
    const registry = self.local_promises.?;
    for (registry.projections.items, 0..) |position, index| {
        if (position != export_position) continue;
        std.debug.assert(registry.projections.swapRemove(index) == export_position);
        break;
    } else unreachable;
    collect(self);
}

/// Mark the projection behind `target` as holding a stored settlement whose
/// carrier outbound pressure refused. The Peer retries it from
/// `deferredSettlement`.
pub fn deferSettlement(self: *Session, target: answers.AnswerTarget) void {
    const export_position = projectionExport(self, target.name) orelse unreachable;
    const purpose = self.exports.purposePtr(export_position) orelse unreachable;
    std.debug.assert(!purpose.local_promise_answer.settlement_deferred);
    purpose.local_promise_answer.settlement_deferred = true;
    self.local_promises.?.deferred += 1;
}

/// One projection whose settlement carrier is still owed, or null. A deferred
/// projection is never collected (`local_promise_gc`), so the count is exact
/// and the scan runs only while one is owed.
pub fn deferredSettlement(self: *Session) ?Projection {
    const registry = self.local_promises orelse return null;
    if (registry.deferred == 0) return null;
    for (registry.projections.items) |position| {
        const purpose = self.exports.purposePtr(position) orelse unreachable;
        if (!purpose.local_promise_answer.settlement_deferred) continue;
        const answer_name = purpose.local_promise_answer.name();
        return .{
            .export_position = position,
            .answer_name = answer_name,
            .answer_target = self.answerTargetNamed(answer_name) orelse unreachable,
        };
    }
    unreachable;
}

/// The owed carrier for `export_position` is queued.
pub fn clearDeferredSettlement(self: *Session, export_position: model.ExportPosition) void {
    const purpose = self.exports.purposePtr(export_position) orelse unreachable;
    std.debug.assert(purpose.local_promise_answer.settlement_deferred);
    purpose.local_promise_answer.settlement_deferred = false;
    const registry = self.local_promises.?;
    std.debug.assert(registry.deferred != 0);
    registry.deferred -= 1;
}

pub fn destroyRegistry(self: *Session) void {
    const registry = self.local_promises orelse return;
    registry.projections.deinit(self.allocator);
    self.allocator.destroy(registry);
    self.local_promises = null;
}

pub const collect = @import("local_promise_gc.zig").collect;
pub const collectNow = @import("local_promise_gc.zig").collectNow;
pub const min_trace_interval = @import("local_promise_gc.zig").min_trace_interval;
pub const collectAtAnswerCap = @import("local_promise_gc.zig").collectAtAnswerCap;

/// Temporary custody of local references before a Node-staged payload records
/// its Session mentions. This retain is local ownership, never a wire grant.
/// The Node acquires through its existing inventory and returns each retain
/// before publication or when the adopted payload rolls back or is torn down.
pub const Custody = struct {
    /// A synchronous owner temporarily holds trees outside Session stores.
    /// Only the outermost pause resumes collection after those trees transfer
    /// or retire. Sessions without local projections keep their inactive path.
    pub const CollectionPause = struct {
        resumes: bool,

        pub fn deinit(self: CollectionPause, owner: *Session) void {
            if (!self.resumes) return;
            // Collection alone frees the registry, and it waits while deferred.
            const registry = owner.local_promises.?;
            std.debug.assert(registry.state == .deferred);
            registry.state = .active;
            collect(owner);
        }
    };

    pub fn pauseCollection(owner: *Session) CollectionPause {
        const registry = owner.local_promises orelse return .{ .resumes = false };
        const resumes = registry.state == .active;
        if (resumes) registry.state = .deferred;
        return .{ .resumes = resumes };
    }

    pub fn retain(owner: *Session, reference: model.Reference) error{QueueCapExceeded}!void {
        if (reference != .near) return;
        const purpose = owner.exports.purposePtr(reference.near.export_position) orelse return;
        if (purpose.* != .local_promise_answer) return;
        const count = &purpose.local_promise_answer.staging_owners;
        count.* = std.math.add(u32, count.*, 1) catch return error.QueueCapExceeded;
    }

    pub fn release(owner: *Session, reference: model.Reference) void {
        if (reference != .near) return;
        // A failed turn may revoke its fresh, unshared Host projection before
        // withdrawing the provisional Node payload. Turn abort is synchronous:
        // that payload cannot publish, and its later custody release is spent.
        const purpose = owner.exports.purposePtr(reference.near.export_position) orelse return;
        if (purpose.* != .local_promise_answer) return;
        const count = &purpose.local_promise_answer.staging_owners;
        std.debug.assert(count.* != 0);
        count.* -= 1;
    }
};
