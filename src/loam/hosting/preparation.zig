//! A call-owned working set driven by the attachment's existing read lane.
//! The portrait lease and retained arguments remain valid through deinit.
const core = @import("loam_core");

/// A preparation's lifecycle callbacks. Implementors are unknown at this
/// declaration, so `advanceFn` and `completeFn` keep `anyerror` return sets.
pub const Preparation = struct {
    context: *anyopaque,
    advanceFn: *const fn (*anyopaque) anyerror!Step,
    completeFn: *const fn (*anyopaque, core.Ticket, core.ReadResult) anyerror!void,
    deinitFn: *const fn (*anyopaque) void,
    pub const Step = union(enum) { ready, read: core.Read, waiting };
    /// A row for a preparation: its lease, the read to park on, or
    /// `.waiting` while the Store's room is spoken for.
    pub const Acquisition = union(enum) { ready: core.Lease, read: core.Read, waiting };

    pub fn acquire(store: *core.Store, id: core.ObjectId) !Acquisition {
        const acquired = store.acquire(id) catch |err| switch (err) {
            error.PendingRead => return .waiting,
            else => return err,
        };
        return switch (acquired) {
            .ready => |lease| .{ .ready = lease },
            .read => |read| .{ .read = read },
        };
    }

    pub fn advance(self: Preparation) !Step {
        return self.advanceFn(self.context);
    }
    /// Retires the exact read emitted by advance, including failed/stale reads.
    pub fn completeRead(self: Preparation, ticket: core.Ticket, result: core.ReadResult) !void {
        return self.completeFn(self.context, ticket, result);
    }
    /// Called only after every submitted read retires, on restart or settlement.
    pub fn deinit(self: Preparation) void {
        self.deinitFn(self.context);
    }
};
