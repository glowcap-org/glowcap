//! C-owned projection state for one Runtime listener identity.

const shared = @import("c_abi_shared");
const std = @import("std");

pub const Bound = struct {
    projection: shared.locator_adapter.Projection,

    pub fn deinit(self: *Bound, inst: anytype) void {
        self.projection.deinit(inst.allocator);
    }
};

pub const State = union(enum) {
    pending,
    active: Bound,
    /// Close has committed in HostRuntime and provider stop is still pending.
    /// The locator projection is already gone. Only listener_close may retry.
    closing,
    /// Zig stop completed after an earlier WOULD_BLOCK. The retrying C
    /// caller owns final id retirement. No locator projection remains.
    retired,

    /// Retire owned projection state. False names an impossible surviving
    /// pending setup so loop release can report the violated barrier.
    pub fn deinit(self: *State, inst: anytype) bool {
        return switch (self.*) {
            .pending => false,
            .active => |*active| blk: {
                active.deinit(inst);
                break :blk true;
            },
            .closing, .retired => true,
        };
    }
};

pub const ActiveLookupError = error{ UnknownListener, ListenerPending, ListenerClosing };

pub fn lookupActive(inst: anytype, listener: u64) ActiveLookupError!*Bound {
    const state = inst.listeners.getPtr(@fromBackingInt(@intCast(listener))) orelse {
        shared.setLastError("driver: unknown listener id", .{});
        return error.UnknownListener;
    };
    return switch (state.*) {
        .pending => {
            shared.setLastError("driver: listener setup is pending", .{});
            return error.ListenerPending;
        },
        .active => |*bound| bound,
        .closing => {
            shared.setLastError("driver: listener close is pending", .{});
            return error.ListenerClosing;
        },
        .retired => {
            shared.setLastError("driver: listener is retired", .{});
            return error.UnknownListener;
        },
    };
}

pub fn markClosing(inst: anytype, tag: u64) void {
    const state = inst.listeners.getPtr(@fromBackingInt(@intCast(tag))) orelse {
        inst.runtime.noteTerminalFailure(error.ProviderContract);
        return;
    };
    switch (state.*) {
        .active => |*active| active.deinit(inst),
        .closing => return,
        .pending, .retired => {
            inst.runtime.noteTerminalFailure(error.ProviderContract);
            return;
        },
    }
    state.* = .closing;
}

pub fn remove(inst: anytype, tag: u64) bool {
    const removed = inst.listeners.fetchRemove(@fromBackingInt(@intCast(tag))) orelse return false;
    var state = removed.value;
    _ = state.deinit(inst);
    return true;
}

pub fn abandon(inst: anytype, tag: u64) void {
    if (!remove(inst, tag)) {
        inst.runtime.noteTerminalFailure(error.ProviderContract);
    }
    releaseReservation(inst);
}

pub fn retire(inst: anytype, tag: u64) void {
    const state = inst.listeners.getPtr(@fromBackingInt(@intCast(tag))) orelse {
        inst.runtime.noteTerminalFailure(error.ProviderContract);
        releaseReservation(inst);
        return;
    };
    switch (state.*) {
        .active => |*active| active.deinit(inst),
        .closing => {},
        .pending, .retired => inst.runtime.noteTerminalFailure(error.ProviderContract),
    }
    state.* = .retired;
    releaseReservation(inst);
}

fn releaseReservation(inst: anytype) void {
    std.debug.assert(inst.event_reservations != 0);
    inst.event_reservations -= 1;
}
