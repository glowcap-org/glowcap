//! A submitted effect retains borrowed effect memory until its worker retires.
const common = @import("common.zig");
const attached = @import("attachment.zig");
const core = common.core;
pub const Request = union(enum) { read: core.Read, write: core.Batch, lookup: core.NameLookup, recover: core.Batch };
pub const Result = union(enum) { read: core.ReadResult, write: core.Outcome, lookup: core.NameResult, recover: core.Resolution, failed: anyerror };

/// Fixed worker slots charge attachment initialization, never individual I/O.
/// An active slot and its borrowed batch cannot be reused until the executor
/// retires, completion consumes it, and the caller releases the handle. As
/// with other C handles, using a released pointer is outside the contract.
/// Core tickets retain incarnation, revision and sequence checks independently.
pub const Work = struct {
    owner: *attached.Attachment,
    active: bool = false,
    request: Request = undefined,
    result: ?Result = null,
    planned: ?Result = null,
    completed: bool = false,
    pub fn next(owner: *attached.Attachment, force_recovery: bool) !?*Work {
        try owner.value.topLevel();
        const recovery = force_recovery or owner.store.value.phase == .uncertain;
        if (recovery and (owner.works != 0 or owner.recovery_work)) return error.Busy;
        const work = for (owner.work_slots) |*slot| {
            if (!slot.active) break slot;
        } else return error.Busy;
        const request: Request = if (recovery)
            .{ .recover = try owner.value.recoveryBatch() }
        else if (try owner.value.nextWork()) |effect| switch (effect) {
            .read => |value| .{ .read = value },
            .write => |value| .{ .write = value },
            .lookup => |value| .{ .lookup = value },
        } else return null;
        work.* = .{ .owner = owner, .active = true, .request = request };
        owner.works += 1;
        if (recovery) owner.recovery_work = true;
        return work;
    }
    pub fn complete(self: *Work) !void {
        if (self.completed) return error.StaleCompletion;
        try self.owner.value.topLevel();
        const result = self.result orelse return error.WorkerNotRetired;
        // Completion consumes the submitted worker even when the core reports
        // a read refusal or an uncertain install. A second completion is stale.
        self.completed = true;
        switch (result) {
            .read => |value| try self.owner.value.completeRead(self.request.read.ticket, value),
            .write => |value| try self.owner.value.completeWrite(self.request.write.ticket, value),
            .lookup => |value| try self.owner.value.completeLookup(self.request.lookup.ticket, value),
            .recover => |value| try self.owner.value.resolve(self.request.recover.ticket, value),
            .failed => |err| return err,
        }
    }
    pub fn destroy(self: *Work) !void {
        if (!self.completed) return error.Busy;
        self.owner.works -= 1;
        if (self.request == .recover) self.owner.recovery_work = false;
        self.active = false;
        self.result = null;
        self.planned = null;
    }
};
pub fn from(raw: ?*common.c.GlowcapLoamWork) !*Work {
    const work: *Work = @ptrCast(@alignCast(raw orelse return error.NullPointer));
    if (!work.active) return error.StaleCompletion;
    return work;
}
