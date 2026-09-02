//! `driver.Bridge` budgets and lifecycle: a flooding client's session
//! closes with the typed resource_exhausted abort while a sibling keeps
//! answering, a second attach is refused, an extension transport symbol is
//! retained without a private length ceiling, closeAndDrain and runUntil
//! settle honestly, an unsupported dial reports as such, and a failed
//! admission allocation releases the owned request.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);
const wait = @import("../support/wait.zig");

const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite on purpose:
/// an unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

// ── The theorem: three-party handoff across two connections of one loop ─────

const bridge_shared = @import("bridge_test.zig");
const support_actors = @import("../support/actors.zig");
const runLoopCapturing = bridge_shared.runLoopCapturing;
const runLoopUntilCapturing = bridge_shared.runLoopUntilCapturing;
const pokeListener = bridge_shared.pokeListener;
const drainLoopThread = bridge_shared.drainLoopThread;

const Counter = support_actors.Counter;

const runaway_budget: usize = 4;

/// One `flood` queues more local turns than the budget admits.
const SelfFlood = struct {
    amp: actors.Ref,
    pub fn handle(self: *SelfFlood, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        var i: usize = 0;
        while (i < runaway_budget + 2) : (i += 1) {
            try turn.tell(self.amp, .{ .verb = "hit", .args = &.{} });
        }
        return .{ .boolean = true };
    }
};

fn publishRunaway(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    _ = ctx;
    const amp = try vat.spawn(Counter, .{});
    _ = try served.publish(vat, "flood", SelfFlood, .{ .amp = amp });
    _ = try served.publish(vat, "echo", Counter, .{});
}

test "budget runaway over the bridge: the flooding connection closes typed, a sibling keeps answering" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x0b)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = runaway_budget,
    });
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{ .publish = publishRunaway });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), designator, &.{});

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopCapturing, .{ &loop, @as(usize, 2), &loop_err, &loop_done });
    defer {
        drainLoopThread(io, loop.port().?, &loop_done) catch |err| std.debug.print("drain loop: {s}\n", .{@errorName(err)});
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("bridge loop: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };

    // The sibling connects first and stays healthy throughout.
    const sibling_session = try driver.connect(allocator, &.{resident.netlayer()}, .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, dial_opts);
    defer sibling_session.deinit();
    const echo = try sibling_session.fetch("echo");

    // The flooder: its one call amplifies past the budget, so the host
    // condemns the connection and the bridge closes it — the answer breaks
    // with the typed abort's own words.
    {
        const flood_session = try driver.connect(allocator, &.{resident.netlayer()}, .{
            .transport = tcp.transport_name,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        }, .ephemeral, dial_opts);
        defer flood_session.deinit();
        const flood = try flood_session.fetch("flood");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        // The flood's own answer may still fulfill: the reply resolves at
        // dispatch, and the budget breach is discovered in the pump right
        // after. What the budget guarantees is what follows — the connection
        // is condemned and closed with the typed abort. (The abort *kind* is
        // pinned hermetically in core_host_budget_test.zig.)
        _ = flood_session.call(flood, "flood", &.{}, arena.allocator()) catch {};
        var polls: usize = 0;
        while (flood_session.abortReason() == null and polls < 500) : (polls += 1) {
            _ = flood_session.stepReadable(10) catch break;
        }
        const reason = flood_session.abortReason() orelse return error.NoBudgetAbort;
        try std.testing.expect(std.mem.indexOf(u8, reason, "local turn budget") != null);
    }

    // The sibling still gets ordinary answers after the flooder was closed.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try sibling_session.call(echo, "hit", &.{}, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqual(@as(i64, 1), arg.integer),
        .broken => |reason| {
            std.debug.print("echo broke: {s}\n", .{reason});
            return error.EchoBroke;
        },
    }
}

test "a second attach is refused" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{});
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 2,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), designator, &.{});
    try std.testing.expectError(
        error.AlreadyAttached,
        bridge.attach(model.transport.Known.tcp.metadata(), designator, &.{}),
    );
}

test "bridge retains an extension transport symbol without a private length ceiling" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, threaded.io(), &loop, .{});
    defer bridge.deinit();

    const transport = "application-defined-transport";
    try bridge.attach(.{ .symbol = transport, .designator_scheme = .address }, "listener-address", &.{});
    const advertised = host.advertisedLocator(transport) orelse
        return error.MissingAdvertisedLocator;
    try std.testing.expectEqualStrings(transport, advertised.transport);
}

test "closeAndDrain: one live accepted connection with an armed recv" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x0b)), blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{ .publish = publishRunaway });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 4,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), designator, &.{});

    var done = std.atomic.Value(bool).init(false);
    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(struct {
        fn run(l: *net.TcpLoop, d: *const std.atomic.Value(bool), e: *?anyerror, f: *std.atomic.Value(bool)) void {
            l.runUntil(d, 0) catch |err| {
                e.* = err;
                f.store(true, .release);
                return;
            };
            l.closeAndDrain() catch |err| {
                e.* = err;
            };
            f.store(true, .release);
        }
    }.run, .{ &loop, &done, &loop_err, &loop_done });

    var resident = tcp.Resident{ .io = io };
    const client = try driver.connect(allocator, &.{resident.netlayer()}, .{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, dial_opts);
    defer client.deinit();
    _ = try client.fetch("echo");

    done.store(true, .release);
    pokeListener(io, loop.port().?);
    try drainLoopThread(io, loop.port().?, &loop_done);
    loop_future.await(io);
    if (loop_err) |err| return err;
}

test "Bridge reports a keyed-relay dial to a TCP-only loop as unsupported" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var seed: [32]u8 = undefined;
    @memset(&seed, 0x42);
    var host = test_host.init(allocator, seed, .{ .limits = .{ .max_frame_bytes = frame_cap } });
    defer host.deinit();

    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{});
    defer bridge.deinit();
    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 4,
        .listen = 0,
    }));
    defer loop.deinit();

    try bridge.attach(model.transport.Known.tcp.metadata(), "127.0.0.1:1", &.{});

    const key = glowcap.foundation.crypto.SecretKey.fromSeed(@as([32]u8, @splat(0xab))).publicKey().toDesignator();
    try std.testing.expectError(
        error.UnknownTransport,
        bridge.dialOutbound(.{
            .transport = model.transport.keyed_relay,
            .designator = key[0..],
            .hints = model.Hints.emptyFalse(),
        }),
    );
}

test "Bridge application dial releases its owned request when admission allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x5a)), .{});
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(failing.allocator(), &host, threaded.io(), &loop, .{});
    defer bridge.deinit();

    // Two string copies succeed; reserving the pending-connect row fails.
    // The dial request owns both copies before that reservation begins.
    try std.testing.expectError(
        error.OutOfMemory,
        bridge.dialOutbound(.{
            .transport = tcp.transport_name,
            .designator = "127.0.0.1:1",
            .hints = model.Hints.emptyFalse(),
        }),
    );
}

test "closeAndDrain: idle listener then deinit with the testing allocator" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();
    try loop.closeAndDrain();
}

test "runUntil: cross-thread done needs a listener poke, then deinit is honest" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, null, .{
        .max_conns = 4,
        .listen = 0,
    });
    defer loop.deinit();

    var done = std.atomic.Value(bool).init(false);
    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopUntilCapturing, .{ &loop, &done, &loop_err, &loop_done });

    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    done.store(true, .release);
    pokeListener(io, loop.port().?);
    try drainLoopThread(io, loop.port().?, &loop_done);
    loop_future.await(io);
    if (loop_err) |err| return err;
}
