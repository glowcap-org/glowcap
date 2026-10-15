//! The host-wide step surface (ADR-0112), served: a server pumped only by
//! the aggregate readiness descriptor and `stepAny` carries a whole budgeted
//! CapTP conversation, failures classify at the I/O-owning driver, close
//! stops admission while a yielded session retains the runtime, the close
//! observer hears a partner EOF, an unparked vow reaches the completion
//! sink, and a refusing open observer settles failure cleanly.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const frame_cap = 8192;

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

test "attendance failure settles registered reply listeners before the wait frame unwinds" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, harness.steppedQuiet());
    defer server.deinit();
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));
    var stop = std.atomic.Value(bool).init(false);
    var client = try io.concurrent(connectAndHold, .{ allocator, io, address, &stop });
    defer {
        stop.store(true, .release);
        client.await(io) catch {};
    }
    const accepted = try server.accept();
    defer accepted.deinit();
    const promise = try accepted.beginFetch("pending");
    defer promise.release() catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Fail the wait itself. The pending reply already has a stack listener
    // by the time attendance waits on this readiness set.
    accepted.runtime.drive.stepped.ready_set.wake_failure.record(error.WakeDrainFailed);
    try std.testing.expectError(error.WakeDrainFailed, promise.settle(arena.allocator()));
    // Settlement retires the vow row and its listener. A failed attendance
    // must leave no listener pointing into the now-returned wait frame.
    try std.testing.expectError(error.NoSuchVow, accepted.runtime.core.vowSession(promise.id));
}

test "Zig operation failures classify at the I/O-owning driver" {
    const Failure = driver.OperationFailure;
    try std.testing.expectEqual(Failure.Kind.internal, Failure.classify(error.OutOfMemory));
    try std.testing.expectEqual(Failure.Kind.invalid_argument, Failure.classify(error.ProviderContract));
    try std.testing.expectEqual(Failure.Kind.invalid_argument, Failure.classify(error.InvalidAddress));
    try std.testing.expectEqual(Failure.Kind.invalid_argument, Failure.classify(error.InvalidBufferConfiguration));
    try std.testing.expectEqual(Failure.Kind.invalid_argument, Failure.classify(error.SessionNotOwned));
    try std.testing.expectEqual(Failure.Kind.would_block, Failure.classify(error.PendingOpenLimitReached));
    try std.testing.expectEqual(Failure.Kind.timeout, Failure.classify(error.HandshakeTimedOut));
    try std.testing.expectEqual(Failure.Kind.closed, Failure.classify(error.Canceled));
    try std.testing.expectEqual(Failure.Kind.io, Failure.classify(error.ConnectionLost));
    try std.testing.expectEqual(Failure.Kind.malformed, Failure.classify(error.TruncatedFrame));
    try std.testing.expectEqual(Failure.Kind.malformed, Failure.classify(error.MalformedFrame));
    try std.testing.expectEqual(Failure.Kind.frame_too_large, Failure.classify(error.FrameTooLarge));
    try std.testing.expectEqual(Failure.Kind.session, Failure.classify(error.ProtocolAbort));
    try std.testing.expectEqual(Failure.Kind.io, Failure.classify(error.ConnectionRefused));
}

test "Zig operation failures can retain archive-crossing cause names" {
    var failure = driver.OperationFailure.fromError(error.ProviderIo);
    failure.namePrimary("TcpReadFailed");
    failure.noteNamed(error.ProviderInternal, "SocketReleaseFailed");
    try std.testing.expectEqualStrings("TcpReadFailed", failure.primaryName());
    try std.testing.expectEqualStrings("SocketReleaseFailed", failure.secondaryName().?);

    var outer = driver.OperationFailure.fromError(error.ConnectionLost);
    outer.noteFailure(failure);
    try std.testing.expectEqualStrings("TcpReadFailed", outer.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 2), outer.secondary_count);

    var chain = glowcap.foundation.FailureChain.initNamed(error.ProviderIo, "ProviderListenerCloseFailed");
    chain.noteNamed(error.ProviderInternal, "ProviderLeaseReleaseFailed");
    const projected = driver.OperationFailure.fromChain(chain);
    try std.testing.expectEqualStrings("ProviderListenerCloseFailed", projected.primaryName());
    try std.testing.expectEqualStrings("ProviderLeaseReleaseFailed", projected.secondaryName().?);
    try std.testing.expectEqual(@as(u16, 1), projected.secondary_count);
}

test "server close returns final runtime failure and implicit deinit reports it" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var explicit = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        opts,
    );
    explicit.runtime.enterDriver();
    try std.testing.expectError(error.HostNotQuiescent, explicit.runtime.detachThread());
    explicit.runtime.leaveDriver();
    explicit.runtime.noteTerminalFailure(error.ConnectionLost);
    const first = explicit.close().?;
    try std.testing.expectEqual(error.ConnectionLost, first.cause);
    try std.testing.expectEqual(error.ConnectionLost, explicit.close().?.cause);
    explicit.deinit();

    var capture = FailureCapture{};
    var implicit_opts = opts;
    implicit_opts.unhandled_failure = .{ .ctx = &capture, .report = FailureCapture.report };
    const implicit = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        implicit_opts,
    );
    implicit.runtime.noteTerminalFailure(error.ConnectionLost);
    implicit.deinit();
    try std.testing.expectEqual(error.ConnectionLost, capture.failure.?.cause);
}

test "server close stops admission while a yielded session retains the Host runtime" {
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
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    var stop = std.atomic.Value(bool).init(false);
    var client = try io.concurrent(connectAndHold, .{
        allocator,
        io,
        address,
        &stop,
    });
    defer {
        stop.store(true, .release);
        client.await(io) catch {};
    }

    const accepted = try server.accept();
    defer accepted.deinit();
    try std.testing.expect(server.close() == null);

    try std.testing.expect(server.close() == null);
    try std.testing.expectError(error.ServerClosed, server.accept());

    try std.testing.expectEqual(driver.core.Host.LifecyclePhase.active, accepted.runtime.lifecyclePhase());
    _ = try accepted.publish("after-listener-close", Treasure, .{});
}

test "a server pumped only by the readiness descriptor and stepAny serves a budgeted call, and the close observer hears the hangup" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var closed = std.atomic.Value(bool).init(false);
    var close_flag = CloseFlag{ .flag = &closed };
    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.stepped(harness.Quiet.sink(), .{ .ctx = &close_flag, .closed = CloseFlag.notify }),
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const ready_fd = try server.runtime.readinessDescriptor();
    var stop = std.atomic.Value(bool).init(false);

    var serve_future = try io.concurrent(stepServe, .{ server, ready_fd, &stop });
    defer {
        stop.store(true, .release);
        serve_future.await(io) catch {};
    }

    {
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        var client = try driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            tcp.locatorFromAddress(&designator_buf, address),
            .ephemeral,
            opts,
        );
        defer client.deinit();
        const treasure = try client.fetch("treasure");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const reply = try client.call(treasure, "greet", &.{}, arena.allocator());
        try std.testing.expect(reply == .fulfilled and reply.fulfilled == .string);
        try std.testing.expectEqualStrings("hello from the step server", reply.fulfilled.string);
    }

    // The client hung up. The step loop must observe the EOF and tell the
    // close observer, without any blocking verb running on the server.
    var waited: usize = 0;
    while (!closed.load(.acquire) and waited < 10_000) : (waited += 10) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(closed.load(.acquire));
}

test "a close observer may drop its owning Session without freeing the pump's borrowed wire" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The observer is installed at construction, so it learns the runtime
    // it will re-enter only once the server exists.
    var owned: ?*driver.Session = null;
    var observer = DropSessionOnClose{ .owned = &owned, .runtime = undefined };
    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.stepped(harness.Quiet.sink(), .{ .ctx = &observer, .closed = DropSessionOnClose.notify }),
    );
    defer server.deinit();
    observer.runtime = server.runtime;
    var address_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    var stop = std.atomic.Value(bool).init(false);
    var client = try io.concurrent(connectAndHold, .{ allocator, io, address, &stop });
    var client_done = false;
    defer {
        stop.store(true, .release);
        if (!client_done) client.await(io) catch {};
    }

    owned = try server.accept();
    errdefer if (owned) |session| session.deinit();
    try owned.?.attend();

    stop.store(true, .release);
    try client.await(io);
    client_done = true;
    var rounds: usize = 0;
    while (!observer.dropped and rounds < 1_000) : (rounds += 1)
        _ = server.runtime.stepAny(10) catch |err| switch (err) {
            error.ConnectionClosed => {},
            else => |other| return other,
        };

    try std.testing.expect(observer.dropped);
    try std.testing.expect(observer.blocking_reentry_refused);
    try std.testing.expect(owned == null);
}

test "a vow nobody parked on reaches the completion sink instead of being freed silently" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var closed = std.atomic.Value(bool).init(false);
    var close_flag = CloseFlag{ .flag = &closed };
    var server = try driver.listen(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        model.transport.tcp,
        .{ .designator = "127.0.0.1:0" },
        .ephemeral,
        harness.stepped(harness.Quiet.sink(), .{ .ctx = &close_flag, .closed = CloseFlag.notify }),
    );
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var stop = std.atomic.Value(bool).init(false);
    const server_ready = try server.runtime.readinessDescriptor();
    var serve_future = try io.concurrent(stepServe, .{ server, server_ready, &stop });
    defer {
        stop.store(true, .release);
        serve_future.await(io) catch {};
    }

    // The client is built stepped with the recording sink; the sink learns
    // the core it frees through once the runtime exists.
    var sink = RecordingSink{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    var client = try driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&designator_buf, address),
        .ephemeral,
        harness.stepped(sink.sink(), harness.Quiet.observer()),
    );
    defer client.deinit();
    sink.core = client.runtime.core;

    // A host-tier vow with no listener, the loop tier's every vow, settles
    // as an action the drain would otherwise free.
    const vow_id = try client.runtime.core.fetch(client.hs, "treasure");

    var waited: usize = 0;
    while (sink.settled.load(.acquire) == 0 and waited < 10_000) : (waited += 1) {
        _ = try client.runtime.stepAny(10);
    }
    try std.testing.expectEqual(vow_id, sink.settled.load(.acquire));
}

test "a refusing open observer settles failure and releases the unexposed session" {
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
    var runtime = try driver.HostRuntime.init(allocator, io, .{ .symbols = &.{.tcp} }, .ephemeral, opts);
    defer runtime.deinit();
    var recorder = DialRecorder{ .refuse_open = true };
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    try runtime.startDial(tcp.locatorFromAddress(&designator_buf, address), .inherit, 17, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    _ = try runtime.stepAny(0);
    const accepted = try server.accept();
    defer accepted.deinit();
    try accepted.attend();
    var rounds: usize = 0;
    while (recorder.failed_err == null and rounds < 1_000) : (rounds += 1) {
        _ = try runtime.stepAny(10);
        while (try server.runtime.stepAny(0) != null) {}
    }
    try std.testing.expectEqual(@as(u64, 17), recorder.failed_tag);
    try std.testing.expectEqual(@as(?anyerror, error.ObserverRefused), recorder.failed_err);
    try std.testing.expect(recorder.opened_session == null);
}

/// Dial `address` once and record how the attempt ended.
fn dialOnce(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: std.Io.net.IpAddress,
    outcome: *?anyerror,
    finished: *std.atomic.Value(bool),
) void {
    defer finished.store(true, .release);
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&designator_buf, address), .ephemeral, opts) catch |err| {
        outcome.* = err;
        return;
    };
    session.deinit();
    outcome.* = error.UnexpectedSession;
}

test "blocking opens and resident accepts share the staged-open admission bound" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Never stepped, so a dial to it stays in its handshake and holds the
    // bounded runtime's one open slot.
    var silent = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer silent.deinit();
    var silent_buf: [64]u8 = undefined;
    const silent_address = try tcp.parseDesignator(try silent.localDesignator(&silent_buf));

    var bounded = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .frame_cap = frame_cap,
        .max_pending_opens = 1,
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 10_000 },
    });
    defer bounded.deinit();
    var bounded_buf: [64]u8 = undefined;
    const bounded_address = try tcp.parseDesignator(try bounded.localDesignator(&bounded_buf));

    var recorder = DialRecorder{};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locatorFromAddress(&designator_buf, silent_address);
    try bounded.runtime.startDial(locator, .inherit, 1, .{
        .ctx = &recorder,
        .opened = DialRecorder.opened,
        .failed = DialRecorder.failed,
    });
    try std.testing.expectError(driver.Error.PendingOpenLimitReached, bounded.runtime.connectLocator(locator, .inherit));

    // An arrival while the slot is held closes with no session: the dialer
    // sees its connection end, and the Server never yields it.
    var outcome: ?anyerror = null;
    var finished = std.atomic.Value(bool).init(false);
    var client = try io.concurrent(dialOnce, .{ allocator, io, bounded_address, &outcome, &finished });
    var joined = false;
    defer if (!joined) client.await(io);
    var rounds: usize = 0;
    while (!finished.load(.acquire) and rounds < 500) : (rounds += 1) {
        try std.testing.expect(!try bounded.waitAcceptable(10));
    }
    client.await(io);
    joined = true;
    try std.testing.expect(finished.load(.acquire));
    try std.testing.expect(outcome != null);
    try std.testing.expect(outcome.? != error.UnexpectedSession and outcome.? != error.HandshakeTimedOut);
    try std.testing.expect(!try bounded.waitAcceptable(0));
    try std.testing.expect(recorder.opened_session == null and recorder.failed_err == null);
}
