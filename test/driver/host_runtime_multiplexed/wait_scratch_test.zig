//! Descriptor-wait row storage (ADR-0024). Construction and each resident
//! admission reserve the rows of the descriptor-poll wait and the terminal
//! signal wait, so building those rows allocates nothing. The fixtures are
//! non-parking residents with `busy_poll_ns` zero, a wait that reaches its
//! descriptor poll is read from the rows the poll saw, and an allocator that
//! refuses every growth after admission shows the wait asks it for nothing.
//! The parking branch of the wait is outside this contract.
//!
//! A growth proof always crosses the array's live capacity, because the list
//! grows by its own amortized step and a few residents fit spare capacity. A
//! refusal is aimed at the scratch request by its exact byte size, and the
//! tests read the allocator's hit counts and the arrays' capacity to show which
//! request was refused.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const step_harness = @import("../host_runtime_step/harness.zig");
const growth_probe = @import("growth_probe.zig");

const Probe = growth_probe.Probe;
const none = growth_probe.none;

const driver = glowcap.driver;
const net = glowcap.net;
const driver_core = driver.core;

const fixtures = @import("residents.zig");
const AcceptOwnershipResident = fixtures.AcceptOwnershipResident;
const opts = fixtures.opts;

const HostRuntime = driver.HostRuntime;
const PollRows = std.ArrayList(std.posix.pollfd);
const FdRows = std.ArrayList(std.posix.fd_t);
const signal_rows = 2;
const max_residents = 64;
const wait_ms = 5;

/// The bytes the list requests when it grows to hold `rows`.
fn pollBytes(rows: usize) usize {
    return PollRows.growCapacity(rows) * @sizeOf(std.posix.pollfd);
}

fn fdBytes(rows: usize) usize {
    return FdRows.growCapacity(rows) * @sizeOf(std.posix.fd_t);
}

/// A runtime over `Probe`, with up to `max_residents` non-parking residents
/// that are created when first named.
const Rig = struct {
    threaded: std.Io.Threaded,
    probe: Probe,
    residents: [max_residents]AcceptOwnershipResident,
    made: usize,
    names: [max_residents][24]u8,
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
        self.runtime.deinit();
        for (self.residents[0..self.made]) |*resident| resident.deinit();
        self.threaded.deinit();
    }

    fn name(self: *Rig, index: usize) []const u8 {
        return std.mem.print(&self.names[index], "x-wait-scratch-{d}", .{index}) catch unreachable;
    }

    fn residentAt(self: *Rig, index: usize) !net.MultiplexedResident {
        while (self.made <= index) : (self.made += 1)
            self.residents[self.made] = try AcceptOwnershipResident.init();
        return self.residents[index].multiplexedResident();
    }

    /// Admit residents `first..first + count`, each serving its own profile.
    fn admitDistinct(self: *Rig, first: usize, count: usize) !void {
        var registrations: [max_residents]HostRuntime.ProviderRegistration = undefined;
        var indices: [max_residents]usize = undefined;
        for (0..count) |k| registrations[k] = .{
            .profile = .{ .symbol = self.name(first + k), .designator_scheme = .address },
            .resident = try self.residentAt(first + k),
        };
        try self.runtime.addProviders(registrations[0..count], indices[0..count]);
    }

    /// Admit one resident serving `count` profiles.
    fn admitShared(self: *Rig, resident_index: usize, count: usize) !void {
        var registrations: [max_residents]HostRuntime.ProviderRegistration = undefined;
        var indices: [max_residents]usize = undefined;
        const shared = try self.residentAt(resident_index);
        for (0..count) |k| registrations[k] = .{
            .profile = .{ .symbol = self.name(k), .designator_scheme = .address },
            .resident = shared,
        };
        try self.runtime.addProviders(registrations[0..count], indices[0..count]);
    }

    fn pollCapacity(self: *const Rig) usize {
        return self.runtime.poll_scratch.capacity;
    }

    fn fdCapacity(self: *const Rig) usize {
        return self.runtime.extra_fd_scratch.capacity;
    }

    fn expectAbsent(self: *Rig, first: usize, count: usize) !void {
        for (first..first + count) |index| {
            try std.testing.expect(!self.runtime.hasTransport(self.name(index)));
            try std.testing.expectError(error.UnknownTransport, self.runtime.core.transportProfile(self.name(index)));
        }
    }

    const Wait = enum { operational, terminal };

    /// Run one wait under an allocator that refuses every growth and return
    /// the rows its descriptor poll saw. Asserts the wait never asked the
    /// allocator for anything, that no resident parks, and that the poll rows
    /// are the expected descriptors in descriptor order, all quiet.
    fn waitWithoutAllocation(self: *Rig, wait: Wait) !void {
        const runtime = &self.runtime;
        try std.testing.expectEqual(@as(u64, 0), runtime.opts.busy_poll_ns);
        for (runtime.residents.items) |registered| try std.testing.expect(!registered.resident.parks());
        const residents = runtime.residents.items.len;
        const first = if (residents > 0) runtime.wait_cursor % residents else 0;
        var expected: [max_residents + signal_rows]i32 = undefined;
        var rows: usize = 0;
        if (wait == .operational) for (0..residents) |k| {
            expected[rows] = runtime.residents.items[(first + k) % residents].readiness_fd;
            rows += 1;
        };
        if (runtime.mailbox) |mailbox| {
            expected[rows] = mailbox.wakeFd();
            rows += 1;
        }
        switch (runtime.drive) {
            .blocking => {},
            .stepped => |*stepped| {
                expected[rows] = stepped.ready_set.wakeFd();
                rows += 1;
            },
        }

        const refused_before = self.probe.refused_all;
        self.probe.refuse_all = true;
        defer self.probe.refuse_all = false;
        switch (wait) {
            .operational => try std.testing.expectEqual(
                @as(?usize, null),
                try HostRuntime.testing.waitAnySource(runtime, wait_ms, true),
            ),
            .terminal => try HostRuntime.testing.waitForTerminalSignal(runtime, wait_ms),
        }
        try std.testing.expectEqual(refused_before, self.probe.refused_all);
        try std.testing.expectEqualSlices(i32, expected[0..rows], runtime.extra_fd_scratch.items);
        // The poll wrote every row it saw, and nothing was ready.
        try std.testing.expectEqual(rows, runtime.poll_scratch.items.len);
        for (runtime.poll_scratch.items, expected[0..rows]) |row, fd| {
            try std.testing.expectEqual(fd, row.fd);
            try std.testing.expectEqual(@as(i16, 0), row.revents);
        }
    }
};

const Scenario = struct { stepped: bool, mailbox: bool, residents: usize };

fn runScenario(wait: Rig.Wait, scenario: Scenario) !void {
    var rig: Rig = undefined;
    try rig.begin(scenario.stepped);
    defer rig.deinit();
    const initial_poll = rig.pollCapacity();
    const initial_fd = rig.fdCapacity();
    if (scenario.residents > 0) {
        try rig.admitDistinct(0, scenario.residents);
        // The admission crossed the live capacity of both arrays.
        try std.testing.expect(rig.pollCapacity() > initial_poll);
        try std.testing.expect(rig.fdCapacity() > initial_fd);
    }
    if (scenario.mailbox) _ = try rig.runtime.settleMailbox();
    try rig.waitWithoutAllocation(wait);
}

/// Residents enough to cross the initial capacity of both arrays.
fn crossingResidents() !usize {
    var rig: Rig = undefined;
    try rig.begin(false);
    defer rig.deinit();
    const count = @max(rig.pollCapacity(), rig.fdCapacity());
    try std.testing.expect(count + signal_rows <= max_residents + signal_rows);
    return count;
}

test "wait scratch: the descriptor-poll wait builds its rows without allocating after admission" {
    const crossing = try crossingResidents();
    try runScenario(.operational, .{ .stepped = false, .mailbox = false, .residents = crossing });
    try runScenario(.operational, .{ .stepped = true, .mailbox = true, .residents = crossing });
    try runScenario(.operational, .{ .stepped = false, .mailbox = true, .residents = crossing });
}

test "wait scratch: a zero-resident stepped wait builds its wake rows without allocating" {
    try runScenario(.operational, .{ .stepped = true, .mailbox = false, .residents = 0 });
    try runScenario(.operational, .{ .stepped = true, .mailbox = true, .residents = 0 });
    try runScenario(.operational, .{ .stepped = false, .mailbox = true, .residents = 0 });
}

test "wait scratch: the terminal signal wait builds its rows without allocating" {
    const crossing = try crossingResidents();
    try runScenario(.terminal, .{ .stepped = true, .mailbox = false, .residents = 0 });
    try runScenario(.terminal, .{ .stepped = true, .mailbox = true, .residents = 0 });
    try runScenario(.terminal, .{ .stepped = false, .mailbox = true, .residents = 0 });
    // Residents are absent from the terminal rows, so they add none.
    try runScenario(.terminal, .{ .stepped = true, .mailbox = true, .residents = crossing });
}

test "wait scratch: the terminal signal wait with no source sleeps and asks the allocator for nothing" {
    var rig: Rig = undefined;
    try rig.begin(false);
    defer rig.deinit();
    rig.probe.refuse_all = true;
    try HostRuntime.testing.waitForTerminalSignal(&rig.runtime, wait_ms);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.refused_all);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime.extra_fd_scratch.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.runtime.poll_scratch.items.len);
    rig.probe.refuse_all = false;
}

test "wait scratch: storage is reserved at construction and its measured capacity is the amortized step" {
    var rig: Rig = undefined;
    try rig.begin(false);
    defer rig.deinit();
    try std.testing.expectEqual(PollRows.growCapacity(signal_rows), rig.pollCapacity());
    try std.testing.expectEqual(FdRows.growCapacity(signal_rows), rig.fdCapacity());
    try std.testing.expect(rig.pollCapacity() > signal_rows);
    try std.testing.expect(rig.fdCapacity() > signal_rows);
}

const Constructor = enum { owning, borrowed };

/// Construct once under `probe`. The owning form returns its runtime, the
/// borrowed form adopts `core` and leaves it with its caller.
fn construct(
    kind: Constructor,
    probe: *Probe,
    io: std.Io,
    core: *driver_core.Host,
) !HostRuntime {
    return switch (kind) {
        .owning => HostRuntime.init(probe.allocator(), io, .{}, .ephemeral, opts),
        .borrowed => HostRuntime.initWithCore(probe.allocator(), io, core, .{}, .{
            .handshake = opts.handshake,
            .settle = opts.settle,
        }),
    };
}

fn constructorSweep(kind: Constructor) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const poll_len = pollBytes(signal_rows);
    const fd_len = fdBytes(signal_rows);

    // Baseline: each scratch request is made exactly once, poll then fd.
    {
        var core = borrowedCore();
        defer core.deinit();
        var probe: Probe = .{ .backing = std.testing.allocator, .count_a_len = poll_len, .count_b_len = fd_len };
        var runtime = try construct(kind, &probe, io, &core);
        runtime.deinit();
        try std.testing.expectEqual(@as(usize, 1), probe.count_a);
        try std.testing.expectEqual(@as(usize, 1), probe.count_b);
    }

    // The poll reserve refuses: the fd reserve is never reached.
    {
        var core = borrowedCore();
        defer core.deinit();
        var probe: Probe = .{
            .backing = std.testing.allocator,
            .target_len = poll_len,
            .count_b_len = fd_len,
        };
        try std.testing.expectError(error.OutOfMemory, construct(kind, &probe, io, &core));
        try std.testing.expect(probe.hits >= 1);
        // The owning form allocated its core first. The borrowed form's
        // first allocation is this reserve.
        if (kind == .owning) try std.testing.expect(probe.granted_before_hit > 0);
        try std.testing.expectEqual(@as(usize, 0), probe.count_b);
        try expectCoreStillAdoptable(kind, &core, io);
    }

    // The fd reserve refuses after the poll reserve succeeded, and that
    // retained poll storage is released with the failed construction.
    {
        var core = borrowedCore();
        defer core.deinit();
        var probe: Probe = .{
            .backing = std.testing.allocator,
            .target_len = fd_len,
            .count_a_len = poll_len,
        };
        try std.testing.expectError(error.OutOfMemory, construct(kind, &probe, io, &core));
        try std.testing.expect(probe.hits >= 1);
        try std.testing.expect(probe.granted_before_hit > 0);
        try std.testing.expectEqual(@as(usize, 1), probe.count_a);
        try expectCoreStillAdoptable(kind, &core, io);
    }
}

fn borrowedCore() driver_core.Host {
    return test_host.init(std.testing.allocator, @as([32]u8, @splat(0x61)), .{ .thread_policy = .unchecked });
}

/// A refused borrowed construction leaves the core with its caller: it is not
/// closed, and a later adoption over it succeeds.
fn expectCoreStillAdoptable(kind: Constructor, core: *driver_core.Host, io: std.Io) !void {
    if (kind == .owning) return;
    var probe: Probe = .{ .backing = std.testing.allocator };
    var runtime = try construct(kind, &probe, io, core);
    runtime.deinit();
}

test "wait scratch: owning construction refuses at each wait scratch reserve and leaks nothing" {
    try constructorSweep(.owning);
}

test "wait scratch: borrowed construction refuses at each wait scratch reserve and keeps the core" {
    try constructorSweep(.borrowed);
}

/// The state a refused admission must leave unchanged.
const Held = struct {
    residents: usize,
    providers: usize,
    poll_capacity: usize,
    poll_ptr: [*]std.posix.pollfd,
    fd_capacity: usize,
    fd_ptr: [*]std.posix.fd_t,

    fn of(rig: *Rig) Held {
        return .{
            .residents = rig.runtime.residents.items.len,
            .providers = rig.runtime.providers.items.len,
            .poll_capacity = rig.pollCapacity(),
            .poll_ptr = rig.runtime.poll_scratch.items.ptr,
            .fd_capacity = rig.fdCapacity(),
            .fd_ptr = rig.runtime.extra_fd_scratch.items.ptr,
        };
    }

    fn expectPollUnchanged(held: Held, rig: *Rig) !void {
        try std.testing.expectEqual(held.poll_capacity, rig.pollCapacity());
        try std.testing.expectEqual(held.poll_ptr, rig.runtime.poll_scratch.items.ptr);
    }

    fn expectFdUnchanged(held: Held, rig: *Rig) !void {
        try std.testing.expectEqual(held.fd_capacity, rig.fdCapacity());
        try std.testing.expectEqual(held.fd_ptr, rig.runtime.extra_fd_scratch.items.ptr);
    }

    fn expectRegistrationsUnchanged(held: Held, rig: *Rig) !void {
        try std.testing.expectEqual(held.residents, rig.runtime.residents.items.len);
        try std.testing.expectEqual(held.providers, rig.runtime.providers.items.len);
    }
};

/// Admit residents one at a time up to `until`, asserting that neither array
/// moves while the rows still fit.
fn admitWithinCapacity(rig: *Rig, until: usize, poll_fits: bool, fd_fits: bool) !void {
    while (rig.runtime.residents.items.len < until) {
        const held = Held.of(rig);
        try rig.admitDistinct(held.residents, 1);
        if (poll_fits) try held.expectPollUnchanged(rig);
        if (fd_fits) try held.expectFdUnchanged(rig);
    }
}

/// After a refusal: the registrations held, nothing new is visible, the first
/// resident's transport still stands, and the wait over the survivors polls
/// exactly their rows without allocating.
fn expectRefusedBeforeEffects(rig: *Rig, held: Held, refused_first: usize, refused_count: usize) !void {
    try held.expectRegistrationsUnchanged(rig);
    try rig.expectAbsent(refused_first, refused_count);
    if (held.residents > 0) try std.testing.expect(rig.runtime.hasTransport(rig.name(0)));
    try rig.waitWithoutAllocation(.operational);
}

/// Retry the refused admission with the allocator disarmed: it succeeds, which
/// shows no ready descriptor leaked from the refusal, and the next wait still
/// builds its larger row set without allocating.
fn retryAndWait(rig: *Rig, first: usize, count: usize) !void {
    rig.probe.target_len = none;
    try rig.admitDistinct(first, count);
    try std.testing.expect(rig.runtime.hasTransport(rig.name(first + count - 1)));
    try rig.waitWithoutAllocation(.operational);
    try rig.waitWithoutAllocation(.terminal);
}

test "wait scratch: a refused poll scratch reserve at admission leaves registrations untouched and retries" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    const initial = rig.pollCapacity();
    // Rows fit through `initial - 2` residents, and the fd array has room.
    try std.testing.expect(initial >= signal_rows + 2);
    try admitWithinCapacity(&rig, initial - signal_rows, true, true);

    const held = Held.of(&rig);
    const next = held.residents;
    // This resident crosses the poll array's live capacity.
    try std.testing.expect(next + 1 + signal_rows > rig.pollCapacity());
    try std.testing.expect(next + 1 + signal_rows <= rig.fdCapacity());
    rig.probe.target_len = pollBytes(next + 1 + signal_rows);
    try std.testing.expectError(error.OutOfMemory, rig.admitDistinct(next, 1));
    try std.testing.expect(rig.probe.hits >= 1);
    try std.testing.expect(rig.probe.granted_before_hit > 0);
    try held.expectPollUnchanged(&rig);
    try held.expectFdUnchanged(&rig);
    rig.probe.target_len = none;
    try expectRefusedBeforeEffects(&rig, held, next, 1);

    try retryAndWait(&rig, next, 1);
    try std.testing.expect(rig.pollCapacity() > held.poll_capacity);
    try std.testing.expectEqual(held.fd_capacity, rig.fdCapacity());
}

test "wait scratch: a refused fd scratch reserve at admission leaves registrations untouched and retries" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    const initial_fd = rig.fdCapacity();
    try std.testing.expect(initial_fd >= signal_rows + 2);
    // The poll array crosses and grows on its own, then the fd array fills.
    try admitWithinCapacity(&rig, initial_fd - signal_rows, false, true);

    const held = Held.of(&rig);
    const next = held.residents;
    try std.testing.expect(next + 1 + signal_rows > rig.fdCapacity());
    // The poll array's grown capacity already holds the next row set.
    try std.testing.expect(next + 1 + signal_rows <= rig.pollCapacity());
    rig.probe.target_len = fdBytes(next + 1 + signal_rows);
    try std.testing.expectError(error.OutOfMemory, rig.admitDistinct(next, 1));
    try std.testing.expect(rig.probe.hits >= 1);
    try std.testing.expect(rig.probe.granted_before_hit > 0);
    try held.expectPollUnchanged(&rig);
    try held.expectFdUnchanged(&rig);
    rig.probe.target_len = none;
    try expectRefusedBeforeEffects(&rig, held, next, 1);

    try retryAndWait(&rig, next, 1);
    try std.testing.expect(rig.fdCapacity() > held.fd_capacity);
}

test "wait scratch: a refused fd reserve after the poll reserve grew keeps that capacity and no registration" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    const initial_poll = rig.pollCapacity();
    const initial_fd = rig.fdCapacity();
    // One batch crosses both arrays' live capacity.
    const batch = @max(initial_poll, initial_fd);
    try std.testing.expect(batch + signal_rows <= max_residents + signal_rows);
    try std.testing.expect(batch + signal_rows > initial_poll and batch + signal_rows > initial_fd);

    const held = Held.of(&rig);
    rig.probe.target_len = fdBytes(batch + signal_rows);
    try std.testing.expectError(error.OutOfMemory, rig.admitDistinct(0, batch));
    try std.testing.expect(rig.probe.hits >= 1);
    try std.testing.expect(rig.probe.granted_before_hit > 0);
    // The poll reserve came first and its capacity stays, harmless.
    try std.testing.expect(rig.pollCapacity() > initial_poll);
    try held.expectFdUnchanged(&rig);
    rig.probe.target_len = none;
    try held.expectRegistrationsUnchanged(&rig);
    try rig.expectAbsent(0, batch);

    try retryAndWait(&rig, 0, batch);
    try std.testing.expect(rig.fdCapacity() > initial_fd);
}

test "wait scratch: many valid profiles on one resident reserve by distinct resident, not by profile" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    const profiles = @min(max_residents, @max(rig.pollCapacity(), rig.fdCapacity()) + 4);
    // Profile count alone would cross both arrays, a resident count would not.
    try std.testing.expect(profiles + signal_rows > rig.pollCapacity());
    try std.testing.expect(profiles + signal_rows > rig.fdCapacity());
    const held = Held.of(&rig);
    rig.probe.count_a_len = pollBytes(profiles + signal_rows);
    rig.probe.count_b_len = fdBytes(profiles + signal_rows);

    try rig.admitShared(0, profiles);
    try std.testing.expectEqual(@as(usize, 1), rig.runtime.residents.items.len);
    try std.testing.expectEqual(held.providers + profiles, rig.runtime.providers.items.len);
    try held.expectPollUnchanged(&rig);
    try held.expectFdUnchanged(&rig);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.count_a);
    try std.testing.expectEqual(@as(usize, 0), rig.probe.count_b);
    try rig.waitWithoutAllocation(.operational);
}

test "wait scratch: growth after admission serves the next wait without allocating" {
    var rig: Rig = undefined;
    try rig.begin(true);
    defer rig.deinit();
    _ = try rig.runtime.settleMailbox();
    const initial_poll = rig.pollCapacity();
    const initial_fd = rig.fdCapacity();
    const crossing = @max(initial_poll, initial_fd);
    // One resident at a time through both crossings, waiting after each.
    for (0..crossing) |index| {
        try rig.admitDistinct(index, 1);
        try rig.waitWithoutAllocation(.operational);
        try rig.waitWithoutAllocation(.terminal);
    }
    try std.testing.expect(rig.pollCapacity() > initial_poll);
    try std.testing.expect(rig.fdCapacity() > initial_fd);
    try std.testing.expect(rig.pollCapacity() >= crossing + signal_rows);
    try std.testing.expect(rig.fdCapacity() >= crossing + signal_rows);
}
