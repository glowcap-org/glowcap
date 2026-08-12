//! The off-turn settle mailbox (ADR-0102 stage 4) on both native tiers that
//! own a wait. The headline scenarios run a real worker `std.Thread`: a
//! served behavior defers its answer onto a resolver vow and parks the
//! resolver id; the worker posts the settle from its own thread; the owning
//! thread's wait wakes through the mailbox's socketpair, applies the settle,
//! and the caller's blocked call completes — over `driver.HostRuntime`'s poll
//! wait, and over `net.TcpLoop` + `driver.Bridge`'s completion wait. The
//! units pin the post-side refusals: a full mailbox, an oversized payload,
//! and a capability in a plain-data settle, each loud.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;
const ip = std.Io.net;

const Host = driver.core.Host;
const TcpBridge = driver.Bridge(net.TcpLoop);

const frame_cap = 4096;

const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

// --- Post-side refusals (no host, no thread) --------------------------------

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
    const big = [_]u8{'x'} ** (driver.settle_mailbox.slot_payload_bytes + 1);
    try std.testing.expectError(
        error.ValueTooLarge,
        mb.post(io, 1, .{ .fulfilled = .{ .string = &big } }),
    );
    // One slot: the second unapplied post is backpressure, not growth.
    try mb.post(io, 1, .{ .broken = "first" });
    try std.testing.expectError(error.MailboxFull, mb.post(io, 2, .{ .broken = "second" }));
}

// --- The shared deferring behavior and worker -------------------------------

/// The owning-tier deferring behavior (Host): the turn wrapper carries
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

/// The vat-tier sibling (the bridge publishes through `Served.publish`).
const DeferringVat = struct {
    core: *Host,
    session: *driver.core.HostSession,
    out: *std.atomic.Value(u64),

    pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = msg;
        self.out.store(try self.core.deferTurn(self.session, turn), .release);
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

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    // Mint the mailbox before any pump runs, hand it to the worker thread.
    const mb = try server.runtime.settleMailbox();
    var parked = std.atomic.Value(u64).init(0);
    var worker_stop = std.atomic.Value(bool).init(false);
    const worker_thread = try std.Thread.spawn(.{}, worker, .{ mb, &parked, &worker_stop });

    var host_future = try io.concurrent(hostRuntimeServe, .{ &server, &parked });

    const client_result = blk: {
        const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const client = driver.connect(
            allocator,
            &netlayers,
            tcp.locator(&designator_buf, address),
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

// --- Bridge + TcpLoop: the completion wait wakes on the same fd -------------

const LoopState = struct {
    host: *Host,
    out: *std.atomic.Value(u64),
};

fn publishWorker(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *LoopState = @ptrCast(@alignCast(ctx.?));
    const session: *driver.core.HostSession = @alignCast(@fieldParentPtr("served", served));
    _ = try served.publish(vat, "worker", DeferringVat, .{ .core = state.host, .session = session, .out = state.out });
}

const LoopShared = struct {
    port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn loopServerTask(
    allocator: std.mem.Allocator,
    shared: *LoopShared,
    mb: *driver.SettleMailbox,
    parked: *std.atomic.Value(u64),
) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = test_host.init(allocator, [_]u8{0x4d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var state = LoopState{ .host = &host, .out = parked };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishWorker,
        .publish_ctx = &state,
    });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const bound = tcp.locator(&designator_buf, bound_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), bound, &.{});
    try bridge.attachSettleMailbox(mb);
    shared.port.store(loop.port().?, .release);

    try loop.runUntil(&shared.done, 30_000);
    loop.closeAndDrain() catch {};
}

test "off-turn settle over the completion loop: the wake recv applies the worker's post on the loop thread" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mb = try driver.SettleMailbox.init(allocator, driver.settle_mailbox.default_slots);
    var shared = LoopShared{};
    var parked = std.atomic.Value(u64).init(0);
    var worker_stop = std.atomic.Value(bool).init(false);
    const worker_thread = try std.Thread.spawn(.{}, worker, .{ mb, &parked, &worker_stop });

    var server_future = try io.concurrent(loopServerTask, .{ allocator, &shared, mb, &parked });

    const client_result = blk: {
        var port: u16 = 0;
        while (true) {
            port = shared.port.load(.acquire);
            if (port != 0) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
        }
        var tcp_resident = tcp.Resident{ .io = io };
        const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
        const address = tcp.parseHostPort("127.0.0.1", port) catch |err| break :blk err;
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const client = driver.connect(
            allocator,
            &netlayers,
            tcp.locator(&designator_buf, address),
            .ephemeral,
            dial_opts,
        ) catch |err| break :blk err;
        defer client.deinit();
        clientAsserts(client, allocator) catch |err| break :blk err;
        break :blk {};
    };

    worker_stop.store(true, .release);
    worker_thread.join();
    // Stop the loop through the mailbox's own wake — the stopper's share of
    // the sanctioned cross-thread entry, not a connect-and-drop.
    shared.done.store(true, .release);
    mb.wake();
    const server_result = server_future.await(io);
    mb.deinit();
    try client_result;
    try server_result;
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
    mb.drainWake();
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

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(
        allocator,
        tcp_resident.netlayer(),
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        dial_opts,
    );
    defer server.close() catch {};
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const mb = try server.runtime.settleMailbox();
    var parked = std.atomic.Value(u64).init(0);
    var done = std.atomic.Value(bool).init(false);
    const worker_thread = try std.Thread.spawn(.{}, workerSwallowingItsWake, .{ mb, &parked });
    var host_future = try io.concurrent(hostRuntimeServeStepping, .{ &server, &parked, &done });

    const client_result = blk: {
        const netlayers = [_]net.netlayer.Netlayer{tcp_resident.netlayer()};
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const client = driver.connect(
            allocator,
            &netlayers,
            tcp.locator(&designator_buf, address),
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
