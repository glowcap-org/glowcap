//! Readiness and wake edges (ADR-0024): a wire lost mid-handshake fails
//! through the dial observer, a silent connector cannot park a staged-accept
//! server, `stepAny` self-wakes over an incomplete feed tail, and
//! `wakeReadiness` raises the descriptor from another thread.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const harness = @import("harness.zig");
const FailureCapture = harness.FailureCapture;
const Treasure = harness.Treasure;
const stepServe = harness.stepServe;
const CloseFlag = harness.CloseFlag;
const DropSessionOnClose = harness.DropSessionOnClose;
const connectAndHold = harness.connectAndHold;
const RecordingSink = harness.RecordingSink;
const DialRecorder = harness.DialRecorder;
const opts = harness.opts;

test "a silent connector cannot park a staged-accept server: a healthy dial opens and settles beside it on one thread" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server_transports: driver.Transports = .{ .symbols = &.{.tcp} };

    // A server built the driver archive's way: a runtime-owned listener whose
    // accepts are staged by `stepAny`, never pumped.
    var server_runtime = try driver.HostRuntime.init(allocator, io, server_transports, .ephemeral, opts);
    defer server_runtime.deinit();
    var accepts = DialRecorder{};
    var listener = try server_runtime.bindListener(model.transport.tcp, "127.0.0.1:0", .inherit);
    var prepared = switch (server_runtime.prepareListenerLocatorOutcome(&listener)) {
        .ready => |value| value,
        .failed => |failure| {
            if (server_runtime.closeListener(&listener)) |cleanup| server_runtime.noteTerminalOperationFailure(cleanup);
            return failure.cause;
        },
    };
    const listener_locator = try model.clonePeerLocator(allocator, prepared.value);
    defer model.freePeerLocator(allocator, listener_locator);
    try server_runtime.activateOwnedListener(&listener, &prepared, 1, .{
        .ctx = &accepts,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    _ = try server_runtime.selectOwnedListener(1);
    try server_runtime.publish("treasure", Treasure, .{});

    // The silent connector arrives first: a raw TCP stream that never sends
    // a hello. A blocking accept would park the server inside its handshake
    // pump for the whole 10s budget the moment it is accepted.
    const address = try tcp.parseDesignator(listener_locator.designator);
    var silent = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer silent.close(io);

    const transports: driver.Transports = .{ .symbols = &.{.tcp} };
    var sink = RecordingSink{};
    var client_runtime = try driver.HostRuntime.init(
        allocator,
        io,
        transports,
        .ephemeral,
        harness.stepped(sink.sink(), harness.Quiet.observer()),
    );
    defer client_runtime.deinit();
    sink.core = client_runtime.core;
    var dials = DialRecorder{};

    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try client_runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 21, .{
        .ctx = &dials,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });

    var fetch_vow: u64 = 0;
    const started_ms = net.clock.nowMs(io);
    var rounds: usize = 0;
    while (sink.settled.load(.acquire) == 0 and rounds < 1_000) : (rounds += 1) {
        while (try server_runtime.stepAny(0) != null) {}
        _ = try client_runtime.stepAny(10);
        if (dials.opened_session != null and fetch_vow == 0) {
            fetch_vow = try client_runtime.core.fetch(dials.opened_session.?, "treasure");
        }
        try std.testing.expectEqual(@as(?anyerror, null), dials.failed_err);
    }
    const elapsed_ms = net.clock.nowMs(io) - started_ms;

    // The healthy conversation completed promptly, well inside the silent
    // connector's handshake budget, which a blocking accept would have spent
    // parked, and only the healthy accept opened.
    try std.testing.expectEqual(fetch_vow, sink.settled.load(.acquire));
    try std.testing.expect(fetch_vow != 0);
    try std.testing.expect(elapsed_ms < 3_000);
    try std.testing.expectEqual(@as(usize, 1), accepts.opened_count);
    try std.testing.expectEqual(@as(?anyerror, null), accepts.failed_err);
    try client_runtime.releaseWire(dials.opened_session.?);
}

test "stepAny self-wakes when a feed_tail still holds incomplete outer-frame bytes" {
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
        opts,
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var accept_future = try io.concurrent(struct {
        fn run(s: *driver.Server) !void {
            var session = try s.accept();
            defer session.deinit();
            try session.serve();
        }
    }.run, .{server});

    // The client is built stepped: its descriptor is read below, never armed.
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    var client = try driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        harness.steppedQuiet(),
    );
    defer {
        client.deinit();
        accept_future.await(io) catch {};
    }

    // Drain any connect-time wake so a leftover cannot fake the proof.
    _ = try client.runtime.stepAny(0);

    // An incomplete outer Syrup length prefix (`3:` declares three body
    // bytes that never arrive): parse retains the suffix in `feed_tail`,
    // which no readiness wait can see. Calibrate the pause before asking
    // the nudge to report it.
    try client.runtime.core.feedBytes(client.hs, "3:");
    try std.testing.expect(client.hs.pausedInboundPending());

    const ready_fd = try client.runtime.readinessDescriptor();
    // Resume leaves the incomplete tail, the park times out, and the nudge
    // must leave the aggregate descriptor readable.
    _ = try client.runtime.stepAny(0);
    try std.testing.expect(client.hs.pausedInboundPending());
    var fds = [_]std.posix.pollfd{
        .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 1), ready);
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);
}

test "wakeReadiness raises the descriptor from another thread, and a sessionless step parks instead of refusing" {
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
        harness.steppedQuiet(),
    );
    defer server.deinit();

    // No session exists: a step must park on its timeout and report a quiet
    // wait, not refuse with ConnectionClosed.
    try std.testing.expectEqual(@as(?net.Progress, null), try server.runtime.stepAny(0));

    const ready_fd = try server.runtime.readinessDescriptor();
    const waker = try std.Thread.spawn(.{}, struct {
        fn run(runtime: *driver.HostRuntime) void {
            runtime.wakeReadiness() catch unreachable;
        }
    }.run, .{server.runtime});
    var fds = [_]std.posix.pollfd{
        .{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&fds, 10_000);
    waker.join();
    try std.testing.expect(ready == 1);
    // The woken step drains the wake and reports quiet; the descriptor is no
    // longer readable afterward, so a parked embedder cannot spin on a
    // consumed wake.
    try std.testing.expectEqual(@as(?net.Progress, null), try server.runtime.stepAny(0));
    fds[0].revents = 0;
    const still_ready = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), still_ready);
}
