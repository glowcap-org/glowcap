//! Export/answer pairing for a Host-local promise projected onto one session.
//!
//! The export is the partner-visible promise reference. The virtual inbound
//! answer is its settlement and pipelining cell. Their explicit BiMap link is
//! the authority because CapTP allocates those namespaces independently.

const std = @import("std");
const model = @import("model");
const answers = @import("answers/store.zig");

/// Collection waits while an engine drain owns temporarily detached values.
pub const CollectionState = enum { active, deferred };

/// Named cost: one cold box per Session while it has local promise
/// projections, plus one position per projection. Null otherwise, so a
/// Session that never projects a local promise pays one pointer. The list lets
/// collection visit projections without scanning the shared resolver map or
/// partner-sized answer tables. Each projection spends one inbound-answer
/// obligation, bounded by SessionLimits.max_inbound_answers. Freed with the
/// last projection or at teardown.
pub const Registry = struct {
    state: CollectionState = .active,
    projections: std.ArrayListUnmanaged(model.ExportPosition) = .empty,
};

pub const Projection = struct {
    export_position: model.ExportPosition,
    answer_name: model.AnswerName,
    answer_target: answers.AnswerTarget,
};

pub fn allocate(self: anytype) !Projection {
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
    const answer_name = model.AnswerName.fromVirtual(try self.allocateInboundAnswer());
    try self.installInboundAnswerNamed(answer_name);
    errdefer self.abandonUnsharedInboundAnswerNamed(answer_name);
    try self.outbound_resolver_link.put(self.allocator, export_position, .{
        .local_promise_answer = .{ .name = answer_name },
    });
    registry.projections.appendAssumeCapacity(export_position);
    return .{
        .export_position = export_position,
        .answer_name = answer_name,
        .answer_target = self.answerTargetNamed(answer_name).?,
    };
}

pub fn answerForExport(self: anytype, export_position: model.ExportPosition) ?model.AnswerName {
    const purpose = self.outbound_resolver_link.getByKey(export_position) orelse return null;
    return switch (purpose) {
        .local_promise_answer => |answer| answer.name,
        else => null,
    };
}

/// Capture the exact answer behind either spelling of a same-peer promise.
/// A local export's live slot and explicit pairing own its meaning; descriptor
/// kind or numeric coincidence with an answer cannot establish that authority.
pub fn targetForResolution(self: anytype, resolution: model.Resolution) !?answers.AnswerTarget {
    if (resolution != .fulfill or resolution.fulfill != .reference) return null;
    const name: model.AnswerName = switch (resolution.fulfill.reference) {
        .promise => |promise| .fromWire(promise.answer_position),
        .near => |near| blk: {
            const cell = self.exportSlot(near.export_position) orelse return null;
            if (cell != .local_unresolved) return null;
            break :blk answerForExport(self, near.export_position) orelse return null;
        },
        else => return null,
    };
    return self.answerTargetNamed(name) orelse error.InvalidReference;
}

pub fn isAnswer(self: anytype, answer_name: model.AnswerName) bool {
    return self.outbound_resolver_link.getByValue(.{
        .local_promise_answer = .{ .name = answer_name },
    }) != null;
}

pub fn abandon(self: anytype, export_position: model.ExportPosition) void {
    // Presence is certain because the only caller is the driver projection
    // rollback (`projection.rollback`), which found the projection row it
    // minted through `projection.prepare` in the same record.
    const answer_name = answerForExport(self, export_position) orelse unreachable;
    std.debug.assert(self.outbound_resolver_link.removeByKey(export_position));
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

pub fn destroyRegistry(self: anytype) void {
    const registry = self.local_promises orelse return;
    registry.projections.deinit(self.allocator);
    self.allocator.destroy(registry);
    self.local_promises = null;
}

pub const collect = @import("local_promise_gc.zig").collect;

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

        pub fn deinit(self: CollectionPause, owner: anytype) void {
            if (!self.resumes) return;
            // Collection alone frees the registry, and it waits while deferred.
            const registry = owner.local_promises.?;
            std.debug.assert(registry.state == .deferred);
            registry.state = .active;
            collect(owner);
        }
    };

    pub fn pauseCollection(owner: anytype) CollectionPause {
        const registry = owner.local_promises orelse return .{ .resumes = false };
        const resumes = registry.state == .active;
        if (resumes) registry.state = .deferred;
        return .{ .resumes = resumes };
    }

    pub fn retain(owner: anytype, reference: model.Reference) error{QueueCapExceeded}!void {
        if (reference != .near) return;
        const purpose = owner.outbound_resolver_link.forward.getPtr(reference.near.export_position) orelse return;
        if (purpose.* != .local_promise_answer) return;
        const count = &purpose.local_promise_answer.staging_owners;
        count.* = std.math.add(u32, count.*, 1) catch return error.QueueCapExceeded;
    }

    pub fn release(owner: anytype, reference: model.Reference) void {
        if (reference != .near) return;
        // A failed turn may revoke its fresh, unshared Host projection before
        // withdrawing the provisional Node payload. Turn abort is synchronous:
        // that payload cannot publish, and its later custody release is spent.
        const purpose = owner.outbound_resolver_link.forward.getPtr(reference.near.export_position) orelse return;
        if (purpose.* != .local_promise_answer) return;
        const count = &purpose.local_promise_answer.staging_owners;
        std.debug.assert(count.* != 0);
        count.* -= 1;
    }
};
