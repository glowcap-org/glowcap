//! A call-owned working set driven by the attachment's existing read lane.
//! The portrait lease and retained arguments remain valid through deinit.
const core = @import("loam_core");

pub const Preparation = struct {
    context: *anyopaque,
    advanceFn: *const fn (*anyopaque) anyerror!Step,
    completeFn: *const fn (*anyopaque, core.Ticket, core.ReadResult) anyerror!void,
    deinitFn: *const fn (*anyopaque) void,
    pub const Step = union(enum) { ready, read: core.Read, waiting };

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
