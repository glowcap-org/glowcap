//! What the core-retry tests share: a completion sink the test scripts, rigs
//! with a deterministic clock, and the refusals they provoke.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const driver_core = driver.core;
const HostRuntime = driver.HostRuntime;
const Rig = @import("pressure_rig.zig").Rig;

pub const retry_ms = HostRuntime.testing.memory_retry_ms;

/// The completion sink: what it does on `reserve`, and what it saw.
pub const Sink = struct {
    const Mode = enum { ok, oom, refused };

    runtime: *HostRuntime,
    mode: Mode = .ok,
    reserves: usize = 0,
    takes: usize = 0,
    releases: usize = 0,
    /// `driver_depth` when the last reservation ran.
    depth_seen: usize = 0,
    /// Called inside `reserve`, before it answers.
    on_reserve: ?*const fn (*Sink) void = null,
    /// A test's own pointer for its hooks.
    probe_ctx: ?*anyopaque = null,
    /// Called inside `take`, after it counts.
    on_take: ?*const fn (*Sink) void = null,
    /// Re-enters the runtime from inside this callback, once, and keeps the
    /// result: a step, or the public `drainActions` when `probe_drain` is set.
    probe_in: ?Callback = null,
    probe_drain: bool = false,
    reentry: ?anyerror = null,

    pub const Callback = enum { reserve, take, release };

    fn of(ctx: *anyopaque) *Sink {
        return @ptrCast(@alignCast(ctx));
    }

    fn probe(self: *Sink, which: Callback) void {
        if (self.probe_in != which) return;
        self.probe_in = null;
        if (self.probe_drain) {
            self.reentry = if (self.runtime.drainActions()) |_| null else |err| err;
        } else {
            self.reentry = if (self.runtime.stepAny(0)) |_| null else |err| err;
        }
    }

    fn reserve(ctx: *anyopaque) anyerror!void {
        const self = of(ctx);
        self.reserves += 1;
        self.depth_seen = self.runtime.driver_depth;
        self.probe(.reserve);
        if (self.on_reserve) |hook| hook(self);
        switch (self.mode) {
            .ok => {},
            .oom => return error.OutOfMemory,
            .refused => return error.SinkRefused,
        }
    }

    fn release(ctx: *anyopaque) void {
        const self = of(ctx);
        self.releases += 1;
        self.probe(.release);
    }

    fn take(ctx: *anyopaque, _: driver_core.HostAction) bool {
        const self = of(ctx);
        self.takes += 1;
        self.probe(.take);
        if (self.on_take) |hook| hook(self);
        return false;
    }

    pub fn install(self: *Sink) void {
        self.runtime.drive.stepped.completion_sink = .{
            .ctx = self,
            .reserve = reserve,
            .release = release,
            .take = take,
        };
    }
};

pub fn buildRig() !*Rig {
    return Rig.build(std.testing.allocator, .{ .fetches = 0, .clock_step_ns = std.time.ns_per_us });
}

/// Leave one completion for the next drain: a fetch no answer will settle, then
/// the partner's clean end, which breaks it.
pub fn breakPendingFetch(rig: *Rig) !void {
    _ = try rig.runtime.core.fetch(rig.session, "treasure");
    rig.resident.read_result = 0;
    rig.resident.read_armed = true;
    rig.resident.signal_closed = true;
}

pub fn expectArmed(runtime: *HostRuntime) !i64 {
    const due = runtime.core.memory_retry_due_ms orelse return error.NotArmed;
    try std.testing.expect(runtime.terminal_failure == null);
    return due;
}

/// A held-release flush that refuses memory, and one that sends nothing.
pub const FlushOom = struct {
    pub var calls: usize = 0;
    pub fn flush(_: *driver_core.Host) !bool {
        calls += 1;
        return error.OutOfMemory;
    }
};
pub const FlushFail = struct {
    pub var calls: usize = 0;
    pub fn flush(_: *driver_core.Host) !bool {
        calls += 1;
        return error.ProviderInternal;
    }
};
pub const FlushIdle = struct {
    pub var calls: usize = 0;
    pub fn flush(_: *driver_core.Host) !bool {
        calls += 1;
        return false;
    }
};

/// Queue one completion without a step: the session's cancel breaks its
/// pending fetch, so the next drain meets a `.failed` action.
pub fn queueCompletion(rig: *Rig) !void {
    _ = try rig.runtime.core.fetch(rig.session, "treasure");
    try rig.runtime.core.beginSessionClose(rig.session, .cancel, rig.runtime.nowMs());
    try std.testing.expect(rig.runtime.core.hasRunnableWork());
}
