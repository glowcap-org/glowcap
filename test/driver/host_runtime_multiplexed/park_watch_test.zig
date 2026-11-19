//! The parking resident's watches (ADR-0060). When every resident parks, the
//! first one is handed each sibling's readiness descriptor, the settle
//! mailbox's wake, and a stepped ready set's wake. The runtime's bookkeeping is
//! a sibling count and two flags, each advanced only after the parker's `watch`
//! callback returns, so it allocates nothing. The fixtures park without
//! blocking and record every descriptor the callback is offered, and a probe
//! allocator that refuses all growth after admission shows the runtime asks
//! it for nothing. Each wait is the public `stepAny`, on both faces. The
//! callback's own `OutOfMemory` declines the optional park for that call, the
//! descriptor wait runs instead, and the next wait offers that descriptor again.
//! An empty `net.poll.testing.Script` records the raw descriptor polls the
//! syscall owner saw, so a declined park is shown to wait once, at the bound
//! the caller or the timed resident named, and a park that held shows none.

const std = @import("std");
const glowcap = @import("glowcap");
const step_harness = @import("../host_runtime_step/harness.zig");
const Probe = @import("growth_probe.zig").Probe;

const driver = glowcap.driver;
const net = glowcap.net;

const fixtures = @import("residents.zig");
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const opts = fixtures.opts;

const HostRuntime = driver.HostRuntime;
const max_attempts = 16;
const residents_max = 3;

/// A resident that parks without blocking and allocates nothing in `watch`.
/// It records every descriptor it is offered, and refuses one descriptor once
/// when armed, the way a provider whose own watch row cannot grow would.
const Parker = struct {
    inner: AcceptOwnershipResident,
    offered: [max_attempts]i32 = undefined,
    offered_count: usize = 0,
    refuse_once: ?i32 = null,
    park_calls: usize = 0,
    park_result: net.MultiplexedResident.Park = .timeout,
    /// Refuses every offer while set, as a provider out of watch capacity would.
    refuse_all: bool = false,

    const vtable = vtable: {
        var table = AcceptOwnershipResident.vtable;
        table.park = park;
        table.watch = watch;
        break :vtable table;
    };

    fn resident(self: *Parker) net.MultiplexedResident {
        return .{ .ctx = &self.inner, .vtable = &vtable };
    }

    fn of(ctx: *anyopaque) *Parker {
        const inner: *AcceptOwnershipResident = @ptrCast(@alignCast(ctx));
        return @fieldParentPtr("inner", inner);
    }

    fn park(ctx: *anyopaque, _: i32) net.MultiplexedResident.Park {
        const self = of(ctx);
        self.park_calls += 1;
        return self.park_result;
    }

    fn watch(ctx: *anyopaque, fd: i32) error{OutOfMemory}!void {
        const self = of(ctx);
        self.offered[self.offered_count] = fd;
        self.offered_count += 1;
        if (self.refuse_all) return error.OutOfMemory;
        if (self.refuse_once == fd) {
            self.refuse_once = null;
            return error.OutOfMemory;
        }
    }

    fn attempts(self: *const Parker) []const i32 {
        return self.offered[0..self.offered_count];
    }
};

const Rig = struct {
    threaded: std.Io.Threaded,
    probe: Probe,
    parkers: [residents_max]Parker,
    made: usize,
    runtime: HostRuntime,

    fn begin(self: *Rig, stepped: bool) !void {
        self.threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        errdefer self.threaded.deinit();
        self.probe = .{ .backing = std.testing.allocator };
        self.made = 0;
        var options = if (stepped) step_harness.steppedQuiet() else opts;
        options.busy_poll_ns = 0;
        self.runtime = try HostRuntime.init(self.probe.allocator(), self.threaded.io(), .{}, .ephemeral, options);
    }

    fn deinit(self: *Rig) void {
        self.probe.refuse_all = false;
        self.runtime.deinit();
        for (self.parkers[0..self.made]) |*parker| parker.inner.deinit();
        self.threaded.deinit();
    }

    /// Admit the next parker as the runtime's own resident row.
    fn admit(self: *Rig) !void {
        const index = self.made;
        self.parkers[index] = .{ .inner = try AcceptOwnershipResident.init() };
        self.made += 1;
        var name: [24]u8 = undefined;
        const symbol = try std.mem.print(&name, "x-park-watch-{d}", .{index});
        _ = try self.runtime.addResident(.{ .symbol = symbol, .designator_scheme = .address }, self.parkers[index].resident());
    }

    fn siblingFd(self: *const Rig, index: usize) i32 {
        return self.runtime.residents.items[index].readiness_fd;
    }

    fn mailboxFd(self: *Rig) !i32 {
        return (try self.runtime.settleMailbox()).wakeFd();
    }

    fn readyWakeFd(self: *Rig) i32 {
        return self.runtime.drive.stepped.ready_set.wakeFd();
    }

    /// One quiet public step that parks without blocking. The probe refuses
    /// all growth for its whole span, so a step that needed any fails or counts.
    fn wait(self: *Rig) !void {
        self.probe.refuse_all = true;
        defer self.probe.refuse_all = false;
        try std.testing.expectEqual(@as(?net.Progress, null), try self.runtime.stepAny(0));
    }

    /// A step the parker's `watch` refuses once: the optional park is
    /// declined for the call, the whole descriptor wait runs in its place, and
    /// the runtime asked the allocator for nothing.
    fn waitRefusedByParker(self: *Rig) !void {
        const parked = self.parkers[0].park_calls;
        try self.wait();
        try std.testing.expectEqual(parked, self.parkers[0].park_calls);
    }

    /// Admission leaves every descriptor the parker watches distinct from
    /// every other the runtime owns, so no offer aliases another source.
    fn expectDistinctDescriptors(self: *Rig) !void {
        var fds: [residents_max + 3]i32 = undefined;
        var count: usize = 0;
        for (self.runtime.residents.items) |registered| {
            fds[count] = registered.readiness_fd;
            count += 1;
        }
        if (self.runtime.mailbox) |mailbox| {
            fds[count] = mailbox.wakeFd();
            count += 1;
        }
        switch (self.runtime.drive) {
            .blocking => {},
            .stepped => |*stepped| {
                fds[count] = stepped.ready_set.descriptor();
                fds[count + 1] = stepped.ready_set.wakeFd();
                count += 2;
            },
        }
        for (fds[0..count], 0..) |fd, i| {
            try std.testing.expect(fd >= 0);
            for (fds[i + 1 .. count]) |other| try std.testing.expect(fd != other);
        }
    }

    fn expectOffered(self: *Rig, expected: []const i32) !void {
        try std.testing.expect(self.runtime.residents.items[0].resident.parks());
        try std.testing.expectEqualSlices(i32, expected, self.parkers[0].attempts());
        try std.testing.expectEqual(@as(usize, 0), self.probe.refused_all);
        try self.expectDistinctDescriptors();
    }
};

test "park watches: a wait after admission offers each distinct descriptor once and asks the allocator for nothing" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    try rig.admit();
    const mailbox = try rig.mailboxFd();
    const expected = [_]i32{ rig.siblingFd(1), rig.siblingFd(2), mailbox, rig.readyWakeFd() };

    try rig.wait();
    try rig.expectOffered(&expected);
    // Later waits find every mark advanced and offer nothing again.
    try rig.wait();
    try rig.wait();
    try rig.expectOffered(&expected);
}

test "park watches: the blocking face has no ready wake to offer" {
    var rig: Rig = undefined;
    try rig.begin(false);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    const mailbox = try rig.mailboxFd();
    try rig.wait();
    try rig.wait();
    try rig.expectOffered(&.{ rig.siblingFd(1), mailbox });
}

test "park watches: a source registered after the first wait is the only new work" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.wait();
    const wake = rig.readyWakeFd();
    try rig.expectOffered(&.{wake});

    // A sibling admitted after the wake was recorded, then a mailbox minted
    // after the sibling: each is offered once, the recorded wake is not.
    try rig.admit();
    try rig.wait();
    try rig.expectOffered(&.{ wake, rig.siblingFd(1) });
    const mailbox = try rig.mailboxFd();
    try rig.wait();
    try rig.wait();
    try rig.expectOffered(&.{ wake, rig.siblingFd(1), mailbox });

    // A second sibling arrives behind both marks and is offered before the
    // mailbox and the wake would be, though both stay recorded.
    try rig.admit();
    try rig.wait();
    try rig.expectOffered(&.{ wake, rig.siblingFd(1), mailbox, rig.siblingFd(2) });
}

test "park watches: a refused sibling declines one park and is offered again, the recorded prefix is not" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    try rig.admit();
    const mailbox = try rig.mailboxFd();
    const wake = rig.readyWakeFd();
    const first = rig.siblingFd(1);
    const second = rig.siblingFd(2);
    rig.parkers[0].refuse_once = second;

    try rig.waitRefusedByParker();
    try rig.expectOffered(&.{ first, second });
    // The retry resumes at the refused descriptor, then the rest in order.
    try rig.wait();
    try rig.expectOffered(&.{ first, second, second, mailbox, wake });
    try rig.wait();
    try rig.expectOffered(&.{ first, second, second, mailbox, wake });
}

test "park watches: a refused mailbox and a refused ready wake each retry alone" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    const mailbox = try rig.mailboxFd();
    const wake = rig.readyWakeFd();
    const sibling = rig.siblingFd(1);

    rig.parkers[0].refuse_once = mailbox;
    try rig.waitRefusedByParker();
    try rig.expectOffered(&.{ sibling, mailbox });
    rig.parkers[0].refuse_once = wake;
    try rig.waitRefusedByParker();
    try rig.expectOffered(&.{ sibling, mailbox, mailbox, wake });
    try rig.wait();
    try rig.expectOffered(&.{ sibling, mailbox, mailbox, wake, wake });
    try rig.wait();
    try rig.expectOffered(&.{ sibling, mailbox, mailbox, wake, wake });
}

/// Raw descriptor polls the syscall owner saw, and the bound of the first.
fn expectPolls(script: *const net.poll.testing.Script, calls: usize, first_timeout_ms: i32) !void {
    try std.testing.expectEqual(calls, script.calls);
    if (calls != 0) try std.testing.expectEqual(first_timeout_ms, script.timeouts[0]);
}

test "park watches: a healthy parker parks once and no descriptor poll runs" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    var script: net.poll.testing.Script = .{ .errnos = &.{} };
    const guard = net.poll.testing.inject(&script);
    defer guard.deinit();
    try rig.wait();
    try std.testing.expectEqual(@as(usize, 1), rig.parkers[0].park_calls);
    try expectPolls(&script, 0, 0);
}

test "park watches: a refused optional watch is not the caller's failure and the descriptor wait runs once instead" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    rig.parkers[0].refuse_once = rig.siblingFd(1);
    var script: net.poll.testing.Script = .{ .errnos = &.{} };
    const guard = net.poll.testing.inject(&script);
    defer guard.deinit();
    try rig.wait();
    try std.testing.expectEqual(@as(usize, 0), rig.parkers[0].park_calls);
    try expectPolls(&script, 1, 0);
}

test "park watches: sustained refusal polls the descriptors each call and recovery parks again without re-offering the prefix" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    try rig.admit();
    const first = rig.siblingFd(1);
    rig.parkers[0].refuse_all = true;
    var script: net.poll.testing.Script = .{ .errnos = &.{} };
    const guard = net.poll.testing.inject(&script);
    defer guard.deinit();

    // Each call offers the same refused descriptor once, never parks, and polls once.
    try rig.wait();
    try rig.wait();
    try std.testing.expectEqualSlices(i32, &.{ first, first }, rig.parkers[0].attempts());
    try std.testing.expectEqual(@as(usize, 0), rig.parkers[0].park_calls);
    try expectPolls(&script, 2, 0);

    // The provider recovers: the refused suffix is offered, then the park resumes.
    rig.parkers[0].refuse_all = false;
    try rig.wait();
    try std.testing.expectEqual(@as(usize, 1), rig.parkers[0].park_calls);
    try expectPolls(&script, 2, 0);
    try rig.expectOffered(&.{ first, first, first, rig.siblingFd(2), rig.readyWakeFd() });
}

test "park watches: a parker that answers unavailable leaves one descriptor poll at the caller's bound" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    rig.parkers[0].park_result = .unavailable;
    var script: net.poll.testing.Script = .{ .errnos = &.{} };
    const guard = net.poll.testing.inject(&script);
    defer guard.deinit();
    try rig.wait();
    try std.testing.expectEqual(@as(usize, 1), rig.parkers[0].park_calls);
    try expectPolls(&script, 1, 0);
    // A finite bound is the wait the descriptor poll runs.
    try std.testing.expectEqual(@as(?net.Progress, null), try rig.runtime.stepAny(10));
    try expectPolls(&script, 2, 0);
    try std.testing.expectEqual(@as(i32, 10), script.timeouts[1]);
}

test "park watches: a declined park polls at the timed resident's bound and services that resident" {
    inline for (.{ false, true }) |declined_by_park| {
        var rig: Rig = undefined;
        try rig.begin(true);
        defer rig.deinit();
        try rig.admit();
        try rig.admit();
        rig.parkers[1].inner.timed_work_ms = 1;
        if (declined_by_park) rig.parkers[0].park_result = .unavailable else rig.parkers[0].refuse_all = true;
        var script: net.poll.testing.Script = .{ .errnos = &.{} };
        const guard = net.poll.testing.inject(&script);
        defer guard.deinit();
        const drained = rig.parkers[1].inner.drain_calls;
        const other_drained = rig.parkers[0].inner.drain_calls;
        _ = try rig.runtime.stepAny(5_000);
        // One poll at the resident's bound, not the caller's, and the resident
        // that owns the bound is the one drained.
        try expectPolls(&script, 1, 1);
        try std.testing.expectEqual(drained + 1, rig.parkers[1].inner.drain_calls);
        try std.testing.expectEqual(other_drained, rig.parkers[0].inner.drain_calls);
    }
}

test "park watches: a genuine fault in a sibling still reaches the caller when the park is declined" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    try rig.admit();
    try rig.admit();
    rig.parkers[0].refuse_all = true;
    rig.parkers[1].inner.fail_drain = true;
    _ = try rig.parkers[1].inner.wake.nudge();
    try std.testing.expectError(error.LoopTerminal, rig.runtime.stepAny(0));
}

// The real epoll completion resident as the runtime's first parker, over a
// backend allocator of its own, with a sibling whose descriptor is genuinely
// readable. The healthy run parks in the epoll queue and polls no
// descriptor. After a valid setup the denied run has the backend refuse its
// first registration (nothing registered), which declines the park: the
// public step takes the descriptor route once, services the readable
// sibling, and stays healthy, and the park works again after recovery.
test "park watches: a real epoll parker that cannot register falls back to the descriptor wait and parks again" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    const Epoll = net.epoll_white_box.TestBackend;
    const Parking = net.completion_resident.Resident(Epoll, net.tcp.CompletionPolicy(Epoll));
    inline for (.{ false, true }) |denied| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        var real = try Parking.init(std.testing.allocator, try Epoll.init(failing.allocator(), 64, 8, 4096), .{
            .send_window_bytes = 16 << 10,
            .spare_send_buffers = 2,
        });
        // The resident outlives the runtime and retires what it still owes.
        defer {
            real.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
            real.deinit();
        }
        var rig: Rig = undefined;
        try rig.begin(true);
        defer rig.deinit();
        _ = try rig.runtime.addResident(.{ .symbol = "x-park-watch-real", .designator_scheme = .address }, real.resident());
        try rig.admit();
        const sibling = &rig.parkers[0].inner;
        if (denied) failing.fail_index = failing.alloc_index;

        var script: net.poll.testing.Script = .{ .errnos = &.{} };
        const guard = net.poll.testing.inject(&script);
        defer guard.deinit();

        // The sibling's readiness descriptor is readable before the step.
        _ = try sibling.wake.nudge();
        const drained = sibling.drain_calls;
        _ = try rig.runtime.stepAny(0);
        try std.testing.expectEqual(@as(?anyerror, null), real.failure);
        if (denied) {
            // Nothing registered, one descriptor poll, and the sibling serviced.
            try std.testing.expectEqual(@as(usize, 0), net.epoll_white_box.pendingCount(&real.backend));
            try expectPolls(&script, 1, 0);
            try std.testing.expectEqual(drained + 1, sibling.drain_calls);
        } else {
            // The park ran inside the epoll queue, so no descriptor was polled.
            try expectPolls(&script, 0, 0);
            try std.testing.expect(net.epoll_white_box.pendingCount(&real.backend) != 0);
        }

        // Recovered: the watches register, the park holds in the epoll queue
        // with no further poll, and a readable sibling still ends it.
        failing.fail_index = std.math.maxInt(usize);
        const polls = script.calls;
        // The healthy run's park ended on the readable sibling, which no step serviced.
        try sibling.wake.drain();
        _ = try rig.runtime.stepAny(0);
        try std.testing.expectEqual(polls, script.calls);
        try std.testing.expect(net.epoll_white_box.pendingCount(&real.backend) != 0);
        for (real.watches.items) |row| try std.testing.expect(row.armed);
        try std.testing.expectEqual(@as(?anyerror, null), real.failure);
        _ = try sibling.wake.nudge();
        _ = try rig.runtime.stepAny(1_000);
        try std.testing.expectEqual(polls, script.calls);
        try std.testing.expectEqual(@as(?anyerror, null), real.failure);
        try std.testing.expectEqual(sibling.wake.read, real.watches.items[0].fd);
        try std.testing.expect(!real.watches.items[0].armed);
    }
}
