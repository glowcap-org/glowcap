//! The parking resident's watches (ADR-0060). When every resident parks, the
//! first one is handed each sibling's readiness descriptor, the settle
//! mailbox's wake, and a stepped ready set's wake. The runtime's bookkeeping is
//! a sibling count and two flags, each advanced only after the parker's `watch`
//! callback returns, so it allocates nothing. The fixtures park without
//! blocking and record every descriptor the callback is offered, and a probe
//! allocator that refuses all growth after admission shows the runtime asks
//! it for nothing. Each wait is the public `stepAny(0)`, on both faces. The
//! callback's own `OutOfMemory` is the provider's, and the next wait offers that
//! descriptor again.

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

    fn park(_: *anyopaque, _: i32) bool {
        return false;
    }

    fn watch(ctx: *anyopaque, fd: i32) error{OutOfMemory}!void {
        const self = of(ctx);
        self.offered[self.offered_count] = fd;
        self.offered_count += 1;
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

    /// A step the parker's `watch` refuses once: the callback's own
    /// `OutOfMemory` reaches the caller, and the runtime asked for nothing.
    fn waitRefusedByParker(self: *Rig) !void {
        self.probe.refuse_all = true;
        defer self.probe.refuse_all = false;
        try std.testing.expectError(error.OutOfMemory, self.runtime.stepAny(0));
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

test "park watches: a refused sibling is offered again and the recorded prefix is not" {
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
