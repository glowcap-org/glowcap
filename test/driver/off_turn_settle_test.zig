//! The off-turn settle mailbox (ADR-0102 stage 4) on `driver.HostRuntime`.
//! The headline scenarios run a real worker `std.Thread`: a served behavior
//! defers its answer onto a resolver vow and parks the resolver id; the worker
//! posts the settle from its own thread; the owning thread's poll wait wakes
//! through the mailbox's socketpair, applies the settle, and the caller's
//! blocked call completes, including when the wake byte never wins the poll.
//! The units pin the post-side refusals: a full mailbox, an oversized payload,
//! and a capability in a plain-data settle, each loud.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const frame_cap = 4096;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

// --- Post-side refusals (no host, no thread) --------------------------------

test "settle mailbox rolls back a post whose wake fails" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const mailbox = try driver.SettleMailbox.init(std.testing.allocator, 1);
    defer mailbox.deinit();

    _ = std.posix.system.close(mailbox.channel.write);
    mailbox.channel.write = -1;

    try std.testing.expectError(
        error.WakeNudgeFailed,
        mailbox.post(threaded.io(), 1, .{ .broken = "not admitted" }),
    );
    try std.testing.expectEqual(@as(usize, 0), mailbox.count);
}

test "settle mailbox: full, oversized, and capability-bearing posts refuse loudly" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const mb = try driver.SettleMailbox.init(allocator, 1);
    defer mb.deinit();

    // A capability never crosses threads.
    try std.testing.expectError(
        error.NotPlainData,
        mb.post(io, 1, .{ .fulfilled = .{ .reference = .{ .far = model.FarRef.object(5) } } }),
    );
    // A payload past the slot's fixed storage refuses; the slot stays free.
    const big = @as([driver.settle_mailbox.slot_payload_bytes + 1]u8, @splat('x'));
    try std.testing.expectError(
        error.ValueTooLarge,
        mb.post(io, 1, .{ .fulfilled = .{ .string = &big } }),
    );
    // One slot: the second unapplied post is backpressure, not growth.
    try mb.post(io, 1, .{ .broken = "first" });
    try std.testing.expectError(error.MailboxFull, mb.post(io, 2, .{ .broken = "second" }));
}

// --- The shared deferring behavior and worker -------------------------------

/// The deferring behavior: the Host turn wrapper carries
/// the host, so the behavior mints, defers, and parks with no captured state
/// beyond the worker's shared slot.
const DeferringOwned = struct {
    out: *std.atomic.Value(u64),

    pub fn handle(self: *@This(), ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = verb;
        _ = args;
        self.out.store(try ht.deferAnswer(), .release);
        return .{ .void = {} };
    }
};

/// The worker: real off-thread completion. Waits for each parked resolver id
/// and posts its settle from this thread — first fulfilled, then broken.
fn worker(
    mb: *driver.SettleMailbox,
    out: *std.atomic.Value(u64),
    stop: *const std.atomic.Value(bool),
) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (0..2) |round| {
        var id: u64 = 0;
        while (true) {
            if (stop.load(.acquire)) return;
            id = out.load(.acquire);
            if (id != 0) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
        }
        out.store(0, .release);
        if (round == 0) {
            mb.post(io, id, .{ .fulfilled = .{ .string = "computed off-thread" } }) catch unreachable;
        } else {
            mb.post(io, id, .{ .broken = "worker gave up" }) catch unreachable;
        }
    }
}

/// Call the worker twice through `client` and assert both settle arms crossed.
fn clientAsserts(client: *driver.Session, allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const worker_ref = try client.fetch("worker");
    const settled = try client.call(worker_ref, "work", &.{}, arena.allocator());
    try std.testing.expect(settled == .fulfilled and settled.fulfilled == .string);
    try std.testing.expectEqualStrings("computed off-thread", settled.fulfilled.string);

    const broken = try client.call(worker_ref, "work", &.{}, arena.allocator());
    try std.testing.expect(broken == .broken);
    try std.testing.expect(std.mem.indexOf(u8, broken.broken, "worker gave up") != null);
}

// --- HostRuntime: the poll wait wakes on the mailbox fd -----------------

fn hostRuntimeServe(server: *driver.Server, out: *std.atomic.Value(u64)) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("worker", DeferringOwned, .{ .out = out });
    try session.serve();
}

test "off-turn settle over HostRuntime: a worker thread's post wakes the poll wait and the blocked call completes" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    // Mint the mailbox before any pump runs, hand it to the worker thread.
    const mb = try server.runtime.settleMailbox();
    var parked = std.atomic.Value(u64).init(0);
    var worker_stop = std.atomic.Value(bool).init(false);
    const worker_thread = try std.Thread.spawn(.{}, worker, .{ mb, &parked, &worker_stop });

    var host_future = try io.concurrent(hostRuntimeServe, .{ server, &parked });

    const client_result = blk: {
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const client = driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            tcp.locatorFromAddress(&designator_buf, address),
            .ephemeral,
            dial_opts,
        ) catch |err| break :blk err;
        defer client.deinit();
        clientAsserts(client, allocator) catch |err| break :blk err;
        break :blk {};
    };

    worker_stop.store(true, .release);
    worker_thread.join();
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// Serve with bounded steps rather than `serve`'s unbounded poll, so a
/// swallowed wake cannot park this thread forever — the point under test is
/// where the settle is applied, not whether a wake can end a wait.
fn hostRuntimeServeStepping(
    server: *driver.Server,
    out: *std.atomic.Value(u64),
    done: *std.atomic.Value(bool),
) anyerror!void {
    const session = try server.accept();
    defer session.deinit();
    _ = try session.publish("worker", DeferringOwned, .{ .out = out });
    try session.attend();
    while (!done.load(.acquire)) {
        const progress = session.runtime.stepSession(session.hs, 25) catch break;
        if (progress) |p| if (p == .closed) break;
    }
}

/// Post the settle and immediately consume the wake byte it wrote, so the
/// owning thread's poll can never select the mailbox row. Applying has to
/// come from the pump's own loop top or not at all.
fn workerSwallowingItsWake(mb: *driver.SettleMailbox, out: *std.atomic.Value(u64)) void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var id: u64 = 0;
    while (id == 0) {
        id = out.load(.acquire);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
    mb.post(io, id, .{ .fulfilled = .{ .string = "applied at the loop top" } }) catch unreachable;
    mb.drainWake() catch unreachable;
}

test "off-turn settle applies at the pump top, not only when the wake wins the poll" {
    // The regression that matters for stage 4 under load. The wake fd rides
    // the poll set as its last row, and a readiness wait reports the *first*
    // ready row, so a busy wire preempts it every pass. If applying depended
    // on that row being selected, a peer with sustained traffic would starve
    // its own mailbox until it filled — exactly the case the mechanism
    // exists for.
    //
    // Swallowing the wake byte is the deterministic form of that race: the
    // poll has nothing to select. The settle must still land, because
    // applying belongs to the top of the pump loop rather than to a poll
    // result.
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const mb = try server.runtime.settleMailbox();
    var parked = std.atomic.Value(u64).init(0);
    var done = std.atomic.Value(bool).init(false);
    const worker_thread = try std.Thread.spawn(.{}, workerSwallowingItsWake, .{ mb, &parked });
    var host_future = try io.concurrent(hostRuntimeServeStepping, .{ server, &parked, &done });

    const client_result = blk: {
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const client = driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            tcp.locatorFromAddress(&designator_buf, address),
            .ephemeral,
            dial_opts,
        ) catch |err| break :blk err;
        defer client.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const worker_ref = client.fetch("worker") catch |err| break :blk err;
        const settled = client.call(worker_ref, "work", &.{}, arena.allocator()) catch |err| break :blk err;
        if (settled != .fulfilled) break :blk error.SettleNeverApplied;
        break :blk {};
    };

    worker_thread.join();
    done.store(true, .release);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}
