//! A foreign provider's failed listen keeps its exact chain on the external
//! completion backend. A refused open answers until the next open, and a
//! listener whose finish failed answers until it is closed, so a chain never
//! describes another attempt.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const external = net.external_completion;

const Backend = external.CompletionBackend(net.Backend);

const transport = "fake-stream";
const named: foundation.FailureChain = .{
    .cause = error.ProviderIo,
    .cause_name = "AddressInUse",
    .classification = .io,
};

/// A provider whose listen answers from a script and whose descriptor is a
/// wake channel the test nudges to finish a pending attempt.
const Script = struct {
    wake: net.wake_channel.WakeChannel,
    start: external.ListenStarted,
    finish: external.ListenFinished,
    listen_calls: usize = 0,
    cancel_calls: usize = 0,
    close_calls: usize = 0,
    accept_calls: usize = 0,
    /// The provider's refusal of each arrival. A transient one is the kind a
    /// resident re-arms at once.
    accept_error: ?anyerror = null,
    /// One quiet wake channel per accepted handle the provider has issued.
    accept_wakes: [max_dials]net.wake_channel.WakeChannel = undefined,
    accepts_issued: usize = 0,
    conn_closes: usize = 0,
    /// One wake channel per dial the provider has started.
    dial_wakes: [max_dials]net.wake_channel.WakeChannel = undefined,
    dials_started: usize = 0,
    dial_cancels: usize = 0,

    fn of(ctx: *anyopaque) *Script {
        return @ptrCast(@alignCast(ctx));
    }

    fn listen(ctx: *anyopaque, _: []const u8, _: ?foundation.crypto.PeerKey) external.ListenStarted {
        const self = of(ctx);
        self.listen_calls += 1;
        return self.start;
    }

    fn finishListen(ctx: *anyopaque, _: *anyopaque) external.ListenFinished {
        return of(ctx).finish;
    }

    fn cancelListen(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).cancel_calls += 1;
    }

    fn listenerClose(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).close_calls += 1;
    }

    /// Each nudge of the listener's wake channel is one arrival: it is
    /// consumed here, and answered with the scripted refusal or with a new
    /// connection handle that has its own quiet readiness descriptor.
    fn acceptNext(ctx: *anyopaque, _: *anyopaque) external.Finished {
        const self = of(ctx);
        self.accept_calls += 1;
        self.wake.drain() catch return .{ .failed = error.ProviderIo };
        if (self.accept_error) |err| return .{ .failed = err };
        if (self.accepts_issued == max_dials) return .{ .failed = error.ProviderIo };
        const wake = net.wake_channel.WakeChannel.open() catch return .{ .failed = error.ProviderIo };
        self.accept_wakes[self.accepts_issued] = wake;
        self.accepts_issued += 1;
        return .{ .ready = .{ .ptr = &self.accept_wakes[self.accepts_issued - 1], .fd = wake.read } };
    }

    fn tryRead(_: *anyopaque, _: *anyopaque, _: []u8) net.completion.TryRead {
        return .would_block;
    }

    fn connClose(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).conn_closes += 1;
    }

    /// A dial that stays pending on its own wake channel until closed.
    fn startConnect(ctx: *anyopaque, _: model.PeerLocator) external.Started {
        const self = of(ctx);
        if (self.dials_started == max_dials) return .{ .failed = error.ProviderIo };
        const wake = net.wake_channel.WakeChannel.open() catch return .{ .failed = error.ProviderIo };
        self.dial_wakes[self.dials_started] = wake;
        self.dials_started += 1;
        return .{ .pending = .{ .ptr = &self.dial_wakes[self.dials_started - 1], .fd = wake.read } };
    }

    fn cancelConnect(ctx: *anyopaque, _: *anyopaque) void {
        of(ctx).dial_cancels += 1;
    }

    fn unreachableFinish(_: *anyopaque, _: *anyopaque) external.Finished {
        unreachable;
    }

    fn unreachableWrite(_: *anyopaque, _: *anyopaque, _: []const u8) net.completion.TryWrite {
        unreachable;
    }

    const vtable: external.VTable = .{
        .start_connect = startConnect,
        .finish_connect = unreachableFinish,
        .cancel_connect = cancelConnect,
        .listen = listen,
        .finish_listen = finishListen,
        .cancel_listen = cancelListen,
        .listener_close = listenerClose,
        .accept = acceptNext,
        .try_read = tryRead,
        .try_write = unreachableWrite,
        .conn_close = connClose,
    };

    fn closeDialWakes(self: *Script) void {
        for (self.dial_wakes[0..self.dials_started]) |wake| wake.deinit();
        for (self.accept_wakes[0..self.accepts_issued]) |wake| wake.deinit();
    }

    fn provider(self: *Script) external.Provider {
        return .{ .transport = transport, .ctx = self, .vtable = &vtable };
    }

    fn handle(self: *Script) external.Handle {
        return .{ .ptr = self, .fd = self.wake.read };
    }
};

const max_dials = 64;

const target: Backend.ListenTarget = .{ .provider = .{ .transport = transport, .designator = "endpoint" } };

fn expectNamed(chain: ?foundation.FailureChain) !void {
    const got = chain orelse return error.NoChain;
    try std.testing.expectEqualStrings("AddressInUse", got.primaryName());
    try std.testing.expectEqual(error.ProviderIo, got.cause);
}

fn newBackend(providers: []const external.Provider) !Backend {
    const allocator = std.testing.allocator;
    return Backend.initWithPlatform(allocator, .{ .providers = providers }, try net.Backend.init(allocator, 8, 2, 256), 2, 256);
}

const none: ?foundation.FailureChain = null;

fn newScript(start: external.ListenStarted) !Script {
    return .{ .wake = try net.wake_channel.WakeChannel.open(), .start = start, .finish = .{ .failed = named } };
}

/// The one completion the backend owes, within five seconds.
fn nextCompletion(backend: *Backend) !net.completion.Completion {
    var out: [4]net.completion.Completion = undefined;
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const n = try backend.poll(&out, 10);
        if (n == 0) continue;
        try std.testing.expectEqual(@as(usize, 1), n);
        return out[0];
    }
    return error.CompletionTimedOut;
}

test "a refused provider listen answers with its chain until the next open" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(.{ .failed = named });
    defer script.wake.deinit();
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    defer backend.deinit();

    try std.testing.expectError(error.ProviderIo, backend.openListener(target));
    try expectNamed(backend.listenFailure(null));

    script.start = .{ .ready = script.handle() };
    const fd = try backend.openListener(target);
    try std.testing.expectEqual(none, backend.listenFailure(null));
    try std.testing.expectEqual(none, backend.listenFailure(fd));

    // The backend refuses a second listener itself, so no provider chain exists.
    try std.testing.expectError(error.AddressInUse, backend.openListener(target));
    try std.testing.expectEqual(none, backend.listenFailure(null));
    try std.testing.expectEqual(@as(usize, 2), script.listen_calls);

    try backend.submitClose(9, fd);
    try std.testing.expectEqual(@as(u64, 9), (try nextCompletion(&backend)).user_data);
    try std.testing.expectEqual(@as(usize, 1), script.close_calls);
}

test "a listener whose finish failed holds its chain and its seat until it is closed" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    script.start = .{ .pending = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    defer backend.deinit();

    const fd = try backend.openListener(target);
    try std.testing.expect(backend.listenerPending(fd));
    try backend.submitListenReady(7, fd);
    _ = try script.wake.nudge();

    const failed = try nextCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 7), failed.user_data);
    try std.testing.expect(failed.result < 0);
    try std.testing.expectEqual(error.ProviderIo, failed.failure.?);
    try std.testing.expect(!backend.listenerPending(fd));
    try expectNamed(backend.listenFailure(fd));
    // Another listener's descriptor and a refused open are different failures.
    try std.testing.expectEqual(none, backend.listenFailure(fd + 1));
    try std.testing.expectEqual(none, backend.listenFailure(null));

    // A listen that arrives before the failed one is closed finds the seat
    // taken, reaches no provider, and leaves the chain where it was.
    try std.testing.expectError(error.AddressInUse, backend.openListener(target));
    try std.testing.expectEqual(@as(usize, 1), script.listen_calls);
    try expectNamed(backend.listenFailure(fd));
    try std.testing.expectError(error.ListenerClosed, backend.submitAccept(8, fd));
    // A late setup wait learns the same failure.
    try backend.submitListenReady(11, fd);
    const late = try nextCompletion(&backend);
    try std.testing.expectEqual(@as(u64, 11), late.user_data);
    try std.testing.expectEqual(error.ProviderIo, late.failure.?);

    try backend.submitClose(9, fd);
    try std.testing.expectEqual(@as(u64, 9), (try nextCompletion(&backend)).user_data);
    try std.testing.expectEqual(none, backend.listenFailure(fd));
    // The provider consumed the attempt when its finish refused.
    try std.testing.expectEqual(@as(usize, 0), script.cancel_calls);

    script.start = .{ .ready = script.handle() };
    const reopened = try backend.openListener(target);
    try backend.submitClose(10, reopened);
    try std.testing.expectEqual(@as(u64, 10), (try nextCompletion(&backend)).user_data);
}

test "releasing a listener whose finish failed frees its seat without a provider verb" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    script.start = .{ .pending = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    // The backend asserts at deinit that no listener row remains.
    defer backend.deinit();

    const fd = try backend.openListener(target);
    try backend.submitListenReady(7, fd);
    _ = try script.wake.nudge();
    try std.testing.expect((try nextCompletion(&backend)).result < 0);

    backend.closeFd(fd);
    try std.testing.expectEqual(none, backend.listenFailure(fd));
    try std.testing.expectEqual(@as(usize, 0), script.cancel_calls);
    try std.testing.expectEqual(@as(usize, 0), script.close_calls);
}

test "a refused ready-queue seat at the first accept submission leaves no seat and a retryable listener" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    script.start = .{ .ready = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var backend = try newBackend(&providers);
    defer backend.deinit();

    const fd = try backend.openListener(target);
    // The queue holds no capacity beyond its seats, as it does whenever it has
    // been released: the accept's seat is then new allocation.
    try std.testing.expectEqual(@as(usize, 0), backend.ready.len());
    try std.testing.expectEqual(@as(usize, 0), backend.ready.reserved);
    backend.ready.items.clearAndFree(backend.allocator);

    const healthy = backend.allocator;
    var failing = std.testing.FailingAllocator.init(healthy, .{ .fail_index = 0, .resize_fail_index = 0 });
    backend.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, backend.submitAccept(5, fd));
    backend.allocator = healthy;
    try std.testing.expect(failing.has_induced_failure);
    // Nothing was admitted: no seat held, no accept armed, no poll armed.
    try std.testing.expectEqual(@as(usize, 0), backend.ready.reserved);
    try std.testing.expect(backend.listener.?.accept_ud == null);

    // The same call succeeds once memory returns: the refusal committed nothing.
    try backend.submitAccept(5, fd);
    try std.testing.expectEqual(@as(?u64, 5), backend.listener.?.accept_ud);
    try backend.submitClose(9, fd);
    // The close answers, and the cancelled accept with it.
    var out: [4]net.completion.Completion = undefined;
    var closed = false;
    var polls: usize = 0;
    while (!closed and polls < 500) : (polls += 1) {
        const n = try backend.poll(&out, 10);
        for (out[0..n]) |comp| closed = closed or comp.user_data == 9;
    }
    try std.testing.expect(closed);
}

const Resident = net.completion_resident.Resident(Backend, external.ResidentPolicy(Backend, external.PlatformRefused(net.Backend)));

/// One park of the resident: stage work, then wait briefly on its descriptor.
fn parkOnce(resident: *Resident) !void {
    const r = resident.resident();
    r.beforeWait(.park);
    if (r.readyPending()) return;
    var fds = [_]std.posix.pollfd{.{ .fd = r.readinessFd(), .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, 10);
}

const wait_budget_ms: i64 = 10_000;

/// Drain what the resident has ready now and count its accept records for
/// `route`. Any other record is a failure.
fn drainAcceptRecords(resident: *Resident, route: usize) !usize {
    var out: [16]net.multiplexed_resident.ReadyEvent = undefined;
    var accepts: usize = 0;
    for (try resident.resident().drainReady(&out)) |event| {
        try std.testing.expectEqual(route, event.subject);
        try std.testing.expect(event.events & net.multiplexed_resident.ev_accept != 0);
        accepts += 1;
    }
    return accepts;
}

test "an established external listener at the unclaimed bound owes its re-arm when the claim meets backend pressure" {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    defer script.closeDialWakes();
    script.start = .{ .ready = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var resident = try Resident.init(allocator, try Backend.initWithPlatform(allocator, .{ .providers = &providers }, try net.Backend.init(allocator, 256, 16, 256), 16, 256), .{});
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("external resident drain failed: {t}", .{err});
        resident.deinit();
    }
    const ops = resident.resident().vtable;
    const listener = switch (ops.listen.?.listen(&resident, 7, transport, .{ .designator = "endpoint" })) {
        .admitted => |admitted| admitted.ready,
        .failed => |failure| return failure.cause,
    };
    const row: *Resident.Listener = @ptrCast(@alignCast(listener));
    try std.testing.expect(row.accept_armed);
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;

    // A transient provider refusal is re-armed at once, with its seat.
    script.accept_error = error.ConnectionAborted;
    _ = try script.wake.nudge();
    while (script.accept_calls == 0) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.ArrivalNeverCompleted;
        try parkOnce(&resident);
    }
    script.accept_error = null;
    try std.testing.expect(row.accept_armed);
    try std.testing.expect(!row.rearm_owed);
    try std.testing.expectEqual(@as(usize, 1), resident.accept_seats);
    // The refused arrival left no readiness record behind it.
    try std.testing.expectEqual(@as(usize, 0), try drainAcceptRecords(&resident, 7));

    // Real accepted handles, one per nudge, until the listener waits for a claim.
    const bound = Resident.max_unclaimed_accepts;
    for (0..bound) |i| {
        _ = try script.wake.nudge();
        while (row.accepted.items.len == i) {
            if (net.clock.nowMonotonicMs() >= deadline) return error.ArrivalNeverCompleted;
            try parkOnce(&resident);
        }
    }
    try std.testing.expect(!row.accept_armed);
    try std.testing.expectEqual(@as(usize, 0), resident.accept_seats);
    try std.testing.expectEqual(bound, script.accepts_issued);

    // Other pending dials, each a real request with its own handle and seat,
    // take the backend queue's spare capacity.
    const peer: model.PeerLocator = .hintless(transport, "peer");
    var requests: usize = 0;
    while (resident.backend.ready.reserved < resident.backend.ready.items.capacity) : (requests += 1) {
        try std.testing.expect(ops.dial.?.start_connect(&resident, 5000 + requests, peer, .{}, .application) == .admitted);
    }
    try std.testing.expectEqual(requests, script.dials_started);
    const reserved = resident.backend.ready.reserved;

    // The claim re-arms first, and its seat is the refused growth. The
    // claimed connection is still adopted.
    const healthy = resident.backend.allocator;
    var failing = std.testing.FailingAllocator.init(healthy, .{ .fail_index = 0, .resize_fail_index = 0 });
    resident.backend.allocator = failing.allocator();
    const outcome = ops.listen.?.finish_accept(&resident, row);
    resident.backend.allocator = healthy;
    try std.testing.expect(failing.has_induced_failure);
    switch (outcome) {
        .connection => |id| try std.testing.expect(id != null),
        .failed => |failure| return failure.chain.cause,
    }
    try std.testing.expect(row.rearm_owed);
    try std.testing.expect(!row.accept_armed);
    try std.testing.expectEqual(@as(usize, 0), resident.accept_seats);
    try std.testing.expectEqual(@as(usize, 1), resident.rearm_owed_count);
    try std.testing.expectEqual(@as(?anyerror, null), resident.failure);
    try std.testing.expectEqual(bound - 1, row.accepted.items.len);
    try std.testing.expect(resident.backend.ready.reserved >= reserved);
    try std.testing.expectEqual(@as(usize, 0), script.dial_cancels);
    const retry = resident.resident().memoryRetry().?;
    try std.testing.expect(retry.owes());

    // The dials are released, and the one group retry re-arms the listener.
    for (0..requests) |i| _ = ops.dial.?.cancel_connect(&resident, 5000 + i);
    while (resident.backend.ready.reserved >= reserved) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.DialsNeverReleased;
        try parkOnce(&resident);
    }
    try std.testing.expectEqual(requests, script.dial_cancels);
    retry.retry();
    try std.testing.expect(row.accept_armed);
    try std.testing.expect(!row.rearm_owed);
    try std.testing.expectEqual(@as(usize, 1), resident.accept_seats);
    try std.testing.expectEqual(@as(usize, 0), resident.rearm_owed_count);
    try std.testing.expect(!retry.owes());
    try std.testing.expectEqual(@as(?anyerror, null), resident.failure);
}

/// A persistent provider refusal answers a real armed accept: the seat is
/// consumed, nothing re-arms, and the claim hands over the earlier arrival
/// first and the refusal with its original cause exactly once.
fn expectPersistentRefusal(refusal: anyerror) !void {
    if (!(builtin.target.os.tag == .linux or builtin.target.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var script = try newScript(undefined);
    defer script.wake.deinit();
    defer script.closeDialWakes();
    script.start = .{ .ready = script.handle() };
    const providers = [_]external.Provider{script.provider()};
    var resident = try Resident.init(allocator, try Backend.initWithPlatform(allocator, .{ .providers = &providers }, try net.Backend.init(allocator, 256, 16, 256), 16, 256), .{});
    defer {
        resident.closeAndDrain(2_000) catch |err| std.debug.panic("external resident drain failed: {t}", .{err});
        resident.deinit();
    }
    const ops = resident.resident().vtable.listen.?;
    const listener = switch (ops.listen(&resident, 7, transport, .{ .designator = "endpoint" })) {
        .admitted => |admitted| admitted.ready,
        .failed => |failure| return failure.cause,
    };
    const row: *Resident.Listener = @ptrCast(@alignCast(listener));
    const deadline = net.clock.nowMonotonicMs() + wait_budget_ms;

    // An arrival answered with a handle re-arms and takes its seat again.
    _ = try script.wake.nudge();
    while (row.accepted.items.len == 0) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.ArrivalNeverCompleted;
        try parkOnce(&resident);
    }
    try std.testing.expect(row.accept_armed);
    try std.testing.expectEqual(@as(usize, 1), resident.accept_seats);
    var accept_records = try drainAcceptRecords(&resident, 7);

    // The next arrival is refused for good.
    script.accept_error = refusal;
    _ = try script.wake.nudge();
    while (script.accept_calls < 2) {
        if (net.clock.nowMonotonicMs() >= deadline) return error.ArrivalNeverCompleted;
        try parkOnce(&resident);
    }
    try std.testing.expect(!row.accept_armed);
    try std.testing.expect(!row.rearm_owed);
    try std.testing.expectEqual(@as(usize, 0), resident.accept_seats);
    try std.testing.expectEqual(@as(usize, 0), resident.rearm_owed_count);
    try std.testing.expectEqual(@as(usize, 1), script.accepts_issued);
    // The runtime sees exactly two accept records: the arrival and the
    // refusal, and no third.
    accept_records += try drainAcceptRecords(&resident, 7);
    try std.testing.expectEqual(@as(usize, 2), accept_records);
    try std.testing.expectEqual(@as(usize, 0), try drainAcceptRecords(&resident, 7));

    switch (ops.finish_accept(&resident, listener)) {
        .connection => |id| try std.testing.expect(id != null),
        .failed => return error.LostEarlierAccept,
    }
    switch (ops.finish_accept(&resident, listener)) {
        .failed => |failure| {
            try std.testing.expectEqual(error.AcceptRefused, failure.classification);
            try std.testing.expectEqual(refusal, failure.chain.cause);
        },
        .connection => return error.LostAcceptRefusal,
    }
    // Handed over once, and the listener never re-armed against it.
    switch (ops.finish_accept(&resident, listener)) {
        .connection => |id| try std.testing.expectEqual(@as(?usize, null), id),
        .failed => return error.RefusalReportedTwice,
    }
    try std.testing.expect(!row.accept_armed);
    try std.testing.expectEqual(@as(usize, 2), script.accept_calls);
    try std.testing.expect(!resident.resident().memoryRetry().?.owes());
}

test "a descriptor quota refusal of an armed accept follows the earlier arrival and does not re-arm" {
    try expectPersistentRefusal(error.ProcessFdQuotaExceeded);
}

test "a provider carried allocation refusal of an armed accept stays a claimable failure" {
    try expectPersistentRefusal(error.OutOfMemory);
}
