//! Completion ownership for a blocking transport operation running away from
//! the host's stepping thread. The transport owns the task and result. This
//! state machine owns only the race between publish, claim, and cancellation.

const std = @import("std");

const WakeChannel = @import("../wake_channel.zig").WakeChannel;

pub const Completion = struct {
    wake: WakeChannel,
    state: std.atomic.Value(u8) = .init(@backingInt(State.running)),
    wake_failed: std.atomic.Value(bool) = .init(false),

    const State = enum(u8) {
        running,
        publishing,
        completed,
        abandoned,
        claimed,
    };

    pub fn init() error{WakeChannelFailed}!Completion {
        return .{ .wake = try WakeChannel.open() };
    }

    pub fn deinit(self: *Completion) void {
        self.wake.deinit();
        self.* = undefined;
    }

    pub fn readinessFd(self: *const Completion) i32 {
        return self.wake.read;
    }

    /// Publish a fully-written result. False transfers cleanup to the worker:
    /// cancellation won before or during publication, so no caller will claim
    /// the result. True leaves cleanup with `claim` or `cancel`.
    pub fn publish(self: *Completion) bool {
        if (self.state.cmpxchgStrong(
            @backingInt(State.running),
            @backingInt(State.publishing),
            .acq_rel,
            .acquire,
        )) |observed| {
            return switch (@as(State, @fromBackingInt(@intCast(observed)))) {
                .abandoned, .publishing, .completed, .claimed => false,
                .running => unreachable,
            };
        }
        _ = self.wake.nudge() catch {
            // Publication remains claimable: the caller already owns a
            // readiness descriptor and may observe its fault or cancellation.
            // The claim carries the notification failure instead of letting a
            // fully-written result masquerade as an ordinary completion.
            self.wake_failed.store(true, .release);
        };
        if (self.state.cmpxchgStrong(
            @backingInt(State.publishing),
            @backingInt(State.completed),
            .release,
            .acquire,
        )) |observed| {
            return switch (@as(State, @fromBackingInt(@intCast(observed)))) {
                .abandoned, .claimed => false,
                .running, .publishing, .completed => unreachable,
            };
        }
        return true;
    }

    /// Consume a readiness-announced result. Publication may still be in its
    /// final instruction after nudging, so claim spins only across that bounded
    /// handoff and never across network I/O.
    pub fn claim(self: *Completion) error{WakeNudgeFailed}!bool {
        while (true) switch (@as(State, @fromBackingInt(@intCast(self.state.load(.acquire))))) {
            .publishing => std.atomic.spinLoopHint(),
            .completed => if (self.state.cmpxchgWeak(
                @backingInt(State.completed),
                @backingInt(State.claimed),
                .acquire,
                .monotonic,
            ) == null) {
                if (self.wake_failed.load(.acquire)) return error.WakeNudgeFailed;
                return true;
            },
            .running, .abandoned, .claimed => return false,
        };
    }

    /// Abandon an unclaimed result. True transfers cleanup to the caller.
    /// False leaves it with the worker, which has not finished publishing.
    pub fn cancel(self: *Completion) bool {
        while (true) {
            const state: State = @fromBackingInt(@intCast(self.state.load(.acquire)));
            switch (state) {
                .running, .publishing => if (self.state.cmpxchgWeak(
                    @backingInt(state),
                    @backingInt(State.abandoned),
                    .acq_rel,
                    .acquire,
                ) == null) return false,
                .completed => if (self.state.cmpxchgWeak(
                    @backingInt(State.completed),
                    @backingInt(State.claimed),
                    .acquire,
                    .monotonic,
                ) == null) return true,
                .abandoned, .claimed => return false,
            }
        }
    }
};
