//! A foreign stream provider's close on an adopted connection, at the
//! completion resident. An awaiting caller gets `pending`, one `ev_closed`
//! once the provider handle is quiet, and then the provider's close failure
//! by value from the next call. A caller that stops waiting (a detach, or an
//! abort before the handle is quiet) hands the close to the provider's sink,
//! and an abort after it is quiet claims the result. Each connection holds
//! one record seat from adoption until its `ev_closed` or its row is gone,
//! and the provider's close runs exactly once.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const external = net.external_completion;
const mux = net.multiplexed_resident;

const HeldPlatform = @import("../support/held_platform.zig").HeldPlatform;

const Backend = external.CompletionBackend(HeldPlatform);
const Resident = net.completion_resident.Resident(Backend, external.ResidentPolicy(Backend, external.PlatformRefused(HeldPlatform)));

const transport = "fake-stream";
const max_conns = 16;
const wait_budget_ms: i64 = 10_000;

/// A provider whose connections are quiet wake channels. Its close reports a
/// scripted failure to the caller that waits for it, or counts a sink close
/// when the resident hands the close over.
const Script = struct {
    wakes: [max_conns]net.wake_channel.WakeChannel = undefined,
    opened: usize = 0,
    /// Provider closes by path. Each connection closes once on one of them.
    report_closes: usize = 0,
    sink_closes: usize = 0,
    /// A plain provider holds no resident close seat.
    reports: bool = true,

    fn of(ctx: *anyopaque) *Script {
        return @ptrCast(@alignCast(ctx));
    }

    fn startConnect(ctx: *anyopaque, _: model.PeerLocator) external.Started {
        const self = of(ctx);
        if (self.opened == max_conns) return .{ .failed = error.ProviderIo };
        const wake = net.wake_channel.WakeChannel.open() catch return .{ .failed = error.ProviderIo };
        self.wakes[self.opened] = wake;
        self.opened += 1;
        return .{ .ready = .{ .ptr = ctx, .fd = wake.read } };
    }

    fn unreachableFinish(_: *anyopaque, _: *anyopaque) external.Finished {
        unreachable;
    }

    fn cancelConnect(_: *anyopaque, _: *anyopaque) void {}

    fn tryRead(_: *anyopaque, _: *anyopaque, _: []u8) net.completion.TryRead {
        return .would_block;
    }

    fn tryWrite(_: *anyopaque, _: *anyopaque, _: []const u8) net.completion.TryWrite {
        return .would_block;
    }

    fn plainClose(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).sink_closes += 1;
    }

    /// One close: a failing report to the caller, or the sink's own record.
    fn reportingClose(ctx: *anyopaque, _: *anyopaque, recipient: external.CloseRecipient) ?net.carrier_failure.Report {
        const self = of(ctx);
        switch (recipient) {
            .sink => {
                self.sink_closes += 1;
                return null;
            },
            .caller => {
                self.report_closes += 1;
                var chain = foundation.FailureChain.init(error.ProviderIo);
                chain.cause_name = "CloseCleanupFailed";
                return .{ .chain = chain };
            },
        }
    }

    const reporting: external.VTable = vtable(.{ .reporting = reportingClose });
    const plain: external.VTable = vtable(.{ .plain = plainClose });

    fn vtable(close: external.VTable.Close) external.VTable {
        return .{
            .start_connect = startConnect,
            .finish_connect = unreachableFinish,
            .cancel_connect = cancelConnect,
            .try_read = tryRead,
            .try_write = tryWrite,
            .conn_close = close,
        };
    }

    fn deinit(self: *Script) void {
        for (self.wakes[0..self.opened]) |wake| wake.deinit();
    }

    fn provider(self: *Script) external.Provider {
        return .{ .transport = transport, .ctx = self, .vtable = if (self.reports) &reporting else &plain };
    }
};

fn newResident(allocator: std.mem.Allocator, providers: []const external.Provider) !Resident {
    return Resident.init(allocator, try Backend.initWithPlatform(allocator, .{ .providers = providers }, try HeldPlatform.init(allocator), 16, 256), .{});
}

/// Dial through the provider and adopt the connection.
fn adoptOne(resident: *Resident) !usize {
    const fd = try resident.backend.startDial(1, .{ .external = .{
        .transport = transport,
        .designator = "close-claim",
        .hints = model.Hints.emptyFalse(),
    } });
    var out: [4]net.completion.Completion = undefined;
    try std.testing.expectEqual(@as(usize, 1), try resident.backend.poll(&out, 1_000));
    try std.testing.expectEqual(@as(i32, 0), out[0].result);
    return resident.adopt(fd);
}

/// The law every record publication relies on: no publication allocates.
fn expectSeatLaw(resident: *const Resident) !void {
    try std.testing.expect(resident.records.capacity >= resident.records.items.len + resident.accept_seats + resident.close_seats);
}

/// Drain the resident until `conn` reports `ev_closed`, counting each one.
/// Returns how many `ev_closed` records named `conn`.
fn closedRecords(resident: *Resident, conn: usize, until_claimable: bool) !usize {
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
    var seen: usize = 0;
    while (true) {
        const r = resident.resident();
        r.beforeWait(.park);
        var out: [16]mux.ReadyEvent = undefined;
        for (try r.drainReady(&out)) |event| {
            if (event.subject == conn and event.events & mux.ev_closed != 0) seen += 1;
        }
        if (!until_claimable or seen != 0) return seen;
        if (net.clock.nowMonotonicMs() >= deadline) return error.CloseNeverClaimable;
        if (!r.readyPending()) {
            var fds = [_]std.posix.pollfd{.{ .fd = r.readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
            _ = try std.posix.poll(&fds, 10);
        }
    }
}

/// Every `ev_closed` record for `conn` from now until its row retires, and
/// one more drain after it: the count a path with no claimable result owes
/// zero of.
fn retiredClosedRecords(resident: *Resident, conn: usize) !usize {
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
    var seen: usize = 0;
    while (resident.conns.count() != 0) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.CloseNeverRetired;
        seen += try closedRecords(resident, conn, false);
    }
    return seen + try closedRecords(resident, conn, false);
}

fn skipUnlessPosix() !void {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
}

fn expectClaimedFailure(outcome: mux.TeardownOutcome) !void {
    switch (outcome) {
        .failed => |report| try std.testing.expectEqualStrings("CloseCleanupFailed", report.chain.primaryName()),
        else => return error.ExpectedFailedClose,
    }
}

test "an awaited close reports pending, one closed record, then the provider's failure by value" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    try std.testing.expectEqual(@as(usize, 1), resident.close_seats);
    try expectSeatLaw(&resident);

    const ops = resident.resident();
    ops.beforeWait(.park);
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    // The provider handle stays open until the result is claimed.
    try std.testing.expectEqual(@as(usize, 0), script.report_closes + script.sink_closes);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, conn, true));
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes + script.sink_closes);

    try expectClaimedFailure(ops.connCloseOutcome(conn, .awaited));
    try std.testing.expectEqual(@as(usize, 1), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
    // The row is gone: nothing is claimed twice, and no second record exists.
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .complete);
    try std.testing.expectEqual(@as(usize, 0), try closedRecords(&resident, conn, false));
    try std.testing.expectEqual(@as(usize, 1), script.report_closes);
}

test "a no-wait close hands the provider failure to its sink and publishes no record" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(conn, .no_wait) == .complete);
    try std.testing.expectEqual(@as(usize, 0), try retiredClosedRecords(&resident, conn));
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
}

test "a close with no poll armed is claimable inside the call on every platform" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.backend.platform.held = false;
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    // The receive was never started, so nothing borrows the handle: the
    // close is quiet at once and the gate has nothing to hold.
    resident.backend.platform.held = true;
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expect(resident.conns.getPtr(conn).?.close_wait == .claimable);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, conn, true));
    try expectClaimedFailure(ops.connCloseOutcome(conn, .awaited));
    try std.testing.expectEqual(@as(usize, 1), script.report_closes);
}

test "an abort before the handle is quiet gives up the wait and returns complete" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.backend.platform.held = false;
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    // Arm the receive poll: the close must cancel it before the handle is
    // quiet. Epoll and kqueue queue that cancel's completions inside the call
    // and io_uring may finish it later, so the platform holds them here and
    // the row is waiting on every platform.
    ops.beforeWait(.park);
    resident.backend.platform.held = true;
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expect(resident.conns.getPtr(conn).?.close_wait == .awaited);
    try std.testing.expect(ops.connAbortOutcome(conn, .awaited).? == .complete);
    // The poll is still borrowed, so the provider has not been closed.
    try std.testing.expectEqual(@as(usize, 0), script.sink_closes);
    resident.backend.platform.held = false;
    try std.testing.expectEqual(@as(usize, 0), try retiredClosedRecords(&resident, conn));
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
}

test "an abort after the handle is quiet claims the failure once" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, conn, true));
    try expectClaimedFailure(ops.connAbortOutcome(conn, .awaited).?);
    try std.testing.expectEqual(@as(usize, 1), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
}

test "a no-wait abort after the handle is quiet hands the failure to the sink once" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, conn, true));
    // The wire was detached: the abort has no caller to claim for.
    try std.testing.expect(ops.connAbortOutcome(conn, .no_wait).? == .complete);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
}

test "a no-wait abort before the handle is quiet hands the close to the sink once" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.backend.platform.held = false;
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    ops.beforeWait(.park);
    resident.backend.platform.held = true;
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expect(resident.conns.getPtr(conn).?.close_wait == .awaited);
    try std.testing.expect(ops.connAbortOutcome(conn, .no_wait).? == .complete);
    try std.testing.expectEqual(@as(usize, 0), script.sink_closes);
    resident.backend.platform.held = false;
    try std.testing.expectEqual(@as(usize, 0), try retiredClosedRecords(&resident, conn));
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
}

test "a detach after the handle is quiet hands the close to the sink" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .pending);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, conn, true));
    try std.testing.expect(ops.connCloseOutcome(conn, .no_wait) == .complete);
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
}

test "a drain finalizes an unclaimed close exactly once" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        // A failed assertion while the gate is held still releases and drains
        // the resident, so deinit does not mask it.
        resident.backend.platform.held = false;
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const claimable = try adoptOne(&resident);
    const waiting = try adoptOne(&resident);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(claimable, .awaited) == .pending);
    try std.testing.expectEqual(@as(usize, 1), try closedRecords(&resident, claimable, true));
    // `waiting` has its receive poll armed (the loop above parked) and the
    // platform holds the cancel, so its seat stays held on every platform.
    resident.backend.platform.held = true;
    try std.testing.expect(ops.connCloseOutcome(waiting, .awaited) == .pending);
    try std.testing.expectEqual(@as(usize, 1), resident.close_seats);
    resident.backend.platform.held = false;
    try resident.closeAndDrain(2_000);
    try std.testing.expectEqual(@as(usize, 2), script.sink_closes);
    try std.testing.expectEqual(@as(usize, 0), script.report_closes);
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
    try std.testing.expect(resident.drained());
}

test "a provider without a close report keeps the ordinary close and holds no resident seat" {
    try skipUnlessPosix();
    var script: Script = .{ .reports = false };
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var resident = try newResident(std.testing.allocator, &providers);
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
        resident.deinit();
    }
    const conn = try adoptOne(&resident);
    try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
    const ops = resident.resident();
    try std.testing.expect(ops.connCloseOutcome(conn, .awaited) == .complete);
    try std.testing.expectEqual(@as(usize, 0), try retiredClosedRecords(&resident, conn));
    try std.testing.expectEqual(@as(usize, 1), script.sink_closes);
}

test "adoption reserves the close seat or changes nothing under allocation refusal" {
    try skipUnlessPosix();
    const allocator = std.testing.allocator;
    var offset: usize = 0;
    while (offset < 16) : (offset += 1) {
        var script: Script = .{};
        defer script.deinit();
        const providers = [_]external.Provider{script.provider()};
        var resident = try newResident(allocator, &providers);
        defer {
            resident.closeAndDrain(2_000) catch |err| std.debug.panic("drain failed: {t}", .{err});
            resident.deinit();
        }
        const fd = try resident.backend.startDial(1, .{ .external = .{
            .transport = transport,
            .designator = "close-claim",
            .hints = model.Hints.emptyFalse(),
        } });
        var out: [4]net.completion.Completion = undefined;
        try std.testing.expectEqual(@as(usize, 1), try resident.backend.poll(&out, 1_000));
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = offset });
        const real = resident.allocator;
        resident.allocator = failing.allocator();
        const adopted = resident.adopt(fd);
        resident.allocator = real;
        if (adopted) |_| {
            try std.testing.expectEqual(@as(usize, 1), resident.close_seats);
            try std.testing.expectEqual(@as(usize, 1), resident.conns.count());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), resident.close_seats);
            try std.testing.expectEqual(@as(usize, 0), resident.conns.count());
            // The caller still owns the descriptor and closes it.
            resident.backend.closeFd(fd);
        }
        try expectSeatLaw(&resident);
    }
}

test "external connection admission reserves publication for its first close" {
    try skipUnlessPosix();
    var script: Script = .{};
    defer script.deinit();
    const providers = [_]external.Provider{script.provider()};
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backend = try Backend.initWithPlatform(measured.allocator(), .{ .providers = &providers }, try HeldPlatform.init(std.testing.allocator), 2, 256);
    defer backend.deinit();
    const target: Backend.ConnectTarget = .{ .external = .hintless(transport, "close") };
    const fd = try backend.startDial(1, target);
    const other = try backend.startDial(2, target);
    var out: [2]net.completion.Completion = undefined;
    try std.testing.expectEqual(2, try backend.peek(&out));
    backend.platform.held = true;
    try backend.submitRecv(3, fd);
    try backend.submitSend(4, fd, "pending");
    const occupied = backend.ready.reserved;
    // Cover the queue's capacity bucket with other reservations. A late
    // request for another seat would have to grow the adapter's allocation.
    const spare = backend.ready.items.capacity - occupied;
    try backend.ready.reserve(backend.allocator, spare);
    const allocations = measured.alloc_index;
    const resizes = measured.resize_index;
    try backend.submitCloseAwaited(5, fd);
    try std.testing.expectError(error.AlreadyClosing, backend.submitClose(6, fd));
    for ([_]u64{ 3, 4 }) |token| {
        try std.testing.expectEqual(1, try backend.peek(out[0..1]));
        try std.testing.expectEqual(token, out[0].user_data);
        try std.testing.expect(out[0].result < 0);
    }
    try std.testing.expectEqual(0, try backend.peek(&out));
    try std.testing.expectEqual(0, script.report_closes + script.sink_closes);
    backend.platform.held = false;
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;
    while (try backend.poll(out[0..1], 10) == 0) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.CloseNeverClaimable;
    }
    try std.testing.expectEqual(5, out[0].user_data);
    try std.testing.expectEqual(Backend.close_claimable, out[0].result);
    try std.testing.expect(backend.claimClose(fd) != null);
    const remaining = backend.ready.reserved - spare;
    backend.ready.release(spare);
    backend.closeFd(other);
    try std.testing.expectEqual(0, try backend.peek(&out));
    try std.testing.expectEqual(1, script.report_closes);
    try std.testing.expectEqual(1, script.sink_closes);
    try std.testing.expectEqual(4, occupied); // Two rows and two parked operations.
    try std.testing.expectEqual(1, remaining); // Only the other row still owned a seat.
    try std.testing.expectEqual(0, backend.ready.reserved);
    try std.testing.expectEqual(allocations, measured.alloc_index);
    try std.testing.expectEqual(resizes, measured.resize_index);
}

// The resident row's 152 bytes are pinned by the completion resident's own
// test. Stated for 64-bit targets under runtime safety, where each embedded
// list header carries std's one-word pointer-stability lock.
test "the close phase adds no bytes to a provider connection row" {
    if (!builtin.optimize.runtimeSafety() or @sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 128), Backend.connection_state_bytes);
}
