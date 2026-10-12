//! Bounded route-attempt scheduling for one pending dial.
//!
//! Identity-proving routes race in an ordered window. Weak handoff fallbacks
//! remain serial and begin only after every strong route has failed. This file
//! owns the policy as bit arithmetic. The Node owns action publication and
//! adapters own only the concrete I/O effects.

const std = @import("std");

const model = @import("model");

pub const parallel_identity_limit: usize = 2;

comptime {
    if (model.route_bundle.max_route_list_count > @bitSizeOf(u8))
        @compileError("route-attempt bitsets must cover every admitted route");
}

pub const Batch = struct {
    indices: [parallel_identity_limit]usize = undefined,
    len: usize = 0,

    pub fn slice(self: *const Batch) []const usize {
        return self.indices[0..self.len];
    }
};

pub const AfterFailure = union(enum) {
    queue: usize,
    waiting,
    exhausted,
};

pub const State = struct {
    /// Routes for which a dial action has been published at least once.
    scheduled: u8 = 0,
    /// Published routes whose action has crossed into an external executor.
    in_flight: u8 = 0,
    /// Routes whose external attempt reported a terminal refusal.
    failed: u8 = 0,

    pub fn initial(plan: model.RouteBundle) Batch {
        var batch: Batch = .{};
        const count = if (plan.identity_path_count > 1)
            @min(parallel_identity_limit, plan.identity_path_count)
        else
            1;
        for (0..count) |index| {
            batch.indices[batch.len] = index;
            batch.len += 1;
        }
        return batch;
    }

    pub fn markScheduled(self: *State, index: usize) void {
        self.scheduled |= bit(index);
    }

    pub fn begin(self: *State, index: usize) bool {
        const route = bit(index);
        if (self.scheduled & route == 0 or self.failed & route != 0 or
            self.in_flight & route != 0) return false;
        self.in_flight |= route;
        return true;
    }

    pub fn rollback(self: *State, index: usize) void {
        const route = bit(index);
        std.debug.assert(self.in_flight & route != 0);
        self.in_flight &= ~route;
    }

    pub fn losingFlights(self: State, winner: usize) u8 {
        return self.in_flight & ~bit(winner);
    }

    pub fn admitsReport(self: State, index: usize) bool {
        const route = bit(index);
        return self.scheduled & route != 0 and self.failed & route == 0;
    }

    pub fn acceptsCompletion(self: State, index: usize) bool {
        const route = bit(index);
        return self.in_flight & route != 0 and self.failed & route == 0;
    }

    pub fn previewAfterFailure(
        self: State,
        plan: model.RouteBundle,
        index: usize,
    ) AfterFailure {
        var projected = self;
        const route = bit(index);
        if (projected.scheduled & route == 0 or projected.failed & route != 0)
            return .waiting;
        projected.in_flight &= ~route;
        projected.failed |= route;

        if (index < plan.identity_path_count) {
            if (firstUnscheduled(projected, 0, plan.identity_path_count)) |route_index|
                return .{ .queue = route_index };
            if (hasOutstanding(projected, 0, plan.identity_path_count))
                return .waiting;
            if (plan.identity_path_count < plan.paths.len)
                return .{ .queue = plan.identity_path_count };
            return .exhausted;
        }

        const next_index = index + 1;
        if (next_index < plan.paths.len) return .{ .queue = next_index };
        return .exhausted;
    }

    pub fn commitFailure(self: *State, index: usize) void {
        const route = bit(index);
        std.debug.assert(self.scheduled & route != 0 and self.failed & route == 0);
        self.in_flight &= ~route;
        self.failed |= route;
    }
};

fn bit(index: usize) u8 {
    std.debug.assert(index < model.route_bundle.max_route_list_count);
    return @as(u8, 1) << @intCast(index);
}

fn firstUnscheduled(state: State, start: usize, end: usize) ?usize {
    for (start..end) |index| if (state.scheduled & bit(index) == 0) return index;
    return null;
}

fn hasOutstanding(state: State, start: usize, end: usize) bool {
    for (start..end) |index| {
        const route = bit(index);
        if (state.scheduled & route != 0 and state.failed & route == 0) return true;
    }
    return false;
}
