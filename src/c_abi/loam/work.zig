//! A submitted effect retains borrowed effect memory until its worker retires.
const common = @import("common.zig");
const attached = @import("attachment.zig");
const core = common.core;
pub const Worker = common.hosting.Worker;
pub const Request = Worker.Request;
pub const Result = Worker.Result;

/// The C handle for one `Worker.Slot`. The attachment's worker owns slot
/// selection, the recovery exclusion, installation, and retirement. The handle
/// adds the off-thread plan/finish state. Fixed slots charge attachment
/// initialization, never individual I/O. An active slot and its borrowed batch
/// cannot be reused until the executor retires, completion consumes it, and
/// the caller releases the handle. As with other C handles, using a released
/// pointer is outside the contract. Core tickets retain incarnation, revision
/// and sequence checks independently.
pub const Work = struct {
    owner: *attached.Attachment,
    slot: *Worker.Slot,
    planned: ?Result = null,
    evaluation: ?core.Batch.Evaluation = null,
    pub fn next(owner: *attached.Attachment, force_recovery: bool) !?*Work {
        const slot = try owner.worker.next(owner.value, force_recovery) orelse return null;
        const work = &owner.work_slots[owner.worker.indexOf(slot).?];
        work.* = .{ .owner = owner, .slot = slot };
        if (slot.request == .write) work.evaluation = core.Batch.Evaluation.init(&slot.request.write);
        return work;
    }
    pub fn complete(self: *Work) !void {
        try self.owner.worker.complete(self.slot, self.owner.value);
    }
    pub fn destroy(self: *Work) !void {
        try self.owner.worker.release(self.slot);
        self.planned = null;
        self.evaluation = null;
    }
};
pub fn from(raw: ?*common.c.GlowcapLoamWork) !*Work {
    const work: *Work = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!work.slot.active) return error.StaleCompletion;
    try common.EvaluationGuard.check(work.owner.store);
    return work;
}
