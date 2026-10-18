//! One active C relay listener's projected locator, lifecycle flags, and
//! claim-once terminal failure. Registration/retry remains owned by RawListener.

const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const net = @import("net");

pub fn State(comptime Runtime: type) type {
    return struct {
        const Self = @This();

        runtime: *Runtime,
        raw: net.relay.RawListener,
        locator: model.PeerLocator,
        route_id: u64,
        io_mutex: net.sync.SpinLock = .{},
        stopped: std.atomic.Value(bool) = .init(false),
        closed: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        retired: std.atomic.Value(bool) = .init(false),
        events: std.atomic.Value(u32) = .init(0),
        failure_mutex: net.sync.SpinLock = .{},
        failure: ?foundation.FailureChain = null,

        pub fn noteFailure(self: *Self, later: foundation.FailureChain) void {
            self.failure_mutex.lock();
            defer self.failure_mutex.unlock();
            foundation.latchFailure(&self.failure, later);
        }

        pub fn claimFailure(self: *Self) ?foundation.FailureChain {
            self.failure_mutex.lock();
            defer self.failure_mutex.unlock();
            const failure = self.failure;
            self.failure = null;
            return failure;
        }
    };
}

pub fn Setup(comptime Runtime: type, comptime Listener: type) type {
    return struct {
        runtime: *Runtime,
        raw: ?net.relay.RawListener,
        route_id: u64,
        state: Phase = .running,
        failure: ?net.netlayer.ListenFailure = null,
        listener: ?*Listener = null,
        announced: bool = false,

        pub const Phase = enum { running, succeeded, failed, cancelled, retired };
    };
}
